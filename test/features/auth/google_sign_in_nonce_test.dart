// Google sign-in's nonce, written from the contract (2026-09-29).
//
// Both sides are stand-ins that behave like the real thing, because the real
// thing cannot run here: an ID token only Google can sign, verified by a
// Supabase Auth configured with a Google provider. So:
//
// - the Google side is a GoogleSignInPlatform that behaves like the native
//   SDKs: whatever nonce `initialize` hands it is embedded in the ID token;
//   the iOS SDK embeds a nonce of its own when handed none, Android embeds
//   none. `initialize` takes a tick to finish, as a platform call does.
// - the Supabase side is the real SupabaseClient over an HTTP stand-in for
//   GoTrue's id_token grant that applies GoTrue's own nonce rules: exactly one
//   of {request nonce, token nonce} -> "should either both exist or not";
//   both, and lowercase-hex sha256(request nonce) != token nonce -> "Nonces
//   mismatch".
//
// NOT covered, and cannot be locally: a real Google-signed token accepted by a
// real Supabase Auth. That round trip is verified on a device.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _webClient = 'web-client-123.apps.googleusercontent.com';

String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

Map<String, dynamic> _claims(String jwt) => jsonDecode(
  utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1]))),
) as Map<String, dynamic>;

String _sha256hex(String s) => sha256.convert(utf8.encode(s)).toString();

String _randomHex() {
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

  /// What `authenticate` does instead of succeeding.
  GoogleSignInException? error;
  bool nullIdToken = false;

  /// The nonce claim of the last token issued.
  String? lastTokenNonce;

  @override
  Future<void> init(InitParameters params) async {
    inits.add(params);
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
    final nonce = given ?? (ios ? _randomHex() : null);
    lastTokenNonce = nonce;
    final token = [
      _b64({'alg': 'RS256', 'typ': 'JWT'}),
      _b64({
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

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => const ClientAuthorizationTokenData(accessToken: 'ya29.access');

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

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

  bool offline = false;

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
      final passed = body['nonce'] as String? ?? '';
      final inToken =
          _claims(body['id_token'] as String)['nonce'] as String? ?? '';
      if (passed.isEmpty != inToken.isEmpty) {
        return _error(
          'Passed nonce and nonce in id_token should either both exist or not.',
        );
      }
      if (passed.isNotEmpty && _sha256hex(passed) != inToken) {
        return _error('Nonces mismatch');
      }
      final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      const uid = '0b6c4bb4-58e4-4bb5-9c1e-3f4bb8e2a7d1';
      return http.Response(
        jsonEncode({
          'access_token': [
            _b64({'alg': 'HS256', 'typ': 'JWT'}),
            _b64({'sub': uid, 'exp': exp, 'role': 'authenticated'}),
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
    return http.Response(
      '[]',
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  final clients = <SupabaseClient>[];

  SupabaseAuthRepository repo({required bool useNonce}) {
    final c = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: gotrue.client,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    clients.add(c);
    return SupabaseAuthRepository(
      c,
      GoogleSignIn.instance,
      googleWebClientId: _webClient,
      useNonce: useNonce,
    );
  }

  late FakeGooglePlatform google;
  void platform({required bool ios}) =>
      GoogleSignInPlatform.instance = google = FakeGooglePlatform(ios: ios);

  setUp(() => gotrue = GoTrueStandIn());
  tearDown(() async {
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
  });

  group('Android (useNonce false)', () {
    setUp(() => platform(ios: false));

    test(
      'no nonce anywhere: not to Google, not to Supabase; signs in',
      () async {
        final r = await repo(useNonce: false).signInWithGoogle();

        expect(r, isA<Ok<void>>(), reason: '$r');
        expect(google.inits, hasLength(1));
        expect(google.inits.single.nonce, isNull);
        expect(google.inits.single.serverClientId, _webClient);
        expect(gotrue.grants, hasLength(1));
        expect(gotrue.grants.single['nonce'], isNull);
        expect(gotrue.grants.single['provider'], 'google');
        expect(google.lastTokenNonce, isNull);
      },
    );
  });

  group('iOS (useNonce true)', () {
    setUp(() => platform(ios: true));

    test(
      'Google gets sha256hex(raw), Supabase gets raw; Supabase accepts',
      () async {
        final r = await repo(useNonce: true).signInWithGoogle();

        expect(r, isA<Ok<void>>(), reason: '$r');
        expect(google.inits, hasLength(1));
        final hashed = google.inits.single.nonce;
        expect(hashed, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(google.inits.single.serverClientId, _webClient);

        final raw = gotrue.grants.single['nonce'] as String?;
        expect(raw, isNotNull, reason: 'the raw nonce never reached Supabase');
        expect(
          raw,
          isNot(hashed),
          reason: 'Supabase got the hash, not the raw',
        );
        expect(_sha256hex(raw!), hashed);
      },
    );

    test(
      'the raw nonce is 32 random bytes, base64url, 43 characters',
      () async {
        expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());
        final raw = gotrue.grants.single['nonce'] as String;

        expect(base64Url.decode(base64Url.normalize(raw)), hasLength(32));
        expect(raw, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      },
    );

    test('two sign-ins on one repository: initialize once, same nonce, both '
        'accepted', () async {
      final auth = repo(useNonce: true);
      expect(await auth.signInWithGoogle(), isA<Ok<void>>());
      final second = await auth.signInWithGoogle();

      expect(second, isA<Ok<void>>(), reason: '$second');
      expect(google.inits, hasLength(1), reason: 'initialize() ran twice');
      expect(gotrue.grants, hasLength(2));
      expect(gotrue.grants[0]['nonce'], gotrue.grants[1]['nonce']);
    });

    test('two repositories: different nonces', () async {
      expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());
      expect(await repo(useNonce: true).signInWithGoogle(), isA<Ok<void>>());

      expect(google.inits, hasLength(2));
      expect(google.inits[0].nonce, isNot(google.inits[1].nonce));
      expect(gotrue.grants[0]['nonce'], isNot(gotrue.grants[1]['nonce']));
    });

    test(
      'without a nonce, the iOS token carries the SDK\'s own and Supabase '
      'refuses: the defect this fixes, reproduced by the stand-ins',
      () async {
        final r = await repo(useNonce: false).signInWithGoogle();

        expect(r, isA<Err<void>>());
        final f = (r as Err<void>).failure;
        expect(f, isA<ProviderFailure>());
        expect(f.message, startsWith('Supabase rejected'));
      },
    );
  });

  group('failure paths', () {
    for (final ios in [false, true]) {
      final name = ios ? 'iOS' : 'Android';
      group(name, () {
        setUp(() => platform(ios: ios));

        test('cancel -> ProviderFailure(userCanceled: true), Supabase not '
            'called', () async {
          google.error = const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
          );
          final r = await repo(useNonce: ios).signInWithGoogle();

          expect(r, isA<Err<void>>());
          final f = (r as Err<void>).failure;
          expect(f, isA<ProviderFailure>());
          expect((f as ProviderFailure).userCanceled, isTrue);
          expect(gotrue.grants, isEmpty);
        });

        test('no ID token -> Err, Supabase not called', () async {
          google.nullIdToken = true;
          final r = await repo(useNonce: ios).signInWithGoogle();

          expect(r, isA<Err<void>>());
          expect(gotrue.grants, isEmpty);
        });

        test(
          'Supabase unreachable -> the offline message, no raw text',
          () async {
            gotrue.offline = true;
            final r = await repo(useNonce: ios).signInWithGoogle();

            expect(r, isA<Err<void>>());
            final message = (r as Err<void>).failure.message;
            expect(message, offlineMessage);
          },
        );
      });
    }

    test('iOS: Supabase\'s "Nonces mismatch" -> ProviderFailure "Supabase '
        'rejected..."', () async {
      // A token whose nonce is not the hash of what the repository sends.
      platform(ios: true);
      final auth = repo(useNonce: true);
      // Swap the SDK after initialize so the token carries a foreign nonce.
      expect(await auth.signInWithGoogle(), isA<Ok<void>>());
      google.inits.add(
        InitParameters(
          serverClientId: _webClient,
          nonce: _sha256hex('someone-else'),
        ),
      );
      final r = await auth.signInWithGoogle();

      expect(r, isA<Err<void>>());
      final f = (r as Err<void>).failure;
      expect(f, isA<ProviderFailure>());
      expect(f.message, startsWith('Supabase rejected'));
    });
  });
}
