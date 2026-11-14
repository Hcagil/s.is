import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/admin_draft_store.dart';

/// Admin panel drafts in the platform's secure storage (Keystore / Keychain), in their own entry.
final class SecureAdminDraftStore implements AdminDraftStore {
  SecureAdminDraftStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // A read error must never delete the entry: it is treated as no drafts.
            aOptions: AndroidOptions(resetOnError: false),
            // This device only: drafts must never travel in an iCloud or Finder backup.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _name = 'sis.admin.drafts';
  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> load() async {
    try {
      final raw = await _storage.read(key: _name);
      if (raw == null) return {};
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['v'] != 1) return {};
      final d = json['d'];
      if (d is! Map<String, dynamic>) return {};
      return {
        for (final e in d.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, String> drafts) async {
    try {
      if (drafts.isEmpty) {
        await _storage.delete(key: _name);
        return;
      }
      await _storage.write(
        key: _name,
        value: jsonEncode({'v': 1, 'd': drafts}),
      );
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _name);
    } catch (_) {}
  }
}
