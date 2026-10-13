import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/voice.dart';

/// [PlayedVoiceStore] over shared_preferences: per member, never synced.
final class SharedPrefsPlayedVoiceStore implements PlayedVoiceStore {
  /// Creates the store.
  const SharedPrefsPlayedVoiceStore();

  static const _key = 'sis.voice.played';

  @override
  Future<Set<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key) ?? const []).toSet();
    } catch (e) {
      log('Loading played voices failed: ${e.runtimeType}', name: 'sis.voice');
      return const {};
    }
  }

  @override
  Future<void> add(String messageId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_key) ?? const [];
      if (list.contains(messageId)) return;
      final all = [...list, messageId];
      await prefs.setStringList(
        _key,
        all.length > 2000 ? all.sublist(all.length - 2000) : all,
      );
    } catch (e) {
      log('Adding a played voice failed: ${e.runtimeType}', name: 'sis.voice');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      log('Clearing played voices failed: ${e.runtimeType}', name: 'sis.voice');
    }
  }
}
