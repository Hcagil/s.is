import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// A real‑server client whose HTTP DELETE calls (Storage remove) fail,
/// so a failing remove can be tested against the real repository.
class DeleteBlockedHost extends http.BaseClient {
  final http.Client _inner = http.Client();
  final deletes = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'DELETE') {
      deletes.add(request.url);
      throw const SocketException('storage remove blocked (test)');
    }
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

Future<SupabaseClient> deleteBlockedSignedIn(
  SupabaseClient live,
  DeleteBlockedHost host,
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
