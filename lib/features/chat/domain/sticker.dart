/// Maximum number of sticker albums a user can create.
const int maxStickerAlbums = 10;

/// Maximum number of stickers per album.
const int maxAlbumStickers = 50;

/// Maximum number of favorite stickers a user can have.
const int maxFavouriteStickers = 200;

/// Number of starter stickers provided by the app.
const int starterStickerCount = 16;

/// Preview text for a sticker.
const String stickerPreviewText = '\u{1F600} Sticker';

/// Preview text for a sticker album.
const String stickerAlbumPreviewText = '\u{1F4C2} Sticker album';

/// Prefix used for generating starter sticker IDs.
const String _starterPrefix = '5151c000-0000-4000-8000-';

/// Generates a sticker ID for a starter sticker with index [n].
String starterStickerId(int n) {
  if (n < 1 || n > starterStickerCount) {
    throw RangeError(
      'Sticker index must be between 1 and $starterStickerCount',
    );
  }
  return '$_starterPrefix${n.toString().padLeft(12, '0')}';
}

/// List of all starter sticker IDs.
final List<String> starterStickerIds = List.unmodifiable([
  for (var n = 1; n <= starterStickerCount; n++) starterStickerId(n),
]);

/// Returns the index of a starter sticker ID, or null if not a starter sticker.
int? starterIndex(String id) {
  if (!id.startsWith(_starterPrefix)) return null;
  final suffix = id.substring(_starterPrefix.length);
  if (suffix.length != 12) return null;
  final index = int.tryParse(suffix);
  return index != null && index >= 1 && index <= starterStickerCount
      ? index
      : null;
}

/// Checks if a sticker ID is a starter sticker.
bool isStarterSticker(String id) => starterIndex(id) != null;

/// Returns the asset path for a starter sticker ID.
String? starterAsset(String id) {
  final index = starterIndex(id);
  if (index == null) return null;
  return 'assets/stickers/starter_${index.toString().padLeft(2, '0')}.webp';
}

/// A sticker album with a unique ID and name.
final class StickerAlbum {
  /// Creates a new sticker album.
  const StickerAlbum({
    required this.id,
    required this.name,
    this.stickerIds = const [],
  });

  /// Unique identifier for the sticker album.
  final String id;

  /// Name of the sticker album.
  final String name;

  /// List of sticker IDs in the album.
  final List<String> stickerIds;
}
