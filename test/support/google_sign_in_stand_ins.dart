// Stand-ins for both sides of Google sign-in, as far as the nonce goes.
// See google_sign_in_nonce_test.dart for why they exist and what they model.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const googleWebClient = 'web-client-123.apps.googleusercontent.com';

String b64Json(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

Map<String, dynamic> jwtClaims(String jwt) => jsonDecode(
  utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1]))),
) as Map<String, dynamic>;

String sha256hex(String s) => sha256.convert(utf8.encode(s)).toString();

String randomHex() {
  final r = Random.secure();
  return List.generate(
    32,
    (_) => r.nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The native Google SDK, as far as the nonce goes.
class FakeGooglePlatform extends GoogleSignInPlatform {
  FakeGooglePlatform({required this.ios});

  /// The iOS SDK puts a nonce in every ID token, its own if given none.
  final bool ios;

  final inits = <InitParameters>[];
  var _initDone = false;
  var authenticateCalls = 0;

  /// What `authenticate` throws instead of succeeding: a
  /// GoogleSignInException, as the SDK does, or anything else.
  Object? error;

  /// What `init` throws instead of finishing, as a failed platform call does.
  Object? initError;
  bool nullIdToken = false;

  /// The nonce claim of the last token issued.
  String? lastTokenNonce;

  @override
  Future<void> init(InitParameters params) async {
    inits.add(params);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (initError != null) throw initError!;
    _initDone = true;
  }

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    authenticateCalls++;
    if (!_initDone) {
      throw StateError('authenticate() before initialize() completed');
    }
    if (error != null) throw error!;
    final given = inits.last.nonce;
    final nonce = given ?? (ios ? randomHex() : null);
    lastTokenNonce = nonce;
    final token = [
      b64Json({'alg': 'RS256', 'typ': 'JWT'}),
      b64Json({
        'iss': 'https://accounts.google.com',
        'aud': inits.last.serverClientId,
        'sub': '1100220033',
        'email': 'ali@example.com',
        'nonce': ?nonce,
      }),
      'c2lnbmF0dXJl',
    ].join('.');
    return AuthenticationResults(
      user: const GoogleSignInUserData(
        email: 'ali@example.com',
        id: '1100220033',
      ),
      authenticationTokens: AuthenticationTokenData(
        idToken: nullIdToken ? null : token,
      ),
    );
  }

  @override
  Future<AuthenticationResults?>? attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async => null;

  @override
  bool supportsAuthenticate() => true;

  @override
  bool authorizationRequiresUserInteraction() => false;

  /// What the scope-authorization step (after a successful authenticate)
  /// throws instead of answering: the consent sheet dismissed, or a failure.
  Object? scopeError;
  var scopeCalls = 0;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    scopeCalls++;
    if (scopeError != null) throw scopeError!;
    return const ClientAuthorizationTokenData(accessToken: 'ya29.access');
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    scopeCalls++;
    if (scopeError != null) throw scopeError!;
    return null;
  }

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

/// GoTrue's id_token grant, with its nonce rules.
class GoTrueStandIn {
  /// Bodies of every id_token grant received.
  final grants = <Map<String, dynamic>>[];

  /// Any other request, so an unexpected call is visible.
  final others = <String>[];

  /// The body of each of [others], in the same order.
  final otherBodies = <String>[];

  bool offline = false;

  /// When set, every id_token grant is refused with this message, as GoTrue
  /// refuses a token whose audience is not an authorised client id.
  String? rejectWith;

  /// When set, every id_token grant is answered with this status and JSON body
  /// verbatim -- e.g. GoTrue's 403 {"code":403,"error_code":"unknown",
  /// "msg":"not invited"} when the before-user-created hook refuses the user.
  (int, Map<String, Object?>)? replyWith;

  http.Response _error(String msg) => http.Response(
    jsonEncode({'code': 400, 'error_code': 'validation_failed', 'msg': msg}),
    400,
    headers: {'content-type': 'application/json'},
  );

  late final http.Client client = MockClient((req) async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (offline) throw http.ClientException('Failed host lookup: x');
    if (req.url.path.endsWith('/auth/v1/token') &&
        req.url.queryParameters['grant_type'] == 'id_token') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      grants.add(body);
      if (rejectWith != null) return _error(rejectWith!);
      if (replyWith case (final status, final reply)) {
        return http.Response(
          jsonEncode(reply),
          status,
          headers: {'content-type': 'application/json'},
        );
      }
      final passed = body['nonce'] as String? ?? '';
      final inToken =
          jwtClaims(body['id_token'] as String)['nonce'] as String? ?? '';
      if (passed.isEmpty != inToken.isEmpty) {
        return _error(
          'Passed nonce and nonce in id_token should either both exist or not.',
        );
      }
      if (passed.isNotEmpty && sha256hex(passed) != inToken) {
        return _error('Nonces mismatch');
      }
      final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      const uid = '0b6c4bb4-58e4-4bb5-9c1e-3f4bb8e2a7d1';
      return http.Response(
        jsonEncode({
          'access_token': [
            b64Json({'alg': 'HS256', 'typ': 'JWT'}),
            b64Json({'sub': uid, 'exp': exp, 'role': 'authenticated'}),
            'c2ln',
          ].join('.'),
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': exp,
          'refresh_token': 'refresh-1',
          'user': {
            'id': uid,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': 'ali@example.com',
            'app_metadata': {'provider': 'google'},
            'user_metadata': <String, dynamic>{},
            'created_at': '2026-09-29T10:00:00Z',
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    others.add('${req.method} ${req.url}');
    otherBodies.add(req.body);
    return http.Response(
      '[]',
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}
