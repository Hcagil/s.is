import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/notification_settings.dart';

/// Settings and mutes live in the member's own rows; row-level security
/// refuses anything else (DeniedFailure).
final class SupabaseNotificationSettingsRepository
    implements NotificationSettingsRepository {
  SupabaseNotificationSettingsRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<NotificationSettings>> load() async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('notification_settings')
          .select('enabled, preview')
          .eq('user_id', uid)
          .maybeSingle()
          .retriedOnce();
      if (row == null) return const Ok(NotificationSettings());
      return Ok(
        NotificationSettings(
          enabled: row['enabled'] as bool,
          preview: NotificationPreview.values.byName(row['preview'] as String),
        ),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> save(NotificationSettings settings) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client.from('notification_settings').upsert({
        'user_id': uid,
        'enabled': settings.enabled,
        'preview': settings.preview.name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<List<Mute>>> mutes() async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final rows = await _client
          .from('notification_mutes')
          .select('kind, target, until')
          .eq('user_id', uid)
          .retriedOnce();
      return Ok(
        rows
            .map(
              (r) => Mute(
                kind: MuteKind.values.byName(r['kind'] as String),
                target: r['target'] as String,
                until: r['until'] == null
                    ? null
                    : DateTime.parse(r['until'] as String),
              ),
            )
            .toList(),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> mute(
    MuteKind kind,
    String target,
    DateTime? until,
  ) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client.from('notification_mutes').upsert({
        'user_id': uid,
        'kind': kind.name,
        'target': target,
        'until': until?.toUtc().toIso8601String(),
      }, onConflict: 'user_id,kind,target');
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> unmute(MuteKind kind, String target) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client
          .from('notification_mutes')
          .delete()
          .eq('user_id', uid)
          .eq('kind', kind.name)
          .eq('target', target);
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}
