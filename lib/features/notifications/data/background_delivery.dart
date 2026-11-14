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
    // The saved session is restored from secure storage by Supabase.initialize; no sign-in.
    try {
      Supabase.instance;
    } catch (_) {
      final cfg = RuntimeConfig.fromEnvironment();
      await Supabase.initialize(
        url: cfg.supabaseUrl,
        publishableKey: cfg.supabasePublishableKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          localStorage: SecureSessionStorage(),
        ),
      );
    }
    await Supabase.instance.client.rpc(
      'mark_delivered',
      params: {'conversation': conversationId, 'up_to': null},
    );
  }
}
