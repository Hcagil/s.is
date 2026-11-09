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

  // A failed read throws (never "no session"): Supabase.initialize then fails into
  // the start-up failure screen, and no session-end wipe runs. resetOnError stays off.
  @override
  Future<String?> accessToken() => _storage.read(key: _key);
  @override
  Future<bool> hasAccessToken() async => await _storage.read(key: _key) != null;

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}
