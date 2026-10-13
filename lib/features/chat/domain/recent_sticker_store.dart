/// The stickers this member sent most recently, kept on this phone.
abstract interface class RecentStickerStore {
  /// The sticker ids, newest first (at most 30).
  Future<List<String>> load();

  /// Puts [stickerId] first; an older copy of it moves out. Keeps at most 30.
  Future<void> use(String stickerId);

  /// Forgets everything (sign-out).
  Future<void> clear();
}
