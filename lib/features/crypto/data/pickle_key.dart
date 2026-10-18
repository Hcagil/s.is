import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/key_directory.dart';

/// The key that encrypts the olm account pickle: 32 random bytes as 64 hex characters, made once and kept in the platform's secure storage (Keystore / Keychain).
final class PickleKey implements PickleKeyStore {
  const PickleKey({
    this._storage = const FlutterSecureStorage(
      // This device only: the key must never travel in an iCloud or Finder
      // backup together with the database file.
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  });
  final FlutterSecureStorage _storage;
  static const _name = 'sis.olm.pickle.key';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// The saved key, or a new one saved first.
  @override
  Future<List<int>> loadOrCreate() async {
    final key = await _storage.read(key: _name);
    if (key != null && _hex64.hasMatch(key)) {
      return List.generate(
        32,
        (i) => int.parse(key.substring(i * 2, i * 2 + 2), radix: 16),
      );
    }

    final bytes = List.generate(32, (_) => Random.secure().nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _name, value: hex);
    return bytes;
  }

  /// Forgets the key (sign-out): the pickle is unreadable without it.
  @override
  Future<void> delete() => _storage.delete(key: _name);
}
