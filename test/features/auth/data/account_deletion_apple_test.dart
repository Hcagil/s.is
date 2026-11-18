import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/data/supabase_account_deletion_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fakes.dart';
import '../../../support/google_sign_in_stand_ins.dart';

const channel = MethodChannel('com.aboutyou.dart_packages.sign_in_with_apple');
const uid = '0b6c4bb4-58e4-4bb5-9c1e-3f4bb8e2a7d1';

/// The native Apple sheet as the plugin's method channel answers it.
class FakeApple {
  PlatformException? error;
  Future<Object?> handle(MethodCall call) async {
    if (call.method != 'performAuthorizationRequest') {
      throw MissingPluginException(call.method);
    }
    if (error != null) throw error!;
    final req = (call.arguments as List).single as Map<Object?, Object?>;
    final token = [
      b64Json({'alg': 'RS256', 'kid': 'apple'}),
      b64Json({
        'iss': 'https://appleid.apple.com',
        'aud': 'com.esd.sis',
        'sub': 'apple-user-1',
        'email': 'ann@mail.test',
        'nonce': req['nonce'],
      }),
      'c2ln',
    ].join('.');
    return <String, Object?>{
      'type': 'appleid',
      'userIdentifier': 'apple-user-1',
      'authorizationCode': 'auth-code-1',
      'identityToken': token,
      'email': null,
    };
  }
}

/// Supabase as the repository sees it: routes by path, records what was called.
class World {
  int revokeStatus = 200;
  int rpcStatus = 200;
  Object rpcBody = '2026-12-20T10:00:00+00:00';
  final paths = <String>[];
  final bodies = <String, String>{};

  http.Response _json(int status, http.BaseRequest req, Object body) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: req,
      );

  late final http.Client client = MockClient((req) async {
    final p = req.url.path;
    paths.add(p);
    bodies[p] = req.body;
    if (p.endsWith('/auth/v1/token')) {
      final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      return _json(200, req, {
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
          'email': 'ann@mail.test',
          'app_metadata': {
            'provider': 'apple',
            'providers': ['apple'],
          },
          'user_metadata': <String, dynamic>{},
          'identities': [
            {
              'identity_id': 'i1',
              'id': 'apple-user-1',
              'user_id': uid,
              'identity_data': {'sub': 'apple-user-1'},
              'provider': 'apple',
              'created_at': '2026-09-29T10:00:00Z',
              'last_sign_in_at': '2026-09-29T10:00:00Z',
              'updated_at': '2026-09-29T10:00:00Z',
            },
          ],
          'created_at': '2026-09-29T10:00:00Z',
        },
      });
    }
    if (p.endsWith('/functions/v1/apple-revoke')) {
      return _json(
        revokeStatus,
        req,
        revokeStatus == 200 ? {'ok': true} : {'error': 'apple_failed'},
      );
    }
    if (p.endsWith('/rest/v1/rpc/request_account_deletion')) {
      return _json(rpcStatus, req, rpcBody);
    }
    return _json(404, req, {'error': 'unexpected $p'});
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late World world;
  late FakeApple apple;
  final clients = <SupabaseClient>[];

  /// A client already signed in as an Apple user; the call log starts empty.
  Future<SupabaseClient> appleClient() async {
    final c = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: world.client,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    clients.add(c);
    await c.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: [
        b64Json({'alg': 'RS256'}),
        b64Json({'sub': 'apple-user-1'}),
        'c2ln',
      ].join('.'),
    );
    expect(c.auth.currentUser?.identities?.first.provider, 'apple');
    world.paths.clear();
    world.bodies.clear();
    return c;
  }

  setUp(() {
    world = World();
    apple = FakeApple();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, apple.handle);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
  });

  /// Helper to extract Failure from Result
  Failure? failureOf(Result<DateTime> r) => switch (r) {
    Err(:final failure) => failure,
    _ => null,
  };

  test(
    'apple-revoke answers 500 -> ProviderFailure with the Apple message',
    () async {
      world.revokeStatus = 500;
      final repo = SupabaseAccountDeletionRepository(
        await appleClient(),
        FakeAuth(),
      );
      final r = await repo.requestDeletion();
      final f = failureOf(r);
      expect(f, isA<ProviderFailure>());
      expect(f!.message, failureStrings.failDeleteAccountApple);
      expect(world.paths, contains('/functions/v1/apple-revoke'));
    },
  );

  test(
    'happy path: revoke 200 then rpc 200 -> Ok, authorization code sent',
    () async {
      final repo = SupabaseAccountDeletionRepository(
        await appleClient(),
        FakeAuth(),
      );
      final r = await repo.requestDeletion();
      expect(r, isA<Ok<DateTime>>());
      final body = world.bodies['/functions/v1/apple-revoke'];
      final decoded = jsonDecode(body ?? '');
      expect(decoded['authorization_code'], 'auth-code-1');
      final revokeIndex = world.paths.indexOf('/functions/v1/apple-revoke');
      final rpcIndex = world.paths.indexOf(
        '/rest/v1/rpc/request_account_deletion',
      );
      expect(revokeIndex, lessThan(rpcIndex));
    },
  );

  test(
    'rpc P0001 APPLE_REVOKE_REQUIRED -> ProviderFailure with the Apple message',
    () async {
      world.rpcStatus = 400;
      world.rpcBody = {
        'code': 'P0001',
        'message': 'APPLE_REVOKE_REQUIRED',
        'details': null,
        'hint': null,
      };
      final repo = SupabaseAccountDeletionRepository(
        await appleClient(),
        FakeAuth(),
      );
      final r = await repo.requestDeletion();
      final f = failureOf(r);
      expect(f, isA<ProviderFailure>());
      expect(f!.message, failureStrings.failDeleteAccountApple);
    },
  );

  test('rpc P0001 REAUTH -> ReauthRequiredFailure', () async {
    world.rpcStatus = 400;
    world.rpcBody = {
      'code': 'P0001',
      'message': 'REAUTH',
      'details': null,
      'hint': null,
    };
    final repo = SupabaseAccountDeletionRepository(
      await appleClient(),
      FakeAuth(),
    );
    final r = await repo.requestDeletion();
    final f = failureOf(r);
    expect(f, isA<ReauthRequiredFailure>());
  });

  test(
    'rpc 42501 -> ProviderFailure with the generic delete message',
    () async {
      world.rpcStatus = 403;
      world.rpcBody = {
        'code': '42501',
        'message': 'not permitted',
        'details': null,
        'hint': null,
      };
      final repo = SupabaseAccountDeletionRepository(
        await appleClient(),
        FakeAuth(),
      );
      final r = await repo.requestDeletion();
      final f = failureOf(r);
      expect(f, isA<ProviderFailure>());
      expect(f!.message, failureStrings.failDeleteAccount);
      expect(f.message, isNot(equals(failureStrings.failDeleteAccountApple)));
    },
  );

  test(
    'Apple sheet cancelled -> ProviderFailure userCanceled, nothing sent',
    () async {
      final repo = SupabaseAccountDeletionRepository(
        await appleClient(),
        FakeAuth(),
      );
      // Set error after client creation
      apple.error = PlatformException(code: 'authorization-error/canceled');
      final r = await repo.requestDeletion();
      final f = failureOf(r);
      expect(f, isA<ProviderFailure>());
      expect((f as ProviderFailure).userCanceled, isTrue);
      expect(world.paths, isNot(contains('/functions/v1/apple-revoke')));
      expect(
        world.paths,
        isNot(contains('/rest/v1/rpc/request_account_deletion')),
      );
    },
  );
}
