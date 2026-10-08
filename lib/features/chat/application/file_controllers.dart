part of 'chat_controllers.dart';

/// Repository for sending and downloading files.
final chatFileRepositoryProvider = Provider<ChatFileRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// Repository for accessing files on the device.
final deviceFilesProvider = Provider<DeviceFiles>(
  (_) => throw UnimplementedError('override in main'),
);

/// Wipes kept files when the session ends, like attachmentCacheOwnerProvider.
final deviceFilesOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(deviceFilesProvider).clear());
});

/// The path of a file message's kept copy on this phone, or null when not
/// downloaded.
final storedFileProvider = FutureProvider.autoDispose
    .family<String?, ({String id, String name})>((ref, key) {
      ref.watch(currentUserIdProvider);
      return ref.read(deviceFilesProvider).storedPath(key.id, key.name);
    });

/// Tracks which file downloads are currently running.
final fileDownloadsProvider =
    NotifierProvider<FileDownloads, Map<String, double>>(FileDownloads.new);

/// Message id -> fraction 0..1 for every file download running now.
class FileDownloads extends Notifier<Map<String, double>> {
  final _autoTried = <String>{};

  @override
  Map<String, double> build() {
    ref.watch(currentUserIdProvider);
    _autoTried.clear();
    return const {};
  }

  /// Downloads a file message; the failure, if any, for the caller to show.
  Future<Failure?> start(Message message) async {
    final path = message.attachmentPath;
    final file = message.file;
    if (path == null || file == null || state.containsKey(message.id)) {
      return null;
    }
    state = {...state, message.id: 0.0};
    final dest = await ref
        .read(deviceFilesProvider)
        .pathFor(message.id, file.name);
    if (!ref.mounted) return null;
    var last = 0.0;
    final result = await ref
        .read(chatFileRepositoryProvider)
        .download(
          path,
          dest,
          onProgress: (f) {
            if (!ref.mounted) return;
            if (f >= 1 || f - last >= 0.01) {
              last = f;
              state = {...state, message.id: f};
            }
          },
        );
    if (!ref.mounted) return null;
    state = {...state}..remove(message.id);
    switch (result) {
      case Ok():
        ref.invalidate(storedFileProvider((id: message.id, name: file.name)));
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Tries an automatic download once per message per session; a failure is
  /// dropped silently and the member can tap.
  void auto(Message message) {
    if (_autoTried.add(message.id)) unawaited(start(message));
  }
}

/// Photos the member chose to download by tapping.
final photoApprovalsProvider = NotifierProvider<PhotoApprovals, Set<String>>(
  PhotoApprovals.new,
);

/// The storage paths of photos approved by a tap.
class PhotoApprovals extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  /// Marks a photo for download.
  void approve(String path) => state = {...state, path};
}

/// Whether the photo at storage path may load now.
final photoGateProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  path,
) async {
  if (ref.watch(photoApprovalsProvider).contains(path)) return true;
  if (await ref.read(attachmentCacheProvider).read(path) != null) return true;
  try {
    return await ref.watch(autoDownloadNowProvider(MediaKind.photos).future);
  } catch (_) {
    // The network could not be told: behave as before, load.
    return true;
  }
});
