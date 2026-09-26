@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/data/supabase_notification_settings_repository.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/data/play_update_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';

/// Every table read the repositories make, over a connection that misbehaves
/// the way a phone's does:
///
/// - not there at all ([deadUrl]): each read is an `Err` with the offline
///   message in about a second (at most one retry), not about seven;
/// - one failed attempt, then fine: each read is still `Ok`, with the same
///   rows a clean connection returns;
/// - two failed attempts in a row: `Err` -- a read retries at most once.
///
/// The flaky connection is a real `http.Client` in front of the real local
/// stack: it fails a table read's first (or first two) attempts with the
/// same `ClientException` a dropped socket gives, and passes everything
/// else -- sign-in, RPCs, writes -- straight through.
///
/// Requires a running local Supabase; --concurrency=1. Accounts tove and ugo
/// are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// "About a second": one retry's 1 s backoff, with CI headroom. The default
/// three retries take 1 + 2 + 4 = 7 s.
const _quick = Duration(milliseconds: 2500);

/// A client in front of the real network that fails the first [failures]
/// attempts of every PostgREST table read (GET/HEAD under /rest/v1/) -- or,
/// with [only] set, just the reads of that one table path -- and counts every
/// attempt it sees.
class _Flaky extends http.BaseClient {
  _Flaky(this.failures);

  int failures;
  String? only;
  final _inner = http.Client();

  /// Table-read attempts, per path.
  final attempts = <String, int>{};

  int get total => attempts.values.fold(0, (a, b) => a + b);

  /// Attempts beyond the first retry: a third try of the same read.
  int beyondOneRetry = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final read =
        request.url.path.startsWith('/rest/v1/') &&
        (request.method == 'GET' || request.method == 'HEAD');
    if (read) {
      final path = request.url.path;
      attempts[path] = (attempts[path] ?? 0) + 1;
      // The SDK numbers a retry in this header; the first attempt has none.
      final attempt = int.parse(request.headers['X-Retry-Count'] ?? '0');
      if (attempt >= 2) beyondOneRetry++;
      if (attempt < failures && (only == null || only == path)) {
        return Future.error(http.ClientException('blip', request.url));
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

SupabaseClient _client(String url, [http.Client? http]) => SupabaseClient(
  url,
  _key,
  httpClient: http,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email, [http.Client? http]) async {
  final client = _client(_url, http);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

typedef _Read = Future<Result<Object?>> Function();

/// Every repository read, each a table read or starting with one.
Map<String, _Read> _reads(SupabaseClient c, String conversation) {
  final chat = SupabaseChatRepository(c);
  final profile = SupabaseProfileRepository(c);
  final settings = SupabaseNotificationSettingsRepository(c);
  final auth = SupabaseAuthRepository(
    c,
    GoogleSignIn.instance,
    googleWebClientId: 'c',
  );
  final update = PlayUpdateRepository(c);
  return {
    'chat.members': chat.members,
    'chat.conversations': chat.conversations,
    'chat.conversationMembers': () => chat.conversationMembers(conversation),
    'chat.sharedMedia': () => chat.sharedMedia(conversation),
    'chat.sharedLinks': () => chat.sharedLinks(conversation),
    'chat.messages': () => chat.messages(conversation),
    'profile.load': profile.load,
    'notificationSettings.load': settings.load,
    'notificationSettings.mutes': settings.mutes,
    'auth.currentMember': auth.currentMember,
    'update.minSupportedBuild': update.minSupportedBuild,
  };
}

/// What a read returned, comparable across clients: the list length for a
/// list, the value's text otherwise.
Object? _shape(Result<Object?> r) => switch (r) {
  Ok(value: final List<Object?> v) => v.length,
  Ok(:final value) => '$value',
  Err(:final failure) => fail('expected Ok, got Err(${failure.message})'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final clients = <SupabaseClient>[];
  late SupabaseClient tove;
  late String conversation;
  late Map<String, Object?> clean;

  /// The table paths each read touches, on a clean connection.
  final paths = <String, Set<String>>{};
  final recorder = _Flaky(0);

  setUpAll(() async {
    tove = await _signedIn('tove@integration.test', recorder);
    final ugo = await _signedIn('ugo@integration.test');
    clients.addAll([tove, ugo]);
    final chat = SupabaseChatRepository(tove);
    final started = await chat.startDirectConversation(
      ugo.auth.currentUser!.id,
    );
    conversation = (started as Ok<String>).value;
    expect(
      await chat.send(
        conversationId: conversation,
        body:
            'see https://example.com ${DateTime.now().microsecondsSinceEpoch}',
      ),
      isA<Ok<Object?>>(),
    );
    clean = {};
    for (final MapEntry(:key, :value) in _reads(tove, conversation).entries) {
      final before = {...recorder.attempts};
      clean[key] = _shape(await value());
      paths[key] = {
        for (final MapEntry(key: p, value: n) in recorder.attempts.entries)
          if (n > (before[p] ?? 0)) p,
      };
      expect(paths[key], isNotEmpty, reason: '$key made no table read');
    }
    recorder.failures = 0;
    expect(clean['chat.messages'], greaterThan(0), reason: '$clean');
    expect(clean['chat.conversations'], greaterThan(0), reason: '$clean');
  });

  tearDownAll(() async {
    for (final c in clients) {
      await c.dispose();
    }
  });

  test('a dead server: every read is the offline Err in about a second, '
      'each retried at most once', () async {
    final counter = _Flaky(0);
    final dead = _client(deadUrl, counter);
    clients.add(dead);
    // tove's real, unexpired session: a repository that checks
    // auth.currentUser first must reach the network to fail.
    await dead.auth.recoverSession(
      jsonEncode(tove.auth.currentSession!.toJson()),
    );

    final slow = <String>[];
    for (final MapEntry(key: name, value: read) in _reads(
      dead,
      conversation,
    ).entries) {
      final before = counter.total;
      final beyond = counter.beyondOneRetry;
      final watch = Stopwatch()..start();
      final result = await read();
      watch.stop();
      final tries = counter.total - before;

      expect(result, isA<Err<Object?>>(), reason: '$name on a dead server');
      expect((result as Err).failure.message, offlineMessage, reason: name);
      expect(tries, greaterThan(0), reason: '$name never reached the network');
      if (watch.elapsed >= _quick || counter.beyondOneRetry > beyond) {
        slow.add('$name: ${watch.elapsedMilliseconds} ms, $tries attempts');
      }
    }
    expect(slow, isEmpty, reason: 'reads still on the ~7 s default retry');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('one failed attempt, then fine: every read is still Ok, with the same '
      'result a clean connection gets', () async {
    final flaky = _Flaky(1);
    final client = await _signedIn('tove@integration.test', flaky);
    clients.add(client);

    for (final MapEntry(key: name, value: read) in _reads(
      client,
      conversation,
    ).entries) {
      final before = flaky.total;
      final result = await read();
      expect(
        result,
        isA<Ok<Object?>>(),
        reason: '$name did not survive one blip: $result',
      );
      expect(_shape(result), clean[name], reason: name);
      expect(
        flaky.total - before,
        greaterThan(0),
        reason: '$name made no table read',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('two failed attempts in a row: every read is an Err (at most one '
      'retry)', () async {
    final flaky = _Flaky(2);
    final client = await _signedIn('tove@integration.test', flaky);
    clients.add(client);

    for (final MapEntry(key: name, value: read) in _reads(
      client,
      conversation,
    ).entries) {
      final beyond = flaky.beyondOneRetry;
      expect(
        await read(),
        isA<Err<Object?>>(),
        reason: '$name retried more than once',
      );
      expect(flaky.beyondOneRetry, beyond, reason: '$name tried a third time');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('each table a read touches, failing on its own for good: given up '
      'after one retry, in about a second', () async {
    // A read that makes several table reads in a row only reaches its
    // later ones when the earlier ones succeed: a whole dead server never
    // gets past the first. So each table fails alone.
    final flaky = recorder..failures = 1 << 30;
    addTearDown(
      () => flaky
        ..failures = 0
        ..only = null,
    );
    final slow = <String>[];
    for (final MapEntry(key: name, value: read) in _reads(
      tove,
      conversation,
    ).entries) {
      for (final path in paths[name]!) {
        flaky.only = path;
        final before = flaky.attempts[path] ?? 0;
        final beyond = flaky.beyondOneRetry;
        final watch = Stopwatch()..start();
        await read();
        watch.stop();
        final tries = (flaky.attempts[path] ?? 0) - before;
        if (watch.elapsed >= _quick || flaky.beyondOneRetry > beyond) {
          slow.add(
            '$name, $path: ${watch.elapsedMilliseconds} ms, '
            '$tries attempts',
          );
        }
      }
    }
    expect(slow, isEmpty, reason: 'table reads still on the ~7 s default');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
