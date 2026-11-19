import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
import '../domain/alert_settings.dart';

AlertChoice _choice(Object? t) => switch (t) {
  'on' => AlertChoice.on,
  'off' => AlertChoice.off,
  _ => AlertChoice.byDefault,
};

String _text(AlertChoice c) => switch (c) {
  AlertChoice.on => 'on',
  AlertChoice.off => 'off',
  AlertChoice.byDefault => 'default',
};

/// Alert settings live in the member's own rows; row-level security
/// refuses anything else (DeniedFailure).
final class SupabaseAlertRemote implements AlertRemote {
  SupabaseAlertRemote(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<RemoteAlerts>> load() async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final row = await _client
          .from('notification_settings')
          .select('alert_sound, alert_vibration')
          .eq('user_id', uid)
          .maybeSingle()
          .retriedOnce();
      final rows = await _client
          .from('chat_alert_settings')
          .select('conversation_id, sound, vibration')
          .eq('user_id', uid)
          .retriedOnce();
      final chats = <String, ChatAlert>{};
      for (final r in rows) {
        final alert = ChatAlert(
          sound: _choice(r['sound']),
          vibration: _choice(r['vibration']),
        );
        if (!alert.isDefault) {
          chats[r['conversation_id'] as String] = alert;
        }
      }
      return Ok(
        RemoteAlerts(
          sound: row?['alert_sound'] as bool?,
          vibration: row?['alert_vibration'] as bool?,
          chats: chats,
        ),
      );
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> saveDefaults({
    required bool sound,
    required bool vibration,
  }) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client.from('notification_settings').upsert({
        'user_id': uid,
        'alert_sound': sound,
        'alert_vibration': vibration,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> saveChat(String conversationId, ChatAlert c) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      if (c.isDefault) {
        await _client
            .from('chat_alert_settings')
            .delete()
            .eq('user_id', uid)
            .eq('conversation_id', conversationId);
      } else {
        await _client.from('chat_alert_settings').upsert({
          'user_id': uid,
          'conversation_id': conversationId,
          'sound': _text(c.sound),
          'vibration': _text(c.vibration),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'user_id,conversation_id');
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}
