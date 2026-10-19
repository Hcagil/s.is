// RecordVoiceRecorder.pause/resume against the real `record` plugin class
// (AudioRecorder), with only the platform side replaced: real audio needs a
// device, so this is as far as a unit test can reach. Contract:
// PausableVoiceRecorder.pause/resume never throw, answer false on failure,
// and resume carries on the same file (no new start).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sis/features/chat/data/record_voice_recorder.dart';
import 'package:sis/features/chat/domain/voice.dart';

/// The platform half of `record`, behaving like the Android one: a file
/// appears on start, calls answer a little later, and a call can fail with a
/// PlatformException as the native side does.
class _Platform extends RecordPlatform {
  final calls = <String>[];
  bool failPause = false;
  bool failResume = false;
  String? path;
  bool _recording = false;
  bool _paused = false;
  final _states = StreamController<RecordState>.broadcast();

  Future<void> _later() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  @override
  Future<void> create(String recorderId) async => calls.add('create');

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    calls.add('start');
    await _later();
    this.path = path;
    File(path).writeAsBytesSync(List<int>.filled(4096, 7));
    _recording = true;
    _states.add(RecordState.record);
  }

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async => const Stream.empty();

  @override
  Future<String?> stop(String recorderId) async {
    calls.add('stop');
    await _later();
    _recording = false;
    _paused = false;
    _states.add(RecordState.stop);
    return path;
  }

  @override
  Future<void> pause(String recorderId) async {
    calls.add('pause');
    await _later();
    if (failPause) throw PlatformException(code: 'record', message: 'busy');
    _paused = true;
    _states.add(RecordState.pause);
  }

  @override
  Future<void> resume(String recorderId) async {
    calls.add('resume');
    await _later();
    if (failResume) throw PlatformException(code: 'record', message: 'busy');
    _paused = false;
    _states.add(RecordState.record);
  }

  @override
  Future<bool> isRecording(String recorderId) async => _recording;

  @override
  Future<bool> isPaused(String recorderId) async => _paused;

  @override
  Future<void> dispose(String recorderId) async => calls.add('dispose');

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -20, max: -10);

  @override
  Future<bool> isEncoderSupported(
    String recorderId,
    AudioEncoder encoder,
  ) async => true;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => [];

  @override
  Future<void> cancel(String recorderId) async {
    calls.add('cancel');
    await _later();
    _recording = false;
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => _states.stream;

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late RecordPlatform before;
  late Directory dir;
  late RecordVoiceRecorder rec;

  setUp(() async {
    before = RecordPlatform.instance;
    platform = _Platform();
    RecordPlatform.instance = platform;
    dir = Directory.systemTemp.createTempSync('voice');
    rec = RecordVoiceRecorder();
    expect(rec, isA<PausableVoiceRecorder>());
    expect(await rec.start('${dir.path}/a.m4a'), VoiceStart.started);
  });

  tearDown(() async {
    await rec.dispose();
    RecordPlatform.instance = before;
    dir.deleteSync(recursive: true);
  });

  test('pause and resume reach the plugin and answer true', () async {
    expect(await rec.pause(), isTrue);
    expect(platform.calls, contains('pause'));
    expect(await rec.resume(), isTrue);
    expect(platform.calls, contains('resume'));
    await rec.stop();
    expect(
      platform.calls.where((c) => c == 'start'),
      hasLength(1),
      reason: 'resume must carry on the same file, not start a new one',
    );
    expect(platform.calls.where((c) => c == 'stop'), hasLength(1));
  });

  test('a failing pause answers false, never throws', () async {
    platform.failPause = true;
    expect(await rec.pause(), isFalse);
    expect(platform.calls, contains('pause'));
  });

  test('a failing resume answers false, never throws', () async {
    expect(await rec.pause(), isTrue);
    platform.failResume = true;
    expect(await rec.resume(), isFalse);
    expect(platform.calls, contains('resume'));
  });
}
