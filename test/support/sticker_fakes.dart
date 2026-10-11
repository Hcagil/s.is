import 'dart:async';
import 'dart:typed_data';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/recent_sticker_store.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/domain/sticker_repository.dart';

/// One send that reached the "server" and waits for its answer.
class StickerSend {
  StickerSend(
    this.conversationId,
    this.messageId,
    this.stickerId,
    this.albumId,
    this.replyTo,
    this.forwarded,
  );
  final String conversationId;
  final String messageId;
  final String? stickerId; // a sticker send
  final String? albumId; // an album card send
  final String? replyTo;
  final bool forwarded;
  final answer = Completer<Result<void>>();
}

/// A [StickerRepository] that behaves like the server, from the contract:
/// sends are HELD until the test answers them (latency, ordering, a lost
/// answer); albums and favourites live in memory with the server's limits
/// (STKA1 at 10 albums, STKA2 at 50 per album, STKF1 at 200 favourites);
/// another member's album is DeniedFailure; [offline] makes every call a
/// retryable NetworkFailure. Albums list oldest first, favourites newest first.
class StickerRepoFake implements StickerRepository {
  StickerRepoFake({Map<String, List<String>>? shared, this.images = const {}})
    : shared = shared ?? {};

  final sends = <StickerSend>[];
  final albumList = <StickerAlbum>[];
  final favs = <String>[]; // newest first
  /// Albums shared to this member by others: id -> sticker ids.
  final Map<String, List<String>> shared;
  final Map<String, Uint8List> images;
  bool offline = false;

  /// Every change call, in order, e.g. 'addFavourite s1'.
  final calls = <String>[];

  /// Answers the next change call with this failure instead (once).
  Failure? failNext;

  var _n = 0;

  Result<T>? _gate<T>(String call) {
    calls.add(call);
    if (offline) {
      return Err(const NetworkFailure('offline', retryable: true));
    }
    final f = failNext;
    if (f != null) {
      failNext = null;
      return Err(f);
    }
    return null;
  }

  int _albumIndex(String id) => albumList.indexWhere((a) => a.id == id);

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    String stickerId, {
    String? replyTo,
    bool forwarded = false,
  }) {
    final s = StickerSend(
      conversationId,
      messageId,
      stickerId,
      null,
      replyTo,
      forwarded,
    );
    sends.add(s);
    return s.answer.future;
  }

  @override
  Future<Result<void>> sendAlbum(
    String conversationId,
    String messageId,
    String albumId,
  ) {
    final s = StickerSend(
      conversationId,
      messageId,
      null,
      albumId,
      null,
      false,
    );
    sends.add(s);
    return s.answer.future;
  }

  void ok(int i) => sends[i].answer.complete(const Ok(null));
  void fail(int i, Failure f) => sends[i].answer.complete(Err(f));

  @override
  Future<Result<List<StickerAlbum>>> albums() async =>
      _gate('albums') ?? Ok(List.of(albumList));

  @override
  Future<Result<List<String>>> favourites() async =>
      _gate('favourites') ?? Ok(List.of(favs));

  @override
  Future<Result<List<String>>> albumStickers(String albumId) async {
    final g = _gate<List<String>>('albumStickers $albumId');
    if (g != null) return g;
    final i = _albumIndex(albumId);
    if (i >= 0) return Ok(List.of(albumList[i].stickerIds));
    final s = shared[albumId];
    if (s != null) return Ok(List.of(s));
    return const Err(DeniedFailure());
  }

  @override
  Future<Result<String>> createAlbum(String name) async {
    final g = _gate<String>('createAlbum $name');
    if (g != null) return g;
    if (albumList.length >= maxStickerAlbums) {
      return const Err(StickerLimitFailure('STKA1'));
    }
    final id = 'album-${++_n}';
    albumList.add(StickerAlbum(id: id, name: name));
    return Ok(id);
  }

  @override
  Future<Result<void>> renameAlbum(String albumId, String name) async {
    final g = _gate<void>('renameAlbum $albumId $name');
    if (g != null) return g;
    final i = _albumIndex(albumId);
    if (i < 0) return const Err(DeniedFailure());
    final a = albumList[i];
    albumList[i] = StickerAlbum(id: a.id, name: name, stickerIds: a.stickerIds);
    return const Ok(null);
  }

  @override
  Future<Result<void>> deleteAlbum(String albumId) async {
    final g = _gate<void>('deleteAlbum $albumId');
    if (g != null) return g;
    final i = _albumIndex(albumId);
    if (i < 0) return const Err(DeniedFailure());
    albumList.removeAt(i);
    return const Ok(null);
  }

  @override
  Future<Result<void>> addToAlbum(String albumId, String stickerId) async {
    final g = _gate<void>('addToAlbum $albumId $stickerId');
    if (g != null) return g;
    final i = _albumIndex(albumId);
    if (i < 0) return const Err(DeniedFailure());
    final a = albumList[i];
    if (a.stickerIds.contains(stickerId)) return const Ok(null);
    if (a.stickerIds.length >= maxAlbumStickers) {
      return const Err(StickerLimitFailure('STKA2'));
    }
    albumList[i] = StickerAlbum(
      id: a.id,
      name: a.name,
      stickerIds: [...a.stickerIds, stickerId],
    );
    return const Ok(null);
  }

  @override
  Future<Result<void>> removeFromAlbum(String albumId, String stickerId) async {
    final g = _gate<void>('removeFromAlbum $albumId $stickerId');
    if (g != null) return g;
    final i = _albumIndex(albumId);
    if (i < 0) return const Err(DeniedFailure());
    final a = albumList[i];
    albumList[i] = StickerAlbum(
      id: a.id,
      name: a.name,
      stickerIds: [...a.stickerIds.where((s) => s != stickerId)],
    );
    return const Ok(null);
  }

  @override
  Future<Result<void>> addFavourite(String stickerId) async {
    final g = _gate<void>('addFavourite $stickerId');
    if (g != null) return g;
    if (favs.contains(stickerId)) return const Ok(null);
    if (favs.length >= maxFavouriteStickers) {
      return const Err(StickerLimitFailure('STKF1'));
    }
    favs.insert(0, stickerId);
    return const Ok(null);
  }

  @override
  Future<Result<void>> removeFavourite(String stickerId) async {
    final g = _gate<void>('removeFavourite $stickerId');
    if (g != null) return g;
    favs.remove(stickerId);
    return const Ok(null);
  }

  @override
  Future<Result<String>> addSharedAlbum(String albumId) async {
    final g = _gate<String>('addSharedAlbum $albumId');
    if (g != null) return g;
    final s = shared[albumId];
    if (s == null) return const Err(DeniedFailure());
    if (albumList.length >= maxStickerAlbums) {
      return const Err(StickerLimitFailure('STKA1'));
    }
    final id = 'album-${++_n}';
    albumList.add(StickerAlbum(id: id, name: 'Copy', stickerIds: List.of(s)));
    return Ok(id);
  }

  @override
  Future<Result<int>> addSharedAlbumToFavourites(String albumId) async {
    final g = _gate<int>('addSharedAlbumToFavourites $albumId');
    if (g != null) return g;
    final s = shared[albumId];
    if (s == null) return const Err(DeniedFailure());
    final add = [...s.where((x) => !favs.contains(x))];
    if (favs.length + add.length > maxFavouriteStickers) {
      return const Err(StickerLimitFailure('STKF1'));
    }
    favs.insertAll(0, add.reversed);
    return Ok(add.length);
  }

  @override
  Future<Result<Uint8List>> image(String stickerId) async {
    if (offline) return Err(const NetworkFailure('offline', retryable: true));
    final b = images[stickerId];
    return b == null ? const Err(DeniedFailure()) : Ok(b);
  }
}

/// The phone's recent list, in memory, with the store's rules: newest first,
/// one copy each, at most 30.
class RecentStickerStoreFake implements RecentStickerStore {
  RecentStickerStoreFake([List<String>? initial]) : ids = initial ?? [];
  final List<String> ids;
  var cleared = 0;

  @override
  Future<List<String>> load() async => List.of(ids);

  @override
  Future<void> use(String stickerId) async {
    ids
      ..remove(stickerId)
      ..insert(0, stickerId);
    if (ids.length > 30) ids.removeRange(30, ids.length);
  }

  @override
  Future<void> clear() async {
    cleared++;
    ids.clear();
  }
}
