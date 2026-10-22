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
  });
  final FlutterSecureStorage _storage;
  static const _name = 'sis.store.key';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// The saved key, or a new one saved first.
  Future<String> loadOrCreate() async {
    final key = await _storage.read(key: _name);
    if (key != null && _hex64.hasMatch(key)) {
      return key;
    }

    final bytes = List.generate(32, (_) => Random.secure().nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _name, value: hex);
    return hex;
  }

  /// The saved key, or null; never makes or writes one (a notification must not).
  Future<String?> read() async {
    final key = await _storage.read(key: _name);
    return key != null && _hex64.hasMatch(key) ? key : null;
  }

  /// Forgets the key (sign-out): the database file is unreadable without it.
  Future<void> delete() => _storage.delete(key: _name);
}
