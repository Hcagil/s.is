import 'dart:convert';
import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/staff_registry.dart';
import '../domain/staff_registry_repository.dart';

/// [StaffRegistryRepository] backed by the staff_registry RPC and a local copy; the server decides who sees what.
class SupabaseStaffRegistryRepository implements StaffRegistryRepository {
  /// Creates the repository with the given Supabase client.
  SupabaseStaffRegistryRepository(this._client);

  final SupabaseClient _client;

  static const _prefix = 'sis.staff.registry';

  // One copy per account, so a second sign-in on the phone never reads the first one's registry.
  String? get _key {
    final id = _client.auth.currentUser?.id;
    return id == null || id.isEmpty ? null : '$_prefix.$id';
  }

  @override
  Future<StaffRegistry?> cached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _key;
      final stored = key == null ? null : prefs.getString(key);
      if (stored == null) return null;
      final decoded = jsonDecode(stored);
      return decoded is Map<String, dynamic>
          ? StaffRegistry.fromJson(decoded)
          : null;
    } catch (e) {
      log(
        'Loading the staff registry failed: ${e.runtimeType}',
        name: 'sis.staff',
      );
      return null;
    }
  }

  @override
  Future<Result<StaffRegistry>> refresh() async {
    try {
      final rows = await _client.rpc('staff_registry');
      final registry = StaffRegistry.fromRows([
        for (final r in rows as List)
          if (r is Map) Map<String, Object?>.from(r),
      ]);
      try {
        final prefs = await SharedPreferences.getInstance();
        final key = _key;
        if (key != null) {
          await prefs.setString(key, jsonEncode(registry.toJson()));
        }
      } catch (e) {
        log(
          'Storing the staff registry failed: ${e.runtimeType}',
          name: 'sis.staff',
        );
      }
      return Ok(registry);
    } on PostgrestException catch (e) {
      return Err(
        e.code == '42501' ? const DeniedFailure() : readableFailure(e),
      );
    } catch (e) {
      return Err(readableFailure(e));
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Every account's copy goes, even when the user is already signed out.
      for (final k in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
        await prefs.remove(k);
      }
    } catch (e) {
      log(
        'Clearing the staff registry failed: ${e.runtimeType}',
        name: 'sis.staff',
      );
    }
  }
}
