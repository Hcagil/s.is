import 'dart:math' as math;

import 'video.dart';

/// A take shorter than this is thrown away.
const int minVoiceMs = 500;

/// A recording is at most 10 minutes.
const int maxVoiceMs = 600000;

/// The MIME type of a voice message (AAC in an m4a container).
const String voiceMime = 'audio/mp4';

/// The one-line preview / quote / forward text of a voice message.
const String voicePreview = '\u{1F3A4} Voice message';

/// Bars in a stored waveform.
const int voiceBars = 40;

/// The longest transcript that is stored.
const int maxTranscriptChars = 10000;

/// The playback speeds, in the order the speed chip cycles through them.
const List<double> voiceSpeeds = [1.0, 1.5, 2.0];

/// The speed after [current] in [voiceSpeeds]; wraps around, and an unknown
/// value gives 1.0.
double nextVoiceSpeed(double current) {
  final i = voiceSpeeds.indexOf(current);
  if (i < 0) return 1.0;
  return voiceSpeeds[(i + 1) % voiceSpeeds.length];
}

/// '1x', '1.5x' or '2x'.
String voiceSpeedLabel(double speed) {
  final s = speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toString();
  return '${s}x';
}

/// m:ss of a length in milliseconds, whole seconds rounded down.
String voiceClock(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// m:ss,cc of a length in milliseconds (hundredths after the comma), as the
/// record bar shows it while recording; whole hundredths rounded down.
String voiceTimer(int ms) {
  final v = ms < 0 ? 0 : ms;
  final total = v ~/ 1000;
  final cs = (v % 1000) ~/ 10;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')},'
      '${cs.toString().padLeft(2, '0')}';
}

/// The file name of a recording started at [at] (local time).
String voiceFileName(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'voice-${at.year.toString().padLeft(4, '0')}${two(at.month)}'
      '${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}.m4a';
}

double _unit(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0);

/// Turns loudness samples (0..1) into a stored waveform: exactly [voiceBars]
/// lowercase hex digits, 0 to f. With enough samples a bar is the loudest of
/// its share of them; with fewer, a bar repeats the nearest sample. No
/// samples at all gives a flat low line.
String encodeWaveform(List<double> samples) {
  if (samples.isEmpty) return '1' * voiceBars;
  final n = samples.length;
  final out = StringBuffer();
  for (var i = 0; i < voiceBars; i++) {
    final from = i * n ~/ voiceBars;
    final to = math.max(from + 1, (i + 1) * n ~/ voiceBars);
    var peak = 0.0;
    for (var j = from; j < to && j < n; j++) {
      peak = math.max(peak, _unit(samples[j]));
    }
    out.write((peak * 15).round().toRadixString(16));
  }
  return out.toString();
}

final _hexOnly = RegExp(r'^[0-9a-f]+$');

/// The bars of a stored waveform as heights 0..1. null, empty or anything
/// that is not lowercase hex gives an empty list.
List<double> decodeWaveform(String? hex) {
  if (hex == null || !_hexOnly.hasMatch(hex)) return const [];
  return [for (final c in hex.split('')) int.parse(c, radix: 16) / 15];
}

/// A transcript ready to store: trimmed, null when empty, cut to
/// [maxTranscriptChars] characters.
String? cleanTranscript(String? raw) {
  final t = raw?.trim() ?? '';
  if (t.isEmpty) return null;
  return t.length > maxTranscriptChars ? t.substring(0, maxTranscriptChars) : t;
}

/// How starting a recording or dictation went.
enum VoiceStart {
  /// It is running.
  started,

  /// The microphone or speech permission was refused.
  denied,

  /// It could not start (no recogniser, no model for the language, busy).
  failed,
}

/// A finished recording.
final class VoiceTake {
  /// Creates a take.
  const VoiceTake({
    required this.path,
    required this.durationMs,
    required this.waveform,
    required this.size,
  });

  /// The recorded file.
  final String path;

  /// Its length in milliseconds.
  final int durationMs;

  /// Its stored waveform (see [encodeWaveform]).
  final String waveform;

  /// Its size in bytes.
  final int size;
}

/// Records a voice message to a file. Never throws.
abstract interface class VoiceRecorder {
  /// Asks for the microphone if needed and starts recording AAC in an m4a
  /// container into [path] (its folder exists).
  Future<VoiceStart> start(String path);

  /// Loudness 0..1, about ten samples a second while recording.
  Stream<double> get levels;

  /// Stops and returns the take; null when nothing usable was recorded
  /// (shorter than half a second, or the file is missing). The file is then
  /// deleted.
  Future<VoiceTake?> stop();

  /// Stops and deletes the file.
  Future<void> cancel();

  /// Releases the recorder.
  Future<void> dispose();
}

/// Turns a finished recording into text ON THIS PHONE, never on a server.
abstract interface class VoiceTranscriber {
  /// The words of the recording at [path] in [localeTag] ('en_US', 'tr_TR'),
  /// or null when there is no transcript.
  Future<String?> transcribe(String path, {required String localeTag});
}

/// Speech to text for the message box, on this phone only.
abstract interface class Dictation {
  /// Starts listening in [localeTag]. [onText] gets the whole text recognised
  /// so far on every update; [onEnd] is called once when listening ends, by
  /// itself (silence, error) or after [stop] / [cancel].
  Future<VoiceStart> start({
    required String localeTag,
    required void Function(String text) onText,
    required void Function() onEnd,
  });

  /// Stops and keeps what was recognised ([onText] gets the final text, then
  /// [onEnd]).
  Future<void> stop();

  /// Stops and drops the text ([onEnd] is still called).
  Future<void> cancel();
}

/// A voice message being played: video playback used for audio, with a speed.
abstract interface class VoicePlayback implements VideoPlayback {
  /// Sets the speed, one of [voiceSpeeds].
  Future<void> setSpeed(double speed);
}

/// Makes a [VoicePlayback].
abstract interface class VoicePlaybackFactory {
  /// Creates a new playback.
  VoicePlayback create();
}

/// Which voice messages this member has already played, kept on this phone.
abstract interface class PlayedVoiceStore {
  /// The ids of the played voice messages.
  Future<Set<String>> load();

  /// Remembers that [messageId] was played.
  Future<void> add(String messageId);

  /// Forgets everything (sign-out).
  Future<void> clear();
}
