import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/speech_dictation.dart';
import 'package:sis/features/chat/domain/voice.dart';

const sis = MethodChannel('sis/speech');
const stt = MethodChannel('plugin.csdcorp.com/speech_to_text');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    final result = await SpeechDictation().start(
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
    final result = await SpeechDictation().start(
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
      final result = await SpeechDictation().start(
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
    await SpeechDictation().start(
      localeTag: 'en-US',
      onText: (_) {},
      onEnd: () {},
    );
    expect(sisCalls, contains('onDeviceAvailable'));
    expect(sttCalls, contains('listen'), reason: 'the plugin listens');
  });
}
