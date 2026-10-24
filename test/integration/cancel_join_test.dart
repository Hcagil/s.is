@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';

/// SupabaseChatRepository.cancelJoin against the real stack (t_50655c1325
/// fix round 2b): with a join out, cancelJoin ends it, the channel is left,
/// incoming() returns an Err (no throw), and the server's late confirm
/// leaves no subscribed channel; twice or for an unknown id it is a no-op; a
/// new incoming() after a cancel is independent and delivers.
///
/// To hold a join "out" on demand, rho talks to the real stack through a
/// small TCP relay whose server-to-app direction can be paused: the join
/// request reaches Realtime, its reply waits until the test lets it through.
///
/// Requires a running local Supabase and the warmup probe. Accounts rho/sig
/// are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
// The suite's shared seed password (supabase/seed.sql).
const _pw = 'integration-password';

/// A relay to the stack whose replies can be held back and let through.
class _Relay {
  _Relay._(this._server);
  final ServerSocket _server;
  final _sockets = <Socket>[];
  final _held = <void Function()>[];
  bool _open = true;

  static Future<_Relay> start() async {
    final target = Uri.parse(_url);
    final relay = _Relay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    relay._server.listen((app) async {
      final stack = await Socket.connect(target.host, target.port);
      relay._sockets
        ..add(app)
        ..add(stack);
      stack.listen(
        (bytes) {
          if (relay._open) {
            app.add(bytes);
          } else {
            relay._held.add(() => app.add(bytes));
          }
        },
        onDone: app.destroy,
        onError: (_) => app.destroy(),
      );
      app.listen(
        stack.add,
        onDone: stack.destroy,
        onError: (_) {
          stack.destroy();
        },
      );
    });
    return relay;
  }

  String get url => 'http://127.0.0.1:${_server.port}';
  void hold() => _open = false;
  void release() {
    for (final send in _held) {
      send();
    }
    _held.clear();
    _open = true;
  }

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

Future<SupabaseClient> _signedIn(String email, [String url = _url]) async {
  final client = SupabaseClient(
    url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _pw);
  } on AuthException {
    await client.auth.signUp(email: email, password: _pw);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

Future<void> _until(bool Function() ok, String reason) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

void main() {
  // flutter_test answers every HTTP request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late _Relay relay;
  late SupabaseClient rhoClient;
  late SupabaseClient sigClient;
  late SupabaseChatRepository rho;
  late SupabaseChatRepository sig;
  late String chat;

  setUpAll(() async {
    relay = await _Relay.start();
    sigClient = await _signedIn('sig@integration.test');
    rhoClient = await _signedIn('rho@integration.test', relay.url);
    await findByTag(rhoClient, [sigClient]);
    rho = SupabaseChatRepository(rhoClient);
    sig = SupabaseChatRepository(sigClient);
    chat = (await rho.startDirectConversation(
      sigClient.auth.currentUser!.id,
    ) as Ok<String>).value;
  });

  tearDownAll(() async {
    relay.release();
    await rhoClient.dispose().timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    await sigClient.dispose();
    await relay.close();
  });

  List<RealtimeChannel> joinedChannels() => [
    for (final ch in rhoClient.getChannels())
      if (ch.canPush) ch,
  ];

  test('a join out is ended by cancelJoin: Err at once, channel left, the '
      'late confirm leaves nothing subscribed; cancel again is a no-op; a '
      'new incoming afterwards is independent and delivers', () async {
    // The socket is up first, so only the join reply is held below.
    final warm = await rho.incoming(chat);
    expect(warm, isA<Ok<Stream<Message>>>(), reason: 'fixture: joins');
    rho.cancelJoin(chat); // already joined: no effect
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(joinedChannels(), isNotEmpty, reason: 'answered join untouched');
    for (final ch in rhoClient.getChannels()) {
      await rhoClient.removeChannel(ch);
    }

    relay.hold();
    final channelsBefore = rhoClient.getChannels().length;
    final out = rho.incoming(chat);
    await _until(
      () => rhoClient.getChannels().length > channelsBefore,
      'the channel was never created',
    );
    // Give the join request time to reach Realtime; its reply is held.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final sw = Stopwatch()..start();
    rho.cancelJoin(chat);
    rho.cancelJoin(chat); // twice: no-op
    rho.cancelJoin('00000000-0000-0000-0000-000000000000'); // unknown: no-op
    final result = await out.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail('incoming() did not end after cancelJoin'),
    );
    expect(result, isA<Err<Stream<Message>>>());
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));

    relay.release(); // the server's confirm now arrives, late
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(joinedChannels(), isEmpty, reason: 'no subscribed channel left');
    await _until(
      () => rhoClient.getChannels().isEmpty,
      'the cancelled channel was never left',
    );

    final again = await rho.incoming(chat);
    expect(
      again,
      isA<Ok<Stream<Message>>>(),
      reason: 'independent of the cancel',
    );
    final got = <String>[];
    final sub = (again as Ok<Stream<Message>>).value.listen(
      (m) => got.add(m.body),
    );
    addTearDown(sub.cancel);
    final body = _stamp('after-cancel');
    expect(
      await sig.send(id: randomMessageId(), conversationId: chat, body: body),
      isA<Ok<Message>>(),
    );
    await _until(() => got.contains(body), 'the new join delivers');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
