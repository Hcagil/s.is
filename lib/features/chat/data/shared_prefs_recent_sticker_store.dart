import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/recent_sticker_store.dart';

/// [RecentStickerStore] over shared_preferences: per member, never synced.
final class SharedPrefsRecentStickerStore implements RecentStickerStore {
  /// Creates the store.
  const SharedPrefsRecentStickerStore();

  static const _key = 'sis.stickers.recent';

  @override
  Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? const [];
    } catch (e) {
      log(
        'Loading recent stickers failed: ${e.runtimeType}',
        name: 'sis.stickers',
      );
      return const [];
    }
  }

  @override
  Future<void> use(String stickerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_key) ?? const [];
      final all = [
        stickerId,
        ...list.where((e) => e != stickerId),
      ].take(30).toList();
      await prefs.setStringList(_key, all);
    } catch (e) {
      log(
        'Adding a recent sticker failed: ${e.runtimeType}',
        name: 'sis.stickers',
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      log(
        'Clearing recent stickers failed: ${e.runtimeType}',
        name: 'sis.stickers',
      );
    }
  }
}
