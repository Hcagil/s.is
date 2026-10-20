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
    this._legacy,
    this._hasPickles,
  });

  /// Keeps the key in the iOS crypto keychain group; the old default group is only a fallback and is cleared on sign-out. [hasPickles] says whether olm pickles are already stored.
  PickleKey.inGroup(String? group, {Future<bool> Function()? hasPickles})
    : this(
        storage: _inGroup(group),
        legacy: group == null ? null : _inGroup(null),
        hasPickles: hasPickles,
      );
  final FlutterSecureStorage _storage;
  final Future<bool> Function()? _hasPickles;

  static FlutterSecureStorage _inGroup(String? group) => FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      groupId: group,
    ),
  );
  final FlutterSecureStorage? _legacy;
  static const _name = 'sis.olm.pickle.key';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// The saved key, or a new one saved first.
  @override
  Future<List<int>> loadOrCreate() async {
    final key = await _read(_storage) ?? await _read(_legacy);
    if (key != null) {
      return List.generate(
        32,
        (i) => int.parse(key.substring(i * 2, i * 2 + 2), radix: 16),
      );
    }

    // iOS crypto group in use and pickles already stored: a new key would make them unreadable for good, so never make one silently.
    if (_legacy != null && await (_hasPickles?.call() ?? Future.value(false))) {
      throw StateError('the pickle key is missing but pickles are stored');
    }

    final bytes = List.generate(32, (_) => Random.secure().nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _name, value: hex);
    return bytes;
  }

  Future<String?> _read(FlutterSecureStorage? s) async {
    final v = await s?.read(key: _name);
    return v != null && _hex64.hasMatch(v) ? v : null;
  }

  /// True when a valid key is saved in either keychain group. Never creates or writes.
  Future<bool> exists() async =>
      await _read(_storage) != null || await _read(_legacy) != null;

  /// Forgets the key (sign-out): the pickle is unreadable without it.
  @override
  Future<void> delete() async {
    await _storage.delete(key: _name);
    await _legacy?.delete(key: _name);
  }
}
