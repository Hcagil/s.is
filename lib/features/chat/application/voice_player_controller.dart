part of 'chat_controllers.dart';

/// The state of the voice player.
final class VoicePlayerState {
  /// Creates a state.
  const VoicePlayerState({
    this.messageId,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1.0,
    this.played = const {},
  });

  /// The voice message loaded now, or null.
  final String? messageId;

  /// Whether it is playing.
  final bool playing;

  /// Its position.
  final Duration position;

  /// Its duration.
  final Duration duration;

  /// Its playback speed.
  final double speed;

  /// The ids of the played voice messages.
  final Set<String> played;

  /// A copy with the given fields replaced.
  VoicePlayerState copyWith({
    String? messageId,
    bool clearMessage = false,
    bool? playing,
    Duration? position,
    Duration? duration,
    double? speed,
    Set<String>? played,
  }) => VoicePlayerState(
    messageId: clearMessage ? null : (messageId ?? this.messageId),
    playing: playing ?? this.playing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    speed: speed ?? this.speed,
    played: played ?? this.played,
  );
}

/// The voice player.
final voicePlayerProvider = NotifierProvider<VoicePlayer, VoicePlayerState>(
  VoicePlayer.new,
);

/// Plays voice messages, one at a time; the next unplayed one follows.
class VoicePlayer extends Notifier<VoicePlayerState> {
  VoicePlayback? _playback;
  StreamSubscription<VideoPlaybackState>? _sub;
  int _gen = 0;

  @override
  VoicePlayerState build() {
    ref.watch(currentUserIdProvider);
    ref.watch(openConversationProvider);
    ref.onDispose(() {
      unawaited(_sub?.cancel());
      unawaited(_playback?.dispose());
      _playback = null;
      _sub = null;
    });
    unawaited(_loadPlayed());
    return const VoicePlayerState();
  }

  Future<void> _loadPlayed() async {
    try {
      final ids = await ref.read(playedVoiceStoreProvider).load();
      if (ref.mounted) {
        state = state.copyWith(played: {...state.played, ...ids});
      }
    } catch (_) {}
  }

  /// A tap on a voice bubble: play it, or pause / resume when it is the one
  /// loaded. The download failure, if any, and whether the file could not be
  /// played, for the caller to show.
  Future<({Failure? download, bool cannotPlay})> toggle(Message m) async {
    if (m.file == null) return (download: null, cannotPlay: false);
    if (state.messageId == m.id && _playback != null) {
      if (state.playing) {
        await _playback!.pause();
      } else {
        await _playback!.play();
      }
      return (download: null, cannotPlay: false);
    }
    return _playMessage(m);
  }

  Future<({Failure? download, bool cannotPlay})> _playMessage(Message m) async {
    final gen = ++_gen;
    await _release();
    if (!ref.mounted) return (download: null, cannotPlay: false);
    state = VoicePlayerState(
      messageId: m.id,
      speed: state.speed,
      played: state.played,
    );
    final name = m.file!.name;
    final files = ref.read(deviceFilesProvider);
    var path = await files.storedPath(m.id, name);
    if (path == null) {
      final failure = await ref.read(fileDownloadsProvider.notifier).start(m);
      if (failure != null) {
        if (gen == _gen && ref.mounted) {
          state = state.copyWith(clearMessage: true);
        }
        return (download: failure, cannotPlay: false);
      }
      path = await files.storedPath(m.id, name);
    }
    if (gen != _gen || !ref.mounted) return (download: null, cannotPlay: false);
    if (path == null) {
      state = state.copyWith(clearMessage: true);
      return (download: null, cannotPlay: true);
    }
    final playback = ref.read(voicePlaybackFactoryProvider).create();
    if (!await playback.open(path)) {
      await playback.dispose();
      if (gen == _gen && ref.mounted) {
        state = state.copyWith(clearMessage: true);
      }
      return (download: null, cannotPlay: true);
    }
    if (gen != _gen || !ref.mounted) {
      await playback.dispose();
      return (download: null, cannotPlay: false);
    }
    _playback = playback;
    _sub = playback.states.listen((s) => _onState(gen, m.id, s));
    await playback.setSpeed(state.speed);
    await playback.play();
    _markPlayed(m.id);
    return (download: null, cannotPlay: false);
  }

  void _onState(int gen, String id, VideoPlaybackState s) {
    if (gen != _gen || !ref.mounted) return;
    if (s.finished) {
      unawaited(_onFinished(id));
      return;
    }
    state = state.copyWith(
      playing: s.playing,
      position: s.position,
      duration: s.duration,
    );
  }

  Future<void> _onFinished(String id) async {
    final list = ref.read(messagesProvider).value ?? const <Message>[];
    final me = ref.read(currentUserIdProvider);
    final i = list.indexWhere((m) => m.id == id);
    Message? next;
    if (i >= 0) {
      for (var j = i + 1; j < list.length; j++) {
        final c = list[j];
        if ((c.file?.isVoice ?? false) &&
            c.senderId != me &&
            !c.sending &&
            c.attachmentPath != null &&
            !state.played.contains(c.id)) {
          next = c;
          break;
        }
      }
    }
    if (next != null) {
      await _playMessage(next);
    } else {
      await stop();
    }
  }

  Future<void> _release() async {
    // Nothing here is awaited: a cancel or dispose that waits on its own
    // stream must never hold up the next message or the stop.
    unawaited(_sub?.cancel());
    _sub = null;
    final p = _playback;
    _playback = null;
    if (p == null) return;
    unawaited(p.pause().then((_) => p.dispose(), onError: (_) => p.dispose()));
  }

  void _markPlayed(String id) {
    if (state.played.contains(id)) return;
    state = state.copyWith(played: {...state.played, id});
    try {
      unawaited(ref.read(playedVoiceStoreProvider).add(id));
    } catch (_) {}
  }

  /// Cycles 1x, 1.5x, 2x for this and the next messages.
  Future<void> cycleSpeed() async {
    final next = nextVoiceSpeed(state.speed);
    state = state.copyWith(speed: next);
    await _playback?.setSpeed(next);
  }

  /// Stops and unloads.
  Future<void> stop() async {
    ++_gen;
    if (ref.mounted) {
      state = state.copyWith(
        clearMessage: true,
        playing: false,
        position: Duration.zero,
        duration: Duration.zero,
      );
    }
    await _release();
  }
}

/// Forgets which voice messages were played as soon as the session ends, like
/// [sendQueueOwnerProvider].
final playedVoiceOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(playedVoiceStoreProvider).clear());
});
