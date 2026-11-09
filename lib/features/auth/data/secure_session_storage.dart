import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage();
  static const _key = 'sis.supabase.session';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  @override
  Future<void> initialize() async {}

  // A failed read is "no session yet", never a delete: the stored session stays for the next run.
  @override
  Future<String?> accessToken() async {
    try {
      return await _storage.read(key: _key);
    } on Object {
      return null;
    }
  }

  // A failed read is "no session yet", never a delete: the stored session stays for the next run.
  @override
  Future<bool> hasAccessToken() async {
    try {
      return await _storage.read(key: _key) != null;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
