import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The key that encrypts the on-phone message database: 32 random bytes as 64 hex characters, made once and kept in the platform's secure storage (Keystore / Keychain).
final class StoreKey {
  const StoreKey({
    this._storage = const FlutterSecureStorage(
      // This device only: the key must never travel in an iCloud or Finder
      // backup together with the database file.
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
    this._legacy,
  });

  /// Keeps the key in the iOS crypto keychain group; sign-out also clears the old default group.
  StoreKey.inGroup(String? group)
    : this(
        storage: _inGroup(group),
        legacy: group == null ? null : _inGroup(null),
      );
  final FlutterSecureStorage _storage;

  static FlutterSecureStorage _inGroup(String? group) => FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      groupId: group,
    ),
  );
  final FlutterSecureStorage? _legacy;
  static const _name = 'sis.store.key';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// The saved key, or a new one saved first. With [mayCreate] false (the database file already exists) a missing key is an error and nothing is created: a new key would lock the existing database for good.
  Future<String> loadOrCreate({bool mayCreate = true}) async {
    final key = await _storage.read(key: _name);
    if (key != null && _hex64.hasMatch(key)) {
      return key;
    }
    if (!mayCreate) {
      throw StateError('the store key is missing but the store file exists');
    }

    final bytes = List.generate(32, (_) => Random.secure().nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _name, value: hex);
    return hex;
  }

  /// Forgets the key (sign-out): the database file is unreadable without it.
  Future<void> delete() async {
    await _storage.delete(key: _name);
    await _legacy?.delete(key: _name);
  }
}
