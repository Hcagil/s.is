import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/runtime_config.dart';
import '../../crypto/data/keychain_group.dart';

final class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage({
    this._group = cryptoKeychainGroup,
    this._deliveryStorage = _inGroup,
  });

  final Future<String?> Function() _group;
  final FlutterSecureStorage Function(String group) _deliveryStorage;

  static const _key = 'sis.supabase.session';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  static const _deliveryKey = 'sis.push.delivery';

  static FlutterSecureStorage _inGroup(String group) => FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      groupId: group,
    ),
  );

  @override
  Future<void> initialize() async {}

  // A failed read throws (never "no session"): Supabase.initialize then fails into
  // the start-up failure screen, and no session-end wipe runs. resetOnError stays off.
  @override
  Future<String?> accessToken() => _storage.read(key: _key);
  @override
  Future<bool> hasAccessToken() async => await _storage.read(key: _key) != null;

  @override
  Future<void> persistSession(String persistSessionString) async {
    await _storage.write(key: _key, value: persistSessionString);
    await _writeDelivery(persistSessionString);
  }

  // The iPhone notification extension reads this small item to mark a message delivered; it holds no refresh token.
  Future<void> _writeDelivery(String s) async {
    try {
      final group = await _group();
      if (group == null) return;

      final decoded = jsonDecode(s) as Map<String, dynamic>;
      final token = decoded['access_token'] as String?;
      final expiresAt = decoded['expires_at'] as int?;
      final user = decoded['user'] as Map<String, dynamic>?;
      final userId = user?['id'] as String?;

      if (token == null ||
          token.isEmpty ||
          expiresAt == null ||
          userId == null) {
        return;
      }

      final cfg = RuntimeConfig.fromEnvironment();
      await _deliveryStorage(group).write(
        key: _deliveryKey,
        value: jsonEncode({
          'access_token': token,
          'expires_at': expiresAt,
          'user_id': userId,
          'url': cfg.supabaseUrl,
          'key': cfg.supabasePublishableKey,
        }),
      );
    } on Object {
      return;
    }
  }

  @override
  Future<void> removePersistedSession() async {
    await _storage.delete(key: _key);
    try {
      final group = await _group();
      if (group != null) {
        await _deliveryStorage(group).delete(key: _deliveryKey);
      }
    } on Object {
      // A failed delete of the small item never fails the sign-out.
      return;
    }
  }
}
