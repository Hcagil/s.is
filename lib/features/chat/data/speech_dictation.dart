import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../domain/voice.dart';

/// Uses the speech_to_text package to recognise speech.
final class SpeechDictation implements Dictation {
  /// Creates a dictation.
  SpeechDictation();

  final SpeechToText _stt = SpeechToText();
  void Function(String)? _onText;
  void Function()? _onEnd;

  @override
  Future<VoiceStart> start({
    required String localeTag,
    required void Function(String text) onText,
    required void Function() onEnd,
  }) async {
    try {
      final ok = await _stt.initialize(onError: _error, onStatus: _status);
      if (!ok) {
        return (await _stt.hasPermission)
            ? VoiceStart.failed
            : VoiceStart.denied;
      }
      final id = await _localeId(localeTag);
      if (id == null) return VoiceStart.failed;
      _onText = onText;
      _onEnd = onEnd;
      await _stt.listen(
        onResult: (r) => _onText?.call(r.recognizedWords),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          onDevice: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
          listenFor: const Duration(minutes: 10),
          pauseFor: const Duration(seconds: 30),
          localeId: id,
        ),
      );
      return VoiceStart.started;
    } catch (_) {
      _onText = null;
      _onEnd = null;
      return VoiceStart.failed;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _stt.stop();
    } catch (_) {}
    _finish();
  }

  @override
  Future<void> cancel() async {
    _onText = null;
    try {
      await _stt.cancel();
    } catch (_) {}
    _finish();
  }

  void _status(String s) {
    if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) {
      _finish();
    }
  }

  void _error(SpeechRecognitionError e) => _finish();

  void _finish() {
    final end = _onEnd;
    _onEnd = null;
    _onText = null;
    end?.call();
  }

  Future<String?> _localeId(String tag) async {
    try {
      final locales = await _stt.locales();
      final want = tag.replaceAll('-', '_');
      for (final l in locales) {
        if (l.localeId.replaceAll('-', '_') == want) return l.localeId;
      }
      final lang = want.split('_').first;
      for (final l in locales) {
        if (l.localeId.replaceAll('-', '_').startsWith('${lang}_')) {
          return l.localeId;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
