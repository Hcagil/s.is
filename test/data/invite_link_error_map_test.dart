import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_invite_link_repository.dart';

/// Stub client that mimics PostgREST responses.
class _Stub extends http.BaseClient {
  _Stub(this.status, this.body, {this.throwError = false});
  final int status;
  final String body;
  final bool throwError;
  final paths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (throwError) throw const SocketException('no route');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

void main() {
  const code = 'Ab3-_Zx9Qw7Lm2Kp4Rt6Yv8N';
  const conv = 'c1';

  // Helper to create repository with a stub that returns the given status/body.
  SupabaseInviteLinkRepository repoWithStub(
    int status,
    String body, {
    bool throwError = false,
  }) {
    final stub = _Stub(status, body, throwError: throwError);
    final client = SupabaseClient(
      'http://stub.test',
      'anon-key-for-tests',
      httpClient: stub,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    return SupabaseInviteLinkRepository(client);
  }

  // Helper to extract failure from Err.
  Object failureOf<T>(Result<T> r) => (r as Err<T>).failure;

  // Helper to extract value from Ok.
  T valueOf<T>(Result<T> r) => (r as Ok<T>).value;

  // Helper to run a request and capture paths.
  Future<_Stub> run(
    int status,
    String body,
    Future<void> Function(SupabaseInviteLinkRepository) call,
  ) async {
    final stub = _Stub(status, body);
    final client = SupabaseClient(
      'http://stub.test',
      'anon-key-for-tests',
      httpClient: stub,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final repo = SupabaseInviteLinkRepository(client);
    await call(repo);
    return stub;
  }

  group('Invite link error mapping', () {
    final cases = <String, Matcher>{
      '42501': isA<DeniedFailure>(),
      'RLMT1': isA<SearchLimitFailure>(),
      'LINK1': isA<InviteLinkFailure>().having(
        (f) => f.problem,
        'problem',
        InviteLinkProblem.invalid,
      ),
      'LINK2': isA<InviteLinkFailure>().having(
        (f) => f.problem,
        'problem',
        InviteLinkProblem.expired,
      ),
      'LINK3': isA<InviteLinkFailure>().having(
        (f) => f.problem,
        'problem',
        InviteLinkProblem.closed,
      ),
      'LINK4': isA<InviteLinkFailure>().having(
        (f) => f.problem,
        'problem',
        InviteLinkProblem.removed,
      ),
    };

    for (final entry in cases.entries) {
      final errCode = entry.key;
      final matcher = entry.value;
      final status = errCode == '42501' ? 403 : 400;
      final body = jsonEncode({
        'code': errCode,
        'message': 'x',
        'details': null,
        'hint': null,
      });

      test('previewInvite maps $errCode', () async {
        final repo = repoWithStub(status, body);
        final result = await repo.previewInvite(code);
        expect(failureOf(result), matcher);
      });

      test('joinByInvite maps $errCode', () async {
        final repo = repoWithStub(status, body);
        final result = await repo.joinByInvite(code);
        expect(failureOf(result), matcher);
      });
    }

    test('inviteLink with 42501 returns DeniedFailure', () async {
      final body = jsonEncode({
        'code': '42501',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(403, body);
      final result = await repo.inviteLink(conv);
      expect(failureOf(result), isA<DeniedFailure>());
    });

    test('inviteLink with RLMT1 returns SearchLimitFailure', () async {
      final body = jsonEncode({
        'code': 'RLMT1',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(400, body);
      final result = await repo.inviteLink(conv);
      expect(failureOf(result), isA<SearchLimitFailure>());
    });

    test('resetInviteLink with 42501 returns DeniedFailure', () async {
      final body = jsonEncode({
        'code': '42501',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(403, body);
      final result = await repo.resetInviteLink(conv, validDays: 7);
      expect(failureOf(result), isA<DeniedFailure>());
    });

    test('resetInviteLink with RLMT1 returns SearchLimitFailure', () async {
      final body = jsonEncode({
        'code': 'RLMT1',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(400, body);
      final result = await repo.resetInviteLink(conv, validDays: 7);
      expect(failureOf(result), isA<SearchLimitFailure>());
    });

    test('turnOffInviteLink with 42501 returns DeniedFailure', () async {
      final body = jsonEncode({
        'code': '42501',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(403, body);
      final result = await repo.turnOffInviteLink(conv);
      expect(failureOf(result), isA<DeniedFailure>());
    });

    test('turnOffInviteLink with RLMT1 returns SearchLimitFailure', () async {
      final body = jsonEncode({
        'code': 'RLMT1',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(400, body);
      final result = await repo.turnOffInviteLink(conv);
      expect(failureOf(result), isA<SearchLimitFailure>());
    });

    test('previewInvite with 23505 returns Err', () async {
      final body = jsonEncode({
        'code': '23505',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(400, body);
      final result = await repo.previewInvite(code);
      expect(result, isA<Err>());
    });

    test('joinByInvite with 23505 returns Err', () async {
      final body = jsonEncode({
        'code': '23505',
        'message': 'x',
        'details': null,
        'hint': null,
      });
      final repo = repoWithStub(400, body);
      final result = await repo.joinByInvite(code);
      expect(result, isA<Err>());
    });

    test('previewInvite throws SocketException returns Err', () async {
      final repo = repoWithStub(200, '', throwError: true);
      final result = await repo.previewInvite(code);
      expect(result, isA<Err>());
    });

    test('joinByInvite throws SocketException returns Err', () async {
      final repo = repoWithStub(200, '', throwError: true);
      final result = await repo.joinByInvite(code);
      expect(result, isA<Err>());
    });

    test('inviteLink success parses token and expiresAt', () async {
      final body = jsonEncode([
        {
          'token': code,
          'created_at': '2026-11-17T10:00:00+00:00',
          'expires_at': '2026-11-24T10:00:00+00:00',
        },
      ]);
      final repo = repoWithStub(200, body);
      final result = await repo.inviteLink(conv);
      final link = valueOf(result);
      expect(link, isNotNull);
      expect(link!.token, equals(code));
      expect(link.expiresAt!.toUtc(), equals(DateTime.utc(2026, 11, 24, 10)));
    });

    test('inviteLink with empty array returns Ok(null)', () async {
      final body = jsonEncode([]);
      final repo = repoWithStub(200, body);
      final result = await repo.inviteLink(conv);
      final link = valueOf(result);
      expect(link, isNull);
    });

    test('inviteLink with null expires_at returns expiresAt null', () async {
      final body = jsonEncode([
        {
          'token': code,
          'created_at': '2026-11-17T10:00:00+00:00',
          'expires_at': null,
        },
      ]);
      final repo = repoWithStub(200, body);
      final result = await repo.inviteLink(conv);
      final link = valueOf(result);
      expect(link, isNotNull);
      expect(link!.expiresAt, isNull);
    });

    test('resetInviteLink success parses token', () async {
      final body = jsonEncode([
        {
          'token': code,
          'created_at': '2026-11-17T10:00:00+00:00',
          'expires_at': '2026-11-24T10:00:00+00:00',
        },
      ]);
      final repo = repoWithStub(200, body);
      final result = await repo.resetInviteLink(conv, validDays: 7);
      final link = valueOf(result);
      expect(link, isNotNull);
      expect(link.token, equals(code));
    });

    test('previewInvite success parses preview', () async {
      final body = jsonEncode([
        {
          'conversation_id': 'c1',
          'title': 'Team',
          'avatar_path': null,
          'member_count': 3,
        },
      ]);
      final repo = repoWithStub(200, body);
      final result = await repo.previewInvite(code);
      final preview = valueOf(result);
      expect(preview, isNotNull);
      expect(preview.conversationId, equals('c1'));
      expect(preview.title, equals('Team'));
      expect(preview.memberCount, equals(3));
      expect(preview.avatarPath, isNull);
    });

    test('joinByInvite success returns conversation id', () async {
      final body = jsonEncode('c1');
      final repo = repoWithStub(200, body);
      final result = await repo.joinByInvite(code);
      final convId = valueOf(result);
      expect(convId, equals('c1'));
    });

    test('turnOffInviteLink success returns Ok<void>', () async {
      final repo = repoWithStub(204, '');
      final result = await repo.turnOffInviteLink(conv);
      expect(result, isA<Ok<void>>());
    });

    test('paths recorded correctly for previewInvite', () async {
      final body = jsonEncode([
        {
          'conversation_id': 'c1',
          'title': 'Team',
          'avatar_path': null,
          'member_count': 3,
        },
      ]);
      final stub = await run(200, body, (repo) => repo.previewInvite(code));
      expect(stub.paths.last, endsWith('/rpc/preview_invite_link'));
    });

    test('paths recorded correctly for joinByInvite', () async {
      final body = jsonEncode('c1');
      final stub = await run(200, body, (repo) => repo.joinByInvite(code));
      expect(stub.paths.last, endsWith('/rpc/join_by_link'));
    });

    test('paths recorded correctly for inviteLink', () async {
      final body = jsonEncode([]);
      final stub = await run(200, body, (repo) => repo.inviteLink(conv));
      expect(stub.paths.last, endsWith('/rpc/get_invite_link'));
    });

    test('paths recorded correctly for turnOffInviteLink', () async {
      final stub = await run(204, '', (repo) => repo.turnOffInviteLink(conv));
      expect(stub.paths.last, endsWith('/rpc/turn_off_invite_link'));
    });
  });
}
