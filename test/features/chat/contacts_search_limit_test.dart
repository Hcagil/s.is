import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_contacts_repository.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  group('Search limit and denied failures', () {
    test(
      'SupabaseContactsRepository.findByTag returns SearchLimitFailure on 400',
      () async {
        final client = clientWith(
          400,
          jsonEncode({
            "code": "RLMT1",
            "message": "rate limit",
            "details": null,
            "hint": null,
          }),
        );
        final repo = SupabaseContactsRepository(client);
        final result = await repo.findByTag('someone');

        final failure = switch (result) {
          Err(:final failure) => failure,
          _ => null,
        };
        expect(failure, isA<SearchLimitFailure>());
        expect(failure, isNot(isA<ProviderFailure>()));
        expect(
          failure?.message,
          'Too many searches. Try again in a little while.',
        );
      },
    );

    test('SupabaseContactsRepository.findByContacts returns SearchLimitFailure on 400', () async {
      final client = clientWith(
        400,
        jsonEncode({
          "code": "RLMT1",
          "message": "rate limit",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseContactsRepository(client);
      final result = await repo.findByContacts(['a' * 64]);

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isA<SearchLimitFailure>());
      expect(failure, isNot(isA<ProviderFailure>()));
      expect(
        failure?.message,
        'Too many searches. Try again in a little while.',
      );
    });

    test('SupabaseProfileRepository.isTagAvailable returns SearchLimitFailure on 400', () async {
      final client = clientWith(
        400,
        jsonEncode({
          "code": "RLMT1",
          "message": "rate limit",
          "details": null,
          "hint": null,
        }),
      );
      final repo = SupabaseProfileRepository(client);
      final result = await repo.isTagAvailable('someone');

      final failure = switch (result) {
        Err(:final failure) => failure,
        _ => null,
      };
      expect(failure, isA<SearchLimitFailure>());
      expect(failure, isNot(isA<ProviderFailure>()));
      expect(
        failure?.message,
        'Too many searches. Try again in a little while.',
      );
    });

    test(
      'SupabaseContactsRepository.findByTag returns DeniedFailure on 403',
      () async {
        final client = clientWith(
          403,
          jsonEncode({
            "code": "42501",
            "message": "denied",
            "details": null,
            "hint": null,
          }),
        );
        final repo = SupabaseContactsRepository(client);
        final result = await repo.findByTag('someone');

        final failure = switch (result) {
          Err(:final failure) => failure,
          _ => null,
        };
        expect(failure, isA<DeniedFailure>());
      },
    );

    test(
      'SupabaseContactsRepository.findByContacts returns DeniedFailure on 403',
      () async {
        final client = clientWith(
          403,
          jsonEncode({
            "code": "42501",
            "message": "denied",
            "details": null,
            "hint": null,
          }),
        );
        final repo = SupabaseContactsRepository(client);
        final result = await repo.findByContacts(['a' * 64]);

        final failure = switch (result) {
          Err(:final failure) => failure,
          _ => null,
        };
        expect(failure, isA<DeniedFailure>());
      },
    );

    test(
      'SupabaseProfileRepository.isTagAvailable returns DeniedFailure on 403',
      () async {
        final client = clientWith(
          403,
          jsonEncode({
            "code": "42501",
            "message": "denied",
            "details": null,
            "hint": null,
          }),
        );
        final repo = SupabaseProfileRepository(client);
        final result = await repo.isTagAvailable('someone');

        final failure = switch (result) {
          Err(:final failure) => failure,
          _ => null,
        };
        expect(failure, isA<DeniedFailure>());
      },
    );
  });
}
