import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// A client for the real local server whose network can be switched off and on;
/// recoverSession is local only.
class SwitchableHost extends http.BaseClient {
  SwitchableHost({this.online = false});

  bool online;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!online) throw const SocketException('offline (test)');
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);

const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

Future<SupabaseClient> switchableSignedIn(
  SupabaseClient live,
  SwitchableHost host,
) async {
  final c = SupabaseClient(
    _url,
    _key,
    httpClient: host,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await c.auth.recoverSession(jsonEncode(live.auth.currentSession!.toJson()));
  return c;
}
