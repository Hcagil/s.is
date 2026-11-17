import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/data/supabase_account_deletion_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fakes.dart';

/// Helper that creates a [SupabaseClient] backed by a [MockClient].
SupabaseClient clientWith(int status, String body) {
  final mock = MockClient((request) async {
    return http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  });
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: mock,
  );
}

void main() {
  group('SupabaseAccountDeletionRepository', () {
    final auth = FakeAuth();

    test('requestDeletion returns Ok with parsed DateTime on 200', () async {
      final client = clientWith(
        200,
        jsonEncode('2026-12-20T10:00:00+00:00'),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.requestDeletion();

      final value = switch (result) {
        Ok(:final value) => value,
        _ => null,
      };
      expect(value, isNotNull);
      expect(
        value!.isAtSameMomentAs(DateTime.parse('2026-12-20T10:00:00+00:00')),
        isTrue,
      );
    });

    test('requestDeletion maps P0001 REAUTH to ReauthRequiredFailure', () async {
      final client = clientWith(
        400,
        jsonEncode({
          "code": "P0001",
          "message": "REAUTH",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.requestDeletion();

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isA<ReauthRequiredFailure>());
    });

    test('requestDeletion maps P0001 APPLE_REVOKE_REQUIRED to ProviderFailure', () async {
      final client = clientWith(
        400,
        jsonEncode({
          "code": "P0001",
          "message": "APPLE_REVOKE_REQUIRED",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.requestDeletion();

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isA<ProviderFailure>());
      expect(failure, isNot(isA<ReauthRequiredFailure>()));
    });

    test('requestDeletion maps 42501 not permitted to ProviderFailure', () async {
      final client = clientWith(
        403,
        jsonEncode({
          "code": "42501",
          "message": "not permitted",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.requestDeletion();

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isA<ProviderFailure>());
      expect(failure, isNot(isA<ReauthRequiredFailure>()));
    });

    test('requestDeletion: the Apple refusal and the not-permitted refusal have different messages', () async {
      Future<String?> messageFor(int status, String code, String msg) async {
        final repo = SupabaseAccountDeletionRepository(
          clientWith(status, jsonEncode({'code': code, 'message': msg, 'details': null, 'hint': null})),
          auth,
        );
        final r = await repo.requestDeletion();
        return switch (r) { Err(:final failure) => failure.message, _ => null };
      }

      final apple = await messageFor(400, 'P0001', 'APPLE_REVOKE_REQUIRED');
      final denied = await messageFor(403, '42501', 'not permitted');
      expect(apple, isNotNull);
      expect(denied, isNotNull);
      expect(apple, isNot(denied));
    });

    test('requestDeletion returns Err on server error', () async {
      final client = clientWith(
        500,
        jsonEncode({"error": "something went wrong"}),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.requestDeletion();

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isNotNull);
    });

    test('missingUsers with empty list returns Ok(empty set) and no request', () async {
      final seen = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode([]), 200, headers: {'content-type': 'application/json'}, request: request);
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.missingUsers([]);
      expect(seen, isEmpty);

      final value = switch (result) {
        Ok(:final value) => value,
        _ => null,
      };
      expect(value, isA<Set<String>>());
      expect(value!.isEmpty, isTrue);
    });

    test('missingUsers with 3 ids returns Ok with server answer', () async {
      final seen = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode(['b']),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.missingUsers(['a', 'b', 'c']);

      final value = switch (result) {
        Ok(:final value) => value,
        _ => null,
      };
      expect(value, isA<Set<String>>());
      expect(value, {'b'});
      expect(seen.length, 1);
      final body = jsonDecode(seen.first.body) as Map<String, dynamic>;
      expect(body['ids'], ['a', 'b', 'c']);
    });

    test('missingUsers with 200 ids makes one call', () async {
      final seen = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode([]),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final ids = List.generate(200, (i) => 'u$i');
      await repo.missingUsers(ids);

      expect(seen.length, 1);
      final body = jsonDecode(seen.first.body) as Map<String, dynamic>;
      expect(body['ids'], ids);
    });

    test('missingUsers with 201 ids splits into two calls', () async {
      final seen = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          seen.add(request);
          final ids = jsonDecode(request.body)['ids'] as List<dynamic>;
          if (ids.length == 200) {
            return http.Response(
              jsonEncode(['u5']),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          } else {
            return http.Response(
              jsonEncode(['u200']),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final ids = List.generate(201, (i) => 'u$i');
      final result = await repo.missingUsers(ids);

      final value = switch (result) {
        Ok(:final value) => value,
        _ => null,
      };
      expect(value, isA<Set<String>>());
      expect(value, {'u5', 'u200'});
      expect(seen.length, 2);
      expect((jsonDecode(seen[0].body)['ids'] as List).length, 200);
      expect(jsonDecode(seen[1].body)['ids'], ['u200']);
    });

    test('missingUsers second call fails returns Err', () async {
      final seen = <http.Request>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-anon-key',
        httpClient: MockClient((request) async {
          seen.add(request);
          final ids = jsonDecode(request.body)['ids'] as List<dynamic>;
          if (ids.length == 200) {
            return http.Response(
              jsonEncode(['u5']),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          } else {
            return http.Response(
              jsonEncode({'error': 'server error'}),
              500,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final ids = List.generate(201, (i) => 'u$i');
      final result = await repo.missingUsers(ids);

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isNotNull);
    });

    test('missingUsers server error returns Err', () async {
      final client = clientWith(
        403,
        jsonEncode({
          "code": "42501",
          "message": "not permitted",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseAccountDeletionRepository(client, auth);
      final result = await repo.missingUsers(['a']);

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isNotNull);
    });
  });
}
