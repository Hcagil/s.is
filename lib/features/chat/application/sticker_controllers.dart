part of 'chat_controllers.dart';

/// Stores and reads stickers, favourites and albums.
final stickerRepositoryProvider = Provider<StickerRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The stickers this phone's member sent lately.
final recentStickerStoreProvider = Provider<RecentStickerStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// What the sticker panel shows: recent, favourites and the member's albums.
final class StickerLibrary {
  /// Creates the library state.
  const StickerLibrary({
    this.recent = const [],
    this.favourites = const [],
    this.albums = const [],
    this.loaded = false,
  });

  /// Recently sent sticker ids, newest first.
  final List<String> recent;

  /// Favourite sticker ids, newest first.
  final List<String> favourites;

  /// The member's own albums.
  final List<StickerAlbum> albums;

  /// Whether the first load finished.
  final bool loaded;

  /// A copy with the given fields replaced.
  StickerLibrary copyWith({
    List<String>? recent,
    List<String>? favourites,
    List<StickerAlbum>? albums,
    bool? loaded,
  }) {
    return StickerLibrary(
      recent: recent ?? this.recent,
      favourites: favourites ?? this.favourites,
      albums: albums ?? this.albums,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// The member's sticker library.
final stickerLibraryProvider =
    NotifierProvider<StickerLibraryController, StickerLibrary>(
      StickerLibraryController.new,
    );

/// Holds the sticker library; every change method returns the [Failure], or
/// null when it worked.
class StickerLibraryController extends Notifier<StickerLibrary> {
  @override
  StickerLibrary build() {
    ref.watch(currentUserIdProvider);
    unawaited(refresh());
    return const StickerLibrary();
  }

  /// Loads recents from the phone, favourites and albums from the server;
  /// a failed part keeps what was there.
  Future<void> refresh() async {
    final recent = await ref.read(recentStickerStoreProvider).load();
    final repo = ref.read(stickerRepositoryProvider);
    final favourites = await repo.favourites();
    final albums = await repo.albums();
    if (!ref.mounted) return;
    state = state.copyWith(
      recent: recent,
      favourites: switch (favourites) {
        Ok(:final value) => value,
        Err() => state.favourites,
      },
      albums: switch (albums) {
        Ok(:final value) => value,
        Err() => state.albums,
      },
      loaded: true,
    );
  }

  /// Puts [stickerId] first in the recents.
  Future<void> markUsed(String stickerId) async {
    state = state.copyWith(
      recent: [
        stickerId,
        ...state.recent.where((e) => e != stickerId),
      ].take(30).toList(),
    );
    await ref.read(recentStickerStoreProvider).use(stickerId);
  }

  /// Adds a sticker to the favourites.
  Future<Failure?> addFavourite(String id) async {
    final result = await ref.read(stickerRepositoryProvider).addFavourite(id);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          favourites: [id, ...state.favourites.where((e) => e != id)],
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Removes a sticker from the favourites.
  Future<Failure?> removeFavourite(String id) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .removeFavourite(id);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          favourites: state.favourites.where((e) => e != id).toList(),
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Makes a new album called [name]; returns its id or the failure.
  Future<({String? id, Failure? failure})> createAlbum(String name) async {
    final result = await ref.read(stickerRepositoryProvider).createAlbum(name);
    if (!ref.mounted) return (id: null, failure: null);
    switch (result) {
      case Ok(:final value):
        state = state.copyWith(
          albums: [
            ...state.albums,
            StickerAlbum(id: value, name: name.trim(), stickerIds: const []),
          ],
        );
        return (id: value, failure: null);
      case Err(:final failure):
        return (id: null, failure: failure);
    }
  }

  /// Renames an album.
  Future<Failure?> renameAlbum(String albumId, String name) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .renameAlbum(albumId, name);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          albums: [
            for (final a in state.albums)
              a.id == albumId ? _with(a, name: name.trim()) : a,
          ],
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Deletes an album.
  Future<Failure?> deleteAlbum(String albumId) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .deleteAlbum(albumId);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          albums: state.albums.where((a) => a.id != albumId).toList(),
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Puts a sticker into an album.
  Future<Failure?> addToAlbum(String albumId, String stickerId) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .addToAlbum(albumId, stickerId);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          albums: [
            for (final a in state.albums)
              a.id == albumId && !a.stickerIds.contains(stickerId)
                  ? _with(a, ids: [...a.stickerIds, stickerId])
                  : a,
          ],
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// Takes a sticker out of an album.
  Future<Failure?> removeFromAlbum(String albumId, String stickerId) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .removeFromAlbum(albumId, stickerId);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        state = state.copyWith(
          albums: [
            for (final a in state.albums)
              a.id == albumId
                  ? _with(
                      a,
                      ids: a.stickerIds.where((e) => e != stickerId).toList(),
                    )
                  : a,
          ],
        );
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// "Add album" on a shared card: copies it into a new own album.
  Future<Failure?> addSharedAlbum(String albumId) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .addSharedAlbum(albumId);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        await refresh();
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  /// "Add to favourites" on a shared card.
  Future<Failure?> addSharedAlbumToFavourites(String albumId) async {
    final result = await ref
        .read(stickerRepositoryProvider)
        .addSharedAlbumToFavourites(albumId);
    if (!ref.mounted) return null;
    switch (result) {
      case Ok():
        await refresh();
        return null;
      case Err(:final failure):
        return failure;
    }
  }

  StickerAlbum _with(StickerAlbum a, {String? name, List<String>? ids}) {
    return StickerAlbum(
      id: a.id,
      name: name ?? a.name,
      stickerIds: ids ?? a.stickerIds,
    );
  }
}

/// The sticker ids of an own or shared album.
final albumStickersProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, albumId) async {
      final result = await ref
          .read(stickerRepositoryProvider)
          .albumStickers(albumId);
      return switch (result) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: _never);

/// The bytes of a sticker that is not bundled in the app.
final stickerImageProvider = FutureProvider.family<Uint8List, String>((
  ref,
  stickerId,
) async {
  final result = await ref.read(stickerRepositoryProvider).image(stickerId);
  return switch (result) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: _never);

/// Forgets the recent stickers as soon as the session ends, like
/// [playedVoiceOwnerProvider].
final recentStickerOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(recentStickerStoreProvider).clear());
});
