import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The `session_id` claim of [client]'s access token, as the app reads it.
String? sessionIdOf(SupabaseClient client) {
  final token = client.auth.currentSession?.accessToken;
  if (token == null) return null;
  final payload = token.split('.')[1];
  final claims = jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(payload))),
  );
  return (claims as Map)['session_id'] as String?;
}
