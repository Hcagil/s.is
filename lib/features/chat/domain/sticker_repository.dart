import 'dart:typed_data';

import '../../../core/failure.dart';
import 'sticker.dart';

/// The boundary for stickers, favourites and albums. A repository never throws: a refusal arrives as [Err] with a typed [Failure]. DeniedFailure for 42501; StickerLimitFailure (code 'STKA1' albums, 'STKA2' stickers in an album, 'STKF1' favourites) for a limit; a retryable NetworkFailure when offline.
abstract interface class StickerRepository {
  /// Stores the sticker message [messageId] (client-generated id: a retry with the same id is harmless) in [conversationId]. [replyTo] answers a message of that chat; [forwarded] marks a forward.
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    String stickerId, {
    String? replyTo,
    bool forwarded = false,
  });

  /// Stores an album card for the member's own album [albumId] as message [messageId].
  Future<Result<void>> sendAlbum(
    String conversationId,
    String messageId,
    String albumId,
  );

  /// The member's own albums, each with its sticker ids, oldest first.
  Future<Result<List<StickerAlbum>>> albums();

  /// The member's favourite sticker ids, newest first.
  Future<Result<List<String>>> favourites();

  /// The sticker ids of an own or shared album, oldest first.
  Future<Result<List<String>>> albumStickers(String albumId);

  /// Makes a private album called [name]; returns its id.
  Future<Result<String>> createAlbum(String name);

  /// Renames the member's own album.
  Future<Result<void>> renameAlbum(String albumId, String name);

  /// Deletes the member's own album (its stickers stay elsewhere).
  Future<Result<void>> deleteAlbum(String albumId);

  /// Puts a sticker the member can read into one of their albums.
  Future<Result<void>> addToAlbum(String albumId, String stickerId);

  /// Takes a sticker out of one of the member's albums.
  Future<Result<void>> removeFromAlbum(String albumId, String stickerId);

  /// Adds a sticker to the member's favourites.
  Future<Result<void>> addFavourite(String stickerId);

  /// Removes a sticker from the member's favourites.
  Future<Result<void>> removeFavourite(String stickerId);

  /// "Add album" on a shared album card: copies it into a new private album; returns its id.
  Future<Result<String>> addSharedAlbum(String albumId);

  /// "Add to favourites" on a shared album card; returns how many were added.
  Future<Result<int>> addSharedAlbumToFavourites(String albumId);

  /// The image bytes (WebP) of a sticker that is not bundled in the app (not a starter).
  Future<Result<Uint8List>> image(String stickerId);
}
