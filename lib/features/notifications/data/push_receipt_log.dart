import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A small on-phone ring buffer of push receipts (what became of each push),
/// newest last, at most [_max]. Runs in the app AND in the FCM background
/// isolate, so every read reloads shared preferences first.
///
/// It exists because the background isolate has no Supabase session (two
/// isolates refreshing one rotating refresh token could sign the member out):
/// the app uploads the receipts on its next open. Never holds message text.
final class PushReceiptLog {
  PushReceiptLog._();

  static const _prefsKey = 'sis.push_receipts';
  static const _max = 50;
  static int? _build;

  /// Never throws: a receipt must not be able to break what it reports on.
  static Future<void> add(
    String stage, {
    String? messageId,
    Object? error,
    String? label,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final entries = [...?prefs.getStringList(_prefsKey)];
      if (entries.length >= _max) {
        entries.removeRange(0, entries.length - _max + 1);
      }
      final build = await _buildNumber();
      entries.add(
        jsonEncode({
          'stage': stage,
          'message_id': ?messageId,
          'error': ?(error == null ? null : _errorText(error, label)),
          'build': ?build,
          'occurred_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await prefs.setStringList(_prefsKey, entries);
    } catch (_) {}
  }

  static Future<List<Map<String, Object?>>> pending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final out = <Map<String, Object?>>[];
      for (final s in prefs.getStringList(_prefsKey) ?? const <String>[]) {
        try {
          out.add((jsonDecode(s) as Map).cast<String, Object?>());
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Drops the [count] oldest receipts (the ones just uploaded).
  static Future<void> removeFirst(int count) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final entries = [...?prefs.getStringList(_prefsKey)];
      await prefs.setStringList(
        _prefsKey,
        entries.length <= count ? [] : entries.sublist(count),
      );
    } catch (_) {}
  }

  /// Removes exactly what was uploaded, so receipts the background isolate
  /// appended meanwhile (or that a full ring rotated) are never deleted by
  /// count.
  static Future<void> removeUploaded(
    List<Map<String, Object?>> uploaded,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final sent = {for (final m in uploaded) jsonEncode(m)};
      final rest = [
        for (final e in prefs.getStringList(_prefsKey) ?? const <String>[])
          if (!sent.contains(e)) e,
      ];
      await prefs.setStringList(_prefsKey, rest);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  static Future<int?> _buildNumber() async {
    if (_build != null) return _build;
    try {
      return _build = int.tryParse(
        (await PackageInfo.fromPlatform()).buildNumber,
      );
    } catch (_) {
      return null;
    }
  }

  /// The exception's runtime type only, never its text: it can quote a push
  /// or a device path, and a receipt leaves the phone.
  static String _errorText(Object e, String? label) =>
      label == null ? '${e.runtimeType}' : '$label: ${e.runtimeType}';
}
