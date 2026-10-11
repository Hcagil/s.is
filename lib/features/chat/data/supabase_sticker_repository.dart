import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/sticker.dart';
import '../domain/sticker_repository.dart';

/// [StickerRepository] backed by server functions; all writes go through the
/// server functions so limits (10 albums, 50 per album, 200 favourites) are
/// enforced there.
final class SupabaseStickerRepository implements StickerRepository {
  SupabaseStickerRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    String stickerId, {
    String? replyTo,
    bool forwarded = false,
  }) async {
    try {
      await _client.rpc(
        'send_sticker',
        params: {
          'p_conversation': conversationId,
          'p_id': messageId,
          'p_sticker': stickerId,
          'p_reply_to': replyTo,
          'p_forwarded': forwarded,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> sendAlbum(
    String conversationId,
    String messageId,
    String albumId,
  ) async {
    try {
      await _client.rpc(
        'send_sticker_album',
        params: {
          'p_conversation': conversationId,
          'p_id': messageId,
          'p_album': albumId,
        },
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<List<StickerAlbum>>> albums() async {
    try {
      final rows = await _client
          .from('sticker_albums')
          .select('id, name')
          .order('created_at', ascending: true)
          .retriedOnce();
      final items = await _client
          .from('sticker_album_items')
          .select('album_id, sticker_id')
          .order('added_at', ascending: true)
          .retriedOnce();

      final by = <String, List<String>>{};
      for (final item in items) {
        final albumId = item['album_id'] as String;
        by.putIfAbsent(albumId, () => []).add(item['sticker_id'] as String);
      }

      return Ok([
        for (final r in rows)
          StickerAlbum(
            id: r['id'] as String,
            name: r['name'] as String,
            stickerIds: by[r['id']] ?? const [],
          ),
      ]);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<List<String>>> favourites() async {
    try {
      final rows = await _client
          .from('sticker_favourites')
          .select('sticker_id')
          .order('added_at', ascending: false)
          .retriedOnce();
      return Ok([for (final r in rows) r['sticker_id'] as String]);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<List<String>>> albumStickers(String albumId) async {
    try {
      final r = await _client.rpc(
        'album_stickers',
        params: {'p_album': albumId},
      );
      return Ok([for (final e in r as List) e as String]);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<String>> createAlbum(String name) async {
    try {
      final r = await _client.rpc(
        'create_sticker_album',
        params: {'p_name': name},
      );
      return Ok(r as String);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> renameAlbum(String albumId, String name) async {
    try {
      await _client.rpc(
        'rename_sticker_album',
        params: {'p_album': albumId, 'p_name': name},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> deleteAlbum(String albumId) async {
    try {
      await _client.rpc('delete_sticker_album', params: {'p_album': albumId});
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> addToAlbum(String albumId, String stickerId) async {
    try {
      await _client.rpc(
        'add_sticker_to_album',
        params: {'p_album': albumId, 'p_sticker': stickerId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> removeFromAlbum(String albumId, String stickerId) async {
    try {
      await _client.rpc(
        'remove_sticker_from_album',
        params: {'p_album': albumId, 'p_sticker': stickerId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> addFavourite(String stickerId) async {
    try {
      await _client.rpc(
        'add_sticker_favourite',
        params: {'p_sticker': stickerId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<void>> removeFavourite(String stickerId) async {
    try {
      await _client.rpc(
        'remove_sticker_favourite',
        params: {'p_sticker': stickerId},
      );
      return const Ok(null);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<String>> addSharedAlbum(String albumId) async {
    try {
      final r = await _client.rpc(
        'add_shared_album',
        params: {'p_album': albumId},
      );
      return Ok(r as String);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<int>> addSharedAlbumToFavourites(String albumId) async {
    try {
      final r = await _client.rpc(
        'add_shared_album_to_favourites',
        params: {'p_album': albumId},
      );
      return Ok((r as num).toInt());
    } catch (e) {
      return Err(_fail(e));
    }
  }

  @override
  Future<Result<Uint8List>> image(String stickerId) async {
    try {
      final bytes = await _client.storage
          .from('stickers')
          .download('$stickerId.webp');
      return Ok(bytes);
    } catch (e) {
      return Err(_fail(e));
    }
  }

  Failure _fail(Object e) {
    if (e is PostgrestException) {
      switch (e.code) {
        case '42501':
          return const DeniedFailure();
        case 'STKA1':
        case 'STKA2':
        case 'STKF1':
          return StickerLimitFailure(e.code!);
        default:
          return readableFailure(e);
      }
    } else {
      return readableFailure(e);
    }
  }
}
