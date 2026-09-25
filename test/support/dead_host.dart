import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Nothing listens here: a server that is not there at all. The port is
/// refused at once, so every attempt fails without waiting on a timeout.
const deadUrl = 'http://127.0.0.1:1';

const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

/// A client for [deadUrl], for the offline path of a repository.
///
/// A table read through it fails only after about 7 s: PostgREST retries a
/// failed GET three times (1 s, 2 s, 4 s) before it rethrows the network
/// error, exactly as the app does offline. That cannot be switched off from
/// here: supabase 2.16.1's `SupabaseClient.from()` does not pass
/// `PostgrestClientOptions.retryEnabled` on to the query it builds. An RPC
/// (a POST) is never retried and fails at once.
SupabaseClient deadHostClient() => SupabaseClient(
  deadUrl,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

/// A [deadHostClient] carrying [live]'s real, unexpired session.
///
/// A repository call that first checks `auth.currentUser` returns
/// `DeniedFailure` on an unauthenticated client before a socket ever opens,
/// proving nothing about the offline message. `recoverSession` only decodes
/// the session and checks its expiry locally: no request leaves the device.
Future<SupabaseClient> deadButSignedIn(SupabaseClient live) async {
  final dead = deadHostClient();
  await dead.auth.recoverSession(
    jsonEncode(live.auth.currentSession!.toJson()),
  );
  return dead;
}
