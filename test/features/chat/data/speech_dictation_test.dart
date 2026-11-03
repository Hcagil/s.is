import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/speech_dictation.dart';
import 'package:sis/features/chat/domain/voice.dart';

const sis = MethodChannel('sis/speech');
const stt = MethodChannel('plugin.csdcorp.com/speech_to_text');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // One instance, as main.dart provides it: the plugin is a singleton that
  // keeps the listeners of its first initialize.
  final dictation = SpeechDictation();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> sisCalls, sttCalls;

  void mock({Object? onDevice, bool throws = false}) {
    sisCalls = [];
    sttCalls = [];
    messenger.setMockMethodCallHandler(sis, (call) async {
      sisCalls.add(call.method);
      if (throws) throw PlatformException(code: 'boom');
      return onDevice;
    });
    messenger.setMockMethodCallHandler(stt, (call) async {
      sttCalls.add(call.method);
      return call.method == 'locales' ? <String>['en_US:English'] : true;
    });
  }

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(sis, null);
    messenger.setMockMethodCallHandler(stt, null);
  });

  test('onDeviceAvailable returns false -> VoiceStart.failed', () async {
    mock(onDevice: false);
    final result = await dictation.start(
      localeTag: 'en-US',
      onText: (_) {},
      onEnd: () {},
    );
    expect(result, VoiceStart.failed);
    expect(sisCalls, contains('onDeviceAvailable'));
    expect(sttCalls, isNot(contains('listen')));
  });

  test('onDeviceAvailable returns null -> VoiceStart.failed', () async {
    mock(onDevice: null);
    final result = await dictation.start(
      localeTag: 'en-US',
      onText: (_) {},
      onEnd: () {},
    );
    expect(result, VoiceStart.failed);
    expect(sisCalls, contains('onDeviceAvailable'));
    expect(sttCalls, isNot(contains('listen')));
  });

  test(
    'onDeviceAvailable throws PlatformException -> VoiceStart.failed',
    () async {
      mock(throws: true);
      final result = await dictation.start(
        localeTag: 'en-US',
        onText: (_) {},
        onEnd: () {},
      );
      expect(result, VoiceStart.failed);
      expect(sisCalls, contains('onDeviceAvailable'));
      expect(sttCalls, isNot(contains('listen')));
    },
  );

  test('onDeviceAvailable returns true -> plugin is used', () async {
    mock(onDevice: true);
    await dictation.start(localeTag: 'en-US', onText: (_) {}, onEnd: () {});
    expect(sisCalls, contains('onDeviceAvailable'));
    expect(sttCalls, contains('listen'), reason: 'the plugin listens');
  });

  group('ends by itself', () {
    late List<String> events;

    /// Delivers a native -> Dart callback on the plugin channel, as the
    /// Android plugin does.
    void native(String method, Object? args) {
      messenger.handlePlatformMessage(
        stt.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    /// What the Android plugin (SpeechToTextPlugin.kt onError) sends on a
    /// recogniser error. When it was listening it sends the status calls at
    /// once and posts the error to the main handler, so the error arrives
    /// last. When it never started listening it sends the error alone.
    void androidError(String code, {required bool wasListening}) {
      if (wasListening) {
        native('notifyStatus', 'notListening');
        native('notifyStatus', 'doneNoResult');
      }
      native('notifyError', jsonEncode({'errorMsg': code, 'permanent': true}));
    }

    // The plugin is a singleton whose channel handler lives in the zone of
    // the first initialize, so these run on real time, not fakeAsync.
    Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

    Future<SpeechDictation> listening({bool started = true}) async {
      mock(onDevice: true);
      events = [];
      final d = dictation;
      final result = await d.start(
        localeTag: 'en-US',
        onText: (_) {},
        onEnd: () => events.add('end'),
        onError: () => events.add('error'),
      );
      expect(result, VoiceStart.started);
      expect(sttCalls, contains('listen'));
      if (started) native('notifyStatus', 'listening');
      await wait(100);
      expect(events, isEmpty);
      return d;
    }

    for (final wasListening in [false, true]) {
      final when = wasListening ? 'while listening' : 'before listening';
      for (final code in ['error_no_match', 'error_speech_timeout']) {
        test('$code $when (silence) -> onEnd only', () async {
          await listening(started: wasListening);
          androidError(code, wasListening: wasListening);
          await wait(600);
          expect(events, ['end']);
        });
      }

      for (final code in [
        'error_client',
        'error_too_many_requests',
        'error_server_disconnected',
      ]) {
        test('$code $when -> onError then onEnd, once each', () async {
          await listening(started: wasListening);
          androidError(code, wasListening: wasListening);
          await wait(600);
          expect(events, ['error', 'end']);
          // A late repeat from the recogniser must not show a second notice.
          androidError(code, wasListening: false);
          await wait(600);
          expect(events, ['error', 'end']);
        });
      }
    }

    test('a late error after the session ended -> no onError', () async {
      await listening();
      native('notifyStatus', 'notListening');
      native('notifyStatus', 'done');
      await wait(600);
      expect(events, ['end']);
      // onError belongs before onEnd; once ended, a stray error is ignored.
      androidError('error_client', wasListening: false);
      await wait(600);
      expect(events, ['end']);
    });

    test('no onError after cancel()', () async {
      final d = await listening();
      unawaited(d.cancel());
      await wait(100);
      androidError('error_client', wasListening: false);
      await wait(600);
      expect(events, isNot(contains('error')));
      expect(events.where((e) => e == 'end'), hasLength(1));
    });

    test('a locales call that never answers -> failed within 3 s', () {
      fakeAsync((async) {
        mock(onDevice: true);
        messenger.setMockMethodCallHandler(stt, (call) {
          sttCalls.add(call.method);
          if (call.method == 'locales') return Completer<Object?>().future;
          return Future.value(true);
        });
        VoiceStart? result;
        dictation
            .start(localeTag: 'en-US', onText: (_) {}, onEnd: () {})
            .then((r) => result = r);
        async.elapse(const Duration(milliseconds: 3100));
        expect(sttCalls, contains('locales'));
        expect(result, VoiceStart.failed);
        expect(sttCalls, isNot(contains('listen')));
      });
    });
  });
}
