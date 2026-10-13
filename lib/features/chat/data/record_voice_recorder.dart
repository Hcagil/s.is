import 'dart:async';
import 'dart:io';

import 'package:record/record.dart';

import '../domain/voice.dart';

/// Records voice messages using the record package.
final class RecordVoiceRecorder implements VoiceRecorder {
  /// Creates a recorder.
  RecordVoiceRecorder() : _rec = AudioRecorder();

  final AudioRecorder _rec;

  final _levels = StreamController<double>.broadcast();

  @override
  Stream<double> get levels => _levels.stream;

  final List<double> _samples = [];
  StreamSubscription<Amplitude>? _sub;
  String? _path;
  final Stopwatch _clock = Stopwatch();

  @override
  Future<VoiceStart> start(String path) async {
    try {
      if (!await _rec.hasPermission()) return VoiceStart.denied;
      _samples.clear();
      _path = path;
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _clock
        ..reset()
        ..start();
      _sub = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((
        a,
      ) {
        final level = ((a.current + 50) / 50).clamp(0.0, 1.0).toDouble();
        _samples.add(level);
        if (!_levels.isClosed) _levels.add(level);
      });
      return VoiceStart.started;
    } catch (_) {
      return VoiceStart.failed;
    }
  }

  @override
  Future<VoiceTake?> stop() async {
    try {
      _clock.stop();
      await _sub?.cancel();
      _sub = null;
      final path = await _rec.stop() ?? _path;
      final ms = _clock.elapsedMilliseconds;
      _path = null;
      if (path == null) return null;
      final file = File(path);
      if (ms < 500 || !file.existsSync()) {
        await _delete(path);
        return null;
      }
      return VoiceTake(
        path: path,
        durationMs: ms > maxVoiceMs ? maxVoiceMs : ms,
        waveform: encodeWaveform(List.of(_samples)),
        size: file.lengthSync(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    _clock.stop();
    await _sub?.cancel();
    _sub = null;
    final path = _path;
    _path = null;
    try {
      await _rec.cancel();
    } catch (_) {}
    if (path != null) await _delete(path);
  }

  @override
  Future<void> dispose() async {
    try {
      await cancel();
      await _levels.close();
      await _rec.dispose();
    } catch (_) {}
  }

  Future<void> _delete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
