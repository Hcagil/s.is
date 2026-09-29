import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/alert_settings.dart';
import 'local_push_display.dart';

/// [AlertStore] over shared_preferences. Thin on purpose (ARCHITECTURE rule
/// 4). Read in the background isolate too, so every load re-reads the disk.
final class SharedPrefsAlertStore implements AlertStore {
  const SharedPrefsAlertStore();

  static const _defaultsKey = 'sis.alert_defaults';
  static const _chatsKey = 'sis.alert_chats';

  @override
  Future<AlertDefaults> loadDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final json = prefs.getString(_defaultsKey);
    if (json == null) return const AlertDefaults();
    try {
      return AlertDefaults.fromJson(jsonDecode(json) as Map<String, Object?>);
    } catch (_) {
      return const AlertDefaults();
    }
  }

  @override
  Future<void> saveDefaults(AlertDefaults d) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultsKey, jsonEncode(d.toJson()));
    await _prune();
  }

  @override
  Future<Map<String, ChatAlert>> loadChats() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final json = prefs.getString(_chatsKey);
    if (json == null) return {};
    try {
      return {
        for (final e in (jsonDecode(json) as Map<String, Object?>).entries)
          if (e.value is Map<String, Object?>)
            e.key: ChatAlert.fromJson(e.value! as Map<String, Object?>),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> saveChat(String conversationId, ChatAlert c) async {
    final prefs = await SharedPreferences.getInstance();
    final chats = await loadChats();
    if (c.isDefault) {
      chats.remove(conversationId);
    } else {
      chats[conversationId] = c;
    }
    await prefs.setString(
      _chatsKey,
      jsonEncode(chats.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await _prune();
  }

  Future<void> _prune() async {
    try {
      await LocalPushDisplay.pruneChannels();
    } catch (_) {
      // Housekeeping only; the next start retries.
    }
  }
}
