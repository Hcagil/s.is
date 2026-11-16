import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// A real‑server client that records every HTTP request, so a test can
/// prove which calls a repository made.
class RequestLogHost extends http.BaseClient {
  final http.Client _inner = http.Client();
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();

  /// Returns all non‑GET/HEAD requests to Storage endpoints.
  List<http.BaseRequest> get storageWrites => [
    for (final r in requests)
      if (r.url.path.contains('/storage/v1/') &&
          r.method != 'GET' &&
          r.method != 'HEAD')
        r,
  ];
}

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);

const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

Future<SupabaseClient> loggedSignedIn(
  SupabaseClient live,
  RequestLogHost host,
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
