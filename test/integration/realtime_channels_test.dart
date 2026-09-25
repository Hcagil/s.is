@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/realtime_channels.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';

/// `joinChannel` / `leaveChannel` against the real Realtime server.
///
/// These helpers exist because a failed private join used to hang the failure
/// path: the refusal was never turned into an error, and the teardown in the
/// catch block awaited a controller nobody had listened to. So every case here
/// is judged by *when* it resolves, not only by how: an error that arrives
/// only at the timeout is a refusal the helper did not hear.
///
/// Requires a running local Supabase and the warmup probe. cleo is this
/// suite's own allowlisted account (supabase/seed.sql); the stranger signs
/// up on the fly and is deliberately not allowlisted.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// Well inside joinChannel's default 15 s, and inside the SDK's own 10 s join
/// timeout, so a helper that ignores `channelError` and waits for either
/// cannot pass.
const _refusalBudget = Duration(seconds: 8);

final _clients = <SupabaseClient>[];

SupabaseClient _client([String url = _url]) {
  final c = SupabaseClient(
    url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  _clients.add(c);
  return c;
}

Future<SupabaseClient> _signIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  return client;
}

Future<SupabaseClient> _member() async {
  final c = await _signIn('cleo@integration.test');
  expect(
    await c.rpc('activate_session'),
    isTrue,
    reason: 'cleo must be allowlisted (supabase/seed.sql)',
  );
  return c;
}

Future<SupabaseClient> _stranger() async {
  final c = await _signIn('stranger-channels@integration.test');
  expect(
    await c.rpc('activate_session'),
    isFalse,
    reason: 'the stranger fixture must not be allowlisted',
  );
  return c;
}

/// The app's presence channel. Bound to presence as the app binds it: without
/// that binding Realtime authorises the join as broadcast, which the policy
/// refuses for everyone on this topic -- a refusal that proves nothing about
/// app access.
RealtimeChannel _presence(SupabaseClient c) => c.channel(
  'presence:members',
  opts: const RealtimeChannelConfig(private: true),
)..onPresenceSync((_) {});

/// Runs [join] and returns how long it took to fail; fails if it succeeded.
Future<Duration> _failsWithin(Future<void> join, Duration budget) async {
  final sw = Stopwatch()..start();
  Object? error;
  try {
    await join.timeout(
      budget,
      onTimeout: () => fail(
        'joinChannel neither completed nor failed within $budget: it hangs',
      ),
    );
  } on TestFailure {
    rethrow;
  } catch (e) {
    error = e;
  }
  sw.stop();
  expect(error, isNotNull, reason: 'the join completed; it must have failed');
  // ignore: avoid_print
  print('join failed after ${sw.elapsed}: $error');
  return sw.elapsed;
}

/// Waits for [c] to stop listing [ch]; the leave is asynchronous by design.
Future<void> _dropped(SupabaseClient c, RealtimeChannel ch) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (c.getChannels().contains(ch) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(
    c.getChannels(),
    isNot(contains(ch)),
    reason:
        'the channel was never removed from the client: the leave never '
        'happened, or waited on something that does not finish',
  );
}

/// Lets anything leaveChannel left running settle, so an asynchronous error
/// it throws lands inside this test rather than silently after it.
Future<void> _settle() => Future<void>.delayed(const Duration(seconds: 2));

void main() {
  // flutter_test answers every HTTP request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  tearDown(() async {
    for (final c in _clients) {
      // A client on a dead socket may never finish disconnecting; that is
      // not what is under test here.
      await c.dispose().timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    _clients.clear();
  });

  group('joinChannel', () {
    test('an allowlisted member joins the private presence channel', () async {
      final c = await _member();
      final ch = _presence(c);
      await joinChannel(ch);
      expect(
        // The SDK marks this internal, but it is the only public-facing
        // record of the server's join reply; nothing else distinguishes
        // "confirmed" from "sent and hoping".
        // ignore: invalid_use_of_internal_member
        ch.isJoined,
        isTrue,
        reason: 'joinChannel completed before the server confirmed the join',
      );
    });

    for (final (name, make) in [
      ('stranger (signed in, not allowlisted)', _stranger),
      ('anon', () async => _client()),
    ]) {
      test('$name: a refused private join is an error, not a hang', () async {
        final c = await make();
        final ch = _presence(c);
        await _failsWithin(joinChannel(ch), _refusalBudget);
      }, timeout: const Timeout(Duration(minutes: 1)));
    }

    test('a server that accepts but never answers fails by the given '
        'timeout', () async {
      // Refused connections fail fast on their own (below); only a server
      // that holds the socket open and says nothing leaves the timeout as
      // the one thing that can end the join.
      final held = <Socket>[];
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await silent.close();
      });

      final c = _client('http://127.0.0.1:${silent.port}');
      final ch = _presence(c);
      const timeout = Duration(seconds: 3);
      final took = await _failsWithin(
        joinChannel(ch, timeout: timeout),
        timeout + const Duration(seconds: 3),
      );
      expect(held, isNotEmpty, reason: 'control: the client never connected');
      expect(
        took,
        greaterThanOrEqualTo(timeout - const Duration(milliseconds: 100)),
        reason: 'failed before the timeout, so something else ended it',
      );
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('an unreachable server fails by the given timeout', () async {
      final c = _client(deadUrl);
      final ch = _presence(c);
      const timeout = Duration(seconds: 3);
      await _failsWithin(
        joinChannel(ch, timeout: timeout),
        timeout + const Duration(seconds: 3),
      );
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  group('leaveChannel', () {
    for (final (name, make, join) in [
      (
        'after a refused join',
        _stranger,
        (RealtimeChannel ch) => joinChannel(ch),
      ),
      (
        'on a dead socket',
        () async => _client(deadUrl),
        (RealtimeChannel ch) =>
            joinChannel(ch, timeout: const Duration(seconds: 2)),
      ),
    ]) {
      test(
        '$name: returns at once and closes a never-listened controller',
        () async {
          final c = await make();
          final ch = _presence(c);
          await _failsWithin(join(ch), _refusalBudget);

          // Never listened to: awaiting its close() would wait forever.
          final controller = StreamController<Object?>();
          expect(() => leaveChannel(c, ch, controller), returnsNormally);
          expect(
            controller.isClosed,
            isTrue,
            reason:
                'leaveChannel returned before closing the controller: it '
                'waited on something first',
          );
          await _dropped(c, ch);
          await _settle();
        },
        timeout: const Timeout(Duration(seconds: 45)),
      );
    }

    test('on a dead socket without a controller, never throws', () async {
      final c = _client(deadUrl);
      final ch = _presence(c);
      expect(() => leaveChannel(c, ch), returnsNormally);
      await _dropped(c, ch);
      await _settle();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('never throws, even when the controller refuses to close', () async {
      // close() throws StateError while an addStream is in flight: the one
      // teardown that fails synchronously.
      final c = _client(deadUrl);
      final ch = _presence(c);
      final controller = StreamController<Object?>();
      unawaited(controller.addStream(StreamController<Object?>().stream));
      expect(() => leaveChannel(c, ch, controller), returnsNormally);
      await _dropped(c, ch);
      await _settle();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('after a successful join, the client drops the channel', () async {
      final c = await _member();
      final ch = _presence(c);
      await joinChannel(ch);
      expect(c.getChannels(), contains(ch), reason: 'control');

      final controller = StreamController<Object?>();
      leaveChannel(c, ch, controller);
      expect(controller.isClosed, isTrue);

      await _dropped(c, ch);
      await _settle();
    }, timeout: const Timeout(Duration(seconds: 45)));
  });
}
