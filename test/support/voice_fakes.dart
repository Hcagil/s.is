// Fakes for the voice boundary (VoiceRecorder, VoiceTranscriber, Dictation,
// VoicePlayback, VoicePlaybackFactory, PlayedVoiceStore) and the overrides
// needed by tests.  They are written by QA from the interfaces only, and
// mimic the real implementations, including artificial latency.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/domain/voice.dart';

/// A fake voice recorder that records calls and simulates latency.
class VoiceRecorderFake implements VoiceRecorder {
  VoiceRecorderFake({
    this.startResult = VoiceStart.started,
    this.latency = const Duration(milliseconds: 30),
    this.take,
    this.nothingUsable = false,
  });

  /// The result returned by [start].
  VoiceStart startResult;

  /// Artificial latency for [start].
  Duration latency;

  /// If non‑null, returned by [stop] instead of the default.
  VoiceTake? take;

  /// If true, [stop] returns null even if [take] is null.
  bool nothingUsable;

  /// The path passed to the last [start].
  String? startedPath;

  /// Recorded calls: `start:PATH`, 'stop', 'cancel', 'dispose'.
  final calls = <String>[];

  /// Loudness samples while recording.
  final _levels = StreamController<double>.broadcast();

  @override
  Stream<double> get levels => _levels.stream;

  /// Adds a level sample to the stream.
  void level(double v) => _levels.add(v);

  @override
  Future<VoiceStart> start(String path) async {
    startedPath = path;
    calls.add('start:$path');
    await Future<void>.delayed(latency);
    return startResult;
  }

  @override
  Future<VoiceTake?> stop() async {
    calls.add('stop');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (take != null) return take;
    if (nothingUsable) return null;
    return VoiceTake(
      path: startedPath!,
      durationMs: 4200,
      waveform: '0123456789abcdef0123456789abcdef01234567',
      size: 9000,
    );
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _levels.close();
  }
}

/// A fake transcriber that records calls and returns a preset transcript.
class VoiceTranscriberFake implements VoiceTranscriber {
  VoiceTranscriberFake({this.words});

  /// The transcript returned by [transcribe].
  String? words;

  /// Recorded calls: each entry is a pair of [path] and [localeTag].
  final asked = <(String, String)>[];

  @override
  Future<String?> transcribe(String path, {required String localeTag}) async {
    asked.add((path, localeTag));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return words;
  }
}

/// A fake dictation service that records calls and simulates speech input.
class DictationFake implements Dictation {
  DictationFake({this.startResult = VoiceStart.started});

  /// The result returned by [start].
  VoiceStart startResult;

  /// The locale passed to the last [start].
  String? localeTag;

  /// The last text passed to [hear].
  String? _lastText;

  /// Recorded calls: 'start', 'stop', 'cancel'.
  final calls = <String>[];

  /// The callbacks passed to [start].
  void Function(String text)? _onText;
  void Function()? _onEnd;

  @override
  Future<VoiceStart> start({
    required String localeTag,
    required void Function(String text) onText,
    required void Function() onEnd,
  }) async {
    this.localeTag = localeTag;
    _onText = onText;
    _onEnd = onEnd;
    calls.add('start');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return startResult;
  }

  /// Simulate receiving new recognised text.
  void hear(String text) {
    _lastText = text;
    _onText?.call(text);
  }

  /// Simulate the dictation ending by itself.
  void endByItself() => _onEnd?.call();

  @override
  Future<void> stop() async {
    calls.add('stop');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _onText?.call(_lastText ?? '');
    _onEnd?.call();
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _onEnd?.call();
  }
}

/// A fake voice playback that mimics the real one, including speed control.
class VoicePlaybackFake implements VoicePlayback {
  VoicePlaybackFake({this.opens = true});

  /// Whether [open] succeeds.
  bool opens;

  /// Recorded calls: 'open', 'play', 'pause', 'seek:MS', 'muted:BOOL',
  /// 'speed:VALUE', 'dispose'.
  final calls = <String>[];

  /// The path passed to the last [open].
  String? openedPath;

  /// Current playback speed.
  double? speed;

  final _states = StreamController<VideoPlaybackState>.broadcast();

  /// Emit a new state.
  void emit(VideoPlaybackState s) => _states.add(s);

  @override
  Future<bool> open(String path) async {
    openedPath = path;
    calls.add('open');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return opens;
  }

  @override
  Stream<VideoPlaybackState> get states => _states.stream;

  /// Like the real player, a play or pause is reported on [states] a little
  /// later, not by the call itself.
  void _report(bool playing) =>
      Future<void>.delayed(const Duration(milliseconds: 3), () {
        if (!_states.isClosed) {
          emit(
            VideoPlaybackState(
              duration: const Duration(seconds: 41),
              playing: playing,
            ),
          );
        }
      });

  @override
  Future<void> play() async {
    calls.add('play');
    _report(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _report(false);
  }

  @override
  Future<void> seekTo(Duration position) async =>
      calls.add('seek:${position.inMilliseconds}');

  @override
  Future<void> setMuted(bool muted) async => calls.add('muted:$muted');

  @override
  Future<void> setSpeed(double speed) async {
    calls.add('speed:$speed');
    this.speed = speed;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _states.close();
  }

  /// Emit a finished state at the given duration.
  void finish(Duration d) => _states.isClosed
      ? null
      : emit(
          VideoPlaybackState(
            position: d,
            duration: d,
            playing: false,
            finished: true,
          ),
        );
}

/// A fake factory that creates [VoicePlaybackFake] instances.
class VoicePlaybackFactoryFake implements VoicePlaybackFactory {
  VoicePlaybackFactoryFake({this.opens = true});

  bool opens;

  final made = <VoicePlaybackFake>[];

  @override
  VoicePlayback create() {
    final p = VoicePlaybackFake(opens: opens);
    made.add(p);
    return p;
  }
}

/// A fake store that keeps track of played voice message IDs.
class PlayedVoiceStoreFake implements PlayedVoiceStore {
  PlayedVoiceStoreFake([Set<String>? initial]) {
    _store = Set<String>.from(initial ?? {});
  }

  late Set<String> _store;
  bool cleared = false;
  final added = <String>[];

  @override
  Future<Set<String>> load() async {
    await Future<void>.delayed(const Duration(milliseconds: 15));
    return Set<String>.from(_store);
  }

  @override
  Future<void> add(String messageId) async {
    added.add(messageId);
    _store.add(messageId);
  }

  @override
  Future<void> clear() async {
    cleared = true;
    _store.clear();
  }
}

/// Provides overrides for all voice‑related providers, using the supplied fakes
/// or default ones if null.
List<Override> voiceOverrides({
  VoiceRecorder? recorder,
  VoiceTranscriber? transcriber,
  Dictation? dictation,
  VoicePlaybackFactory? playback,
  PlayedVoiceStore? played,
}) => [
  voiceRecorderProvider.overrideWithValue(recorder ?? VoiceRecorderFake()),
  voiceTranscriberProvider.overrideWithValue(
    transcriber ?? VoiceTranscriberFake(),
  ),
  dictationProvider.overrideWithValue(dictation ?? DictationFake()),
  voicePlaybackFactoryProvider.overrideWithValue(
    playback ?? VoicePlaybackFactoryFake(),
  ),
  playedVoiceStoreProvider.overrideWithValue(played ?? PlayedVoiceStoreFake()),
];
