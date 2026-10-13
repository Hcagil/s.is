import '../domain/voice.dart';

/// Makes no transcript: native recognition of a recorded file is a later step.
final class NoVoiceTranscriber implements VoiceTranscriber {
  /// Creates the transcriber.
  const NoVoiceTranscriber();

  @override
  Future<String?> transcribe(String path, {required String localeTag}) async =>
      null;
}
