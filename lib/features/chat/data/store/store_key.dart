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

  /// Keeps the key in the iOS crypto keychain group; the old default group is only a fallback and is cleared on sign-out.
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

  Future<String?> _read(FlutterSecureStorage? s) async {
    final v = await s?.read(key: _name);
    return v != null && _hex64.hasMatch(v) ? v : null;
  }

  /// The saved key, or a new one saved first; [setAsideStore] runs only when the key is missing in both iOS keychain groups.
  Future<String> loadOrCreate({Future<void> Function()? setAsideStore}) async {
    final key = await _read(_storage) ?? await _read(_legacy);
    if (key != null) return key;

    // Only with the iOS crypto group (_legacy set): the key is in neither group, so an existing database file can never be opened again. It is set aside (renamed, never deleted) before a new key is made.
    if (_legacy != null) await setAsideStore?.call();

    final bytes = List.generate(32, (_) => Random.secure().nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _name, value: hex);
    return hex;
  }

  /// The saved key from either keychain group, or null. Never creates or writes.
  Future<String?> peek() async => await _read(_storage) ?? await _read(_legacy);

  /// The saved key, or null; never makes or writes one (a notification must not).
  Future<String?> read() => peek();

  /// Forgets the key (sign-out): the database file is unreadable without it.
  Future<void> delete() async {
    await _storage.delete(key: _name);
    await _legacy?.delete(key: _name);
  }
}
