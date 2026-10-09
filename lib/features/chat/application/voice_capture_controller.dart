part of 'chat_controllers.dart';

/// Records a voice message to a file.
final voiceRecorderProvider = Provider<VoiceRecorder>(
  (_) => throw UnimplementedError('override in main'),
);

/// Turns a finished recording into text ON THIS PHONE, never on a server.
final voiceTranscriberProvider = Provider<VoiceTranscriber>(
  (_) => throw UnimplementedError('override in main'),
);

/// Speech to text for the message box, on this phone only.
final dictationProvider = Provider<Dictation>(
  (_) => throw UnimplementedError('override in main'),
);

/// Makes a [VoicePlayback].
final voicePlaybackFactoryProvider = Provider<VoicePlaybackFactory>(
  (_) => throw UnimplementedError('override in main'),
);

/// Which voice messages this member has already played, kept on this phone.
final playedVoiceStoreProvider = Provider<PlayedVoiceStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// What the one composer button does when held.
enum VoiceMode {
  /// Records a voice message.
  voice,

  /// Turns speech into text in the message box.
  dictation,
}

/// Where a hold is.
enum VoicePhase {
  /// Nothing is being captured.
  idle,

  /// The button is held down.
  held,

  /// Swiped up: captures without the finger.
  locked,
}

/// A notice to show once about the last capture.
enum VoiceNotice {
  /// The microphone or speech permission was refused.
  micDenied,

  /// The recording could not start.
  micFailed,

  /// No on-phone recogniser for this language.
  dictationUnavailable,

  /// Released too early: nothing was recorded.
  tooShort,
}

/// The state of the composer's voice / dictation button.
final class VoiceCaptureState {
  /// Creates a state.
  const VoiceCaptureState({
    this.mode = VoiceMode.voice,
    this.phase = VoicePhase.idle,
    this.elapsedMs = 0,
    this.notice,
  });

  /// What a hold does now.
  final VoiceMode mode;

  /// Where the hold is.
  final VoicePhase phase;

  /// Milliseconds since the hold began.
  final int elapsedMs;

  /// A notice waiting to be shown once.
  final VoiceNotice? notice;

  /// A copy with the given fields replaced.
  VoiceCaptureState copyWith({
    VoiceMode? mode,
    VoicePhase? phase,
    int? elapsedMs,
    VoiceNotice? notice,
    bool clearNotice = false,
  }) => VoiceCaptureState(
    mode: mode ?? this.mode,
    phase: phase ?? this.phase,
    elapsedMs: elapsedMs ?? this.elapsedMs,
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// The composer's voice / dictation button.
final voiceCaptureProvider = NotifierProvider<VoiceCapture, VoiceCaptureState>(
  VoiceCapture.new,
);

/// Records a voice message or dictates into the message box.
class VoiceCapture extends Notifier<VoiceCaptureState> {
  Timer? _ticker;
  final Stopwatch _clock = clock.stopwatch();
  String? _conversationId;
  String _localeTag = 'en_US';
  String _base = '';
  String? _messageId;
  String? _fileName;
  Future<void>? _starting;
  bool _ending = false;

  @override
  VoiceCaptureState build() {
    ref.watch(currentUserIdProvider);
    ref.onDispose(() => _ticker?.cancel());
    return const VoiceCaptureState();
  }

  /// A tap: voice becomes dictation and back. Ignored during a hold.
  void toggleMode() {
    if (state.phase != VoicePhase.idle) return;
    state = state.copyWith(
      mode: state.mode == VoiceMode.voice
          ? VoiceMode.dictation
          : VoiceMode.voice,
    );
  }

  /// Starts capturing for [conversationId] in the language [localeTag].
  Future<void> begin(String conversationId, String localeTag) {
    if (state.phase != VoicePhase.idle) return Future.value();
    _conversationId = conversationId;
    _localeTag = localeTag;
    state = state.copyWith(
      phase: VoicePhase.held,
      elapsedMs: 0,
      clearNotice: true,
    );
    _clock
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    return _starting = _start();
  }

  Future<void> _start() async {
    final VoiceStart result;
    if (state.mode == VoiceMode.voice) {
      final messageId = _messageId = randomMessageId();
      final name = _fileName = voiceFileName(DateTime.now());
      final path = await ref.read(deviceFilesProvider).pathFor(messageId, name);
      result = await ref.read(voiceRecorderProvider).start(path);
    } else {
      _base = ref.read(draftsProvider.notifier).draftFor(_conversationId!).text;
      result = await ref
          .read(dictationProvider)
          .start(
            localeTag: _localeTag,
            onText: _onDictated,
            onEnd: _onDictationEnd,
          );
    }
    if (!ref.mounted) return;
    if (result != VoiceStart.started) {
      _stopTicker();
      state = state.copyWith(
        phase: VoicePhase.idle,
        elapsedMs: 0,
        notice: result == VoiceStart.denied
            ? VoiceNotice.micDenied
            : (state.mode == VoiceMode.voice
                  ? VoiceNotice.micFailed
                  : VoiceNotice.dictationUnavailable),
      );
    }
  }

  /// Swiped up: keeps capturing without the finger.
  void lock() {
    if (state.phase == VoicePhase.held) {
      state = state.copyWith(phase: VoicePhase.locked);
    }
  }

  void _tick() {
    final ms = _clock.elapsedMilliseconds;
    state = state.copyWith(elapsedMs: ms);
    if (state.mode == VoiceMode.voice && ms >= maxVoiceMs) {
      unawaited(finish());
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _clock.stop();
  }

  /// Release (or Send when locked): a voice message is queued for sending, a
  /// dictation keeps its text in the message box.
  Future<void> finish() async {
    await _starting;
    if (state.phase == VoicePhase.idle || _ending) return;
    _ending = true;
    _stopTicker();
    try {
      if (state.mode == VoiceMode.voice) {
        await _finishVoice();
      } else {
        await ref.read(dictationProvider).stop();
      }
    } finally {
      _ending = false;
    }
    if (ref.mounted) {
      state = state.copyWith(phase: VoicePhase.idle, elapsedMs: 0);
    }
  }

  Future<void> _finishVoice() async {
    final take = await ref.read(voiceRecorderProvider).stop();
    if (!ref.mounted) return;
    final id = _conversationId;
    final messageId = _messageId;
    final name = _fileName;
    if (take == null ||
        take.durationMs < minVoiceMs ||
        id == null ||
        messageId == null ||
        name == null) {
      state = state.copyWith(notice: VoiceNotice.tooShort);
      return;
    }
    final transcript = cleanTranscript(
      await ref
          .read(voiceTranscriberProvider)
          .transcribe(take.path, localeTag: _localeTag),
    );
    if (!ref.mounted) return;
    ref
        .read(sendQueueProvider.notifier)
        .enqueueFile(
          id,
          PickedFile(
            id: messageId,
            path: take.path,
            name: name,
            mime: voiceMime,
            size: take.size,
            durationMs: take.durationMs,
            waveform: take.waveform,
            transcript: transcript,
          ),
          replyTo: ref.read(replyingToProvider),
        );
  }

  /// Throws the capture away: no voice message, and the message box goes
  /// back to what it held before a dictation.
  Future<void> cancel() async {
    await _starting;
    if (state.phase == VoicePhase.idle) return;
    _stopTicker();
    if (state.mode == VoiceMode.voice) {
      await ref.read(voiceRecorderProvider).cancel();
    } else {
      await ref.read(dictationProvider).cancel();
      final id = _conversationId;
      if (id != null && ref.mounted) {
        ref.read(draftsProvider.notifier).setText(id, _base);
      }
    }
    if (ref.mounted) {
      state = state.copyWith(phase: VoicePhase.idle, elapsedMs: 0);
    }
  }

  void _onDictated(String text) {
    final id = _conversationId;
    if (!ref.mounted || id == null) return;
    final sep = (_base.isEmpty || _base.endsWith(' ') || _base.endsWith('\n'))
        ? ''
        : ' ';
    var all = '$_base$sep$text';
    if (all.length > maxMessageLength) {
      all = all.substring(0, maxMessageLength);
    }
    ref.read(draftsProvider.notifier).setText(id, all);
  }

  void _onDictationEnd() {
    if (!ref.mounted) return;
    if (state.mode == VoiceMode.dictation && state.phase != VoicePhase.idle) {
      _stopTicker();
      state = state.copyWith(phase: VoicePhase.idle, elapsedMs: 0);
    }
  }

  /// The notice was shown.
  void consumeNotice() {
    if (state.notice != null) state = state.copyWith(clearNotice: true);
  }
}
