import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/runtime_config.dart';
import '../../auth/data/secure_session_storage.dart';

/// Marks a chat as delivered from a push handled in a background isolate.
abstract interface class BackgroundDelivery {
  /// The saved session's user id, or null when no session is saved.
  Future<String?> savedUserId();

  /// Calls the server mark_delivered(conv, null) for this chat.
  Future<void> markDelivered(String conversationId);
}

final class SupabaseBackgroundDelivery implements BackgroundDelivery {
  const SupabaseBackgroundDelivery();

  @override
  Future<String?> savedUserId() async {
    final raw = await const SecureSessionStorage().accessToken();
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final user = decoded['user'];
    if (user is! Map) return null;
    final id = user['id'];
    if (id is String && id.isNotEmpty) return id;
    return null;
  }

  @override
  Future<void> markDelivered(String conversationId) async {
    // A plain client with the stored access token: no auth client, no refresh, no storage writes.
    final session = await _stored();
    if (session == null) return;
    final token = session['access_token'];
    if (token is! String || token.isEmpty) return;
    final expiresAt = session['expires_at'];
    if (expiresAt is! num) return;
    // Expired or about to: skip; the foreground marks delivery when the app opens.
    if (expiresAt * 1000 <= DateTime.now().millisecondsSinceEpoch + 30000) {
      return;
    }
    final cfg = RuntimeConfig.fromEnvironment();
    final client = SupabaseClient(
      cfg.supabaseUrl,
      cfg.supabasePublishableKey,
      accessToken: () async => token,
    );
    try {
      await client.rpc(
        'mark_delivered',
        params: {'conversation': conversationId, 'up_to': null},
      );
    } finally {
      await client.dispose();
    }
  }

  /// Reads the stored session JSON (read only; never written from here).
  Future<Map<String, dynamic>?> _stored() async {
    final raw = await const SecureSessionStorage().accessToken();
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
