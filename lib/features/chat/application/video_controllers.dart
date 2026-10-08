part of 'chat_controllers.dart';

/// Picks and shrinks videos on the device.
final deviceVideosProvider = Provider<DeviceVideos>(
  (_) => throw UnimplementedError('override in main'),
);

/// Makes a player for each player screen.
final videoPlaybackFactoryProvider = Provider<VideoPlaybackFactory>(
  (_) => throw UnimplementedError('override in main'),
);

/// Hands a video to the phone's share sheet.
final videoSharerProvider = Provider<VideoSharer>(
  (_) => throw UnimplementedError('override in main'),
);

/// Where waiting sends are kept so they survive the app being killed.
final sendQueueStoreProvider = Provider<SendQueueStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// Forgets the saved queue as soon as the session ends, like
/// [deviceFilesOwnerProvider].
final sendQueueOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(sendQueueStoreProvider).clear());
});

/// Message id -> stage and fraction for every video send running or waiting
/// now.
final videoProgressProvider =
    NotifierProvider<VideoProgressController, Map<String, VideoProgress>>(
      VideoProgressController.new,
    );

/// Holds the [VideoProgress] of each video send, for its bubble to show.
class VideoProgressController extends Notifier<Map<String, VideoProgress>> {
  @override
  Map<String, VideoProgress> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  /// Records where the video [id] is. A change of under one percent within the
  /// same stage is ignored so a bubble is not rebuilt for nothing.
  void set(String id, VideoProgress progress) {
    final old = state[id];
    if (old != null &&
        old.stage == progress.stage &&
        (progress.fraction - old.fraction).abs() < 0.01 &&
        progress.fraction < 1) {
      return;
    }
    state = {...state, id: progress};
  }

  /// Forgets the video [id] (sent, cancelled or refused).
  void clear(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }
}
