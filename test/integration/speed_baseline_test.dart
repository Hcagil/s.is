@Tags(['integration'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/speed_probe.dart';

/// Timing harness, not a behaviour test: what the calls behind each tap cost
/// against the REAL local stack, at no added delay and at a phone-like 100 ms
/// per request. The Realtime websocket is not delayed (only PostgREST and
/// auth requests are), so the join figures are a floor.
///
/// It prints `SPEED | ...` lines and asserts only that calls succeed.
/// Run: flutter test --run-skipped --tags integration --concurrency=1 \
///        test/integration/speed_baseline_test.dart
/// Accounts pace/quill/rush are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

const _n = 7;
const _rows = 560; // past the repository's read limit of 500

Future<SupabaseClient> _signedIn(String email, [LatencyWire? wire]) async {
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: wire,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'call failed: $r');
  return (r as Ok<T>).value;
}

void main() {
  late SupabaseClient pace;
  late SupabaseClient quill;
  late SupabaseClient rush;
  late SupabaseChatRepository repo;
  final wire = LatencyWire();
  late String paceId;
  late String shortConv;
  late String longConv;
  late String photoConv;

  /// [n] runs of [action]; prints one line with the median and the requests
  /// and bytes of the last run.
  Future<void> bench(
    String what,
    Future<void> Function() action, {
    String suffix = '',
  }) async {
    final samples = Samples(what);
    late Timed last;
    for (var i = 0; i < _n; i++) {
      last = await timeIt(wire, action);
      samples.add(last.d);
    }
    report(
      '$what @ ${wire.delay.inMilliseconds} ms RTT',
      samples,
      extra: 'requests ${last.requests} | bytes ${last.bytes}$suffix',
    );
  }

  /// Opens [conv] the way MessagesController does: join first, then read.
  /// Returns the join time and the read time of one open.
  Future<(Duration, Duration)> openOnce(String conv) async {
    final clock = Stopwatch()..start();
    final stream = _ok(await repo.incoming(conv));
    final join = clock.elapsed;
    final sub = stream.listen((_) {});
    wire.bytes = 0;
    _ok(await repo.messages(conv));
    final read = clock.elapsed - join;
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return (join, read);
  }

  Future<void> benchOpen(String what, String conv) async {
    final joins = Samples('$what join');
    final reads = Samples('$what read');
    final totals = Samples('$what total');
    for (var i = 0; i < _n; i++) {
      final (join, read) = await openOnce(conv);
      joins.add(join);
      reads.add(read);
      totals.add(join + read);
    }
    final rtt = '@ ${wire.delay.inMilliseconds} ms RTT';
    report(
      '$what: incoming() join $rtt',
      joins,
      extra: 'first ${joins.micros.first ~/ 1000} ms',
    );
    report('$what: messages() read $rtt', reads, extra: 'bytes ${wire.bytes}');
    report('$what: join then read, serial $rtt', totals);
  }

  Future<void> fill(
    SupabaseClient writer,
    String conv, {
    bool previews = false,
  }) async {
    final nonce = DateTime.now().microsecondsSinceEpoch;
    // The database only takes base64 of a PNG: the 8-byte signature first.
    final preview = base64Encode([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
      ...List<int>.generate(1792, (i) => i % 251),
    ]);
    for (var batch = 0; batch < _rows ~/ 40; batch++) {
      await writer.from('messages').insert([
        for (var i = 0; i < 40; i++)
          {
            'conversation_id': conv,
            'sender_id': paceId,
            'body': 'bulk-$nonce-b$batch-i$i with some filler to look real',
            if (previews && i % 8 == 0)
              'attachment_path': 'speed/$nonce-$batch-$i.jpg',
            if (previews && i % 8 == 0) 'attachment_preview': preview,
          },
      ]);
    }
  }

  setUpAll(() async {
    quill = await _signedIn('quill@integration.test');
    rush = await _signedIn('rush@integration.test');
    pace = await _signedIn('pace@integration.test', wire);
    repo = SupabaseChatRepository(pace);
    paceId = pace.auth.currentUser!.id;
    final quillId = quill.auth.currentUser!.id;
    await findByTag(pace, [quill, rush]);

    shortConv = _ok(await repo.startDirectConversation(quillId));
    for (var i = 0; i < 5; i++) {
      _ok(
        await repo.send(
          id: randomMessageId(),
          conversationId: shortConv,
          body: 'short-$i',
        ),
      );
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    longConv = _ok(
      await repo.startGroupConversation(
        title: 'speed long $stamp',
        memberIds: [quillId],
      ),
    );
    await fill(pace, longConv);
    photoConv = _ok(
      await repo.startGroupConversation(
        title: 'speed photo $stamp',
        memberIds: [quillId],
      ),
    );
    // Photo rows reference storage objects that do not exist, so only the
    // server may write them (see test/support/service_key.dart).
    final service = SupabaseClient(_url, serviceKey());
    try {
      await fill(service, photoConv, previews: true);
    } finally {
      await service.dispose();
    }
  });

  tearDownAll(() async {
    await pace.dispose();
    await quill.dispose();
    await rush.dispose();
  });

  for (final ms in [0, 100]) {
    group('RTT $ms ms', () {
      setUp(() => wire.delay = Duration(milliseconds: ms));

      test('gate: activate_session', () async {
        await bench('gate: activate_session rpc', () async {
          await pace.rpc('activate_session');
        });
      });

      test('gate: currentMember row', () async {
        await bench('gate: currentMember (profiles row)', () async {
          await pace
              .from('profiles')
              .select('user_id, display_name, tag')
              .eq('user_id', paceId)
              .single();
        });
      });

      test('gate: own_profile rpc', () async {
        await bench('gate: own_profile rpc (get)', () async {
          await pace.rpc('own_profile', params: const {}, get: true);
        });
      });

      test('chat list', () async {
        await bench('chat list: conversations(), 3 chats', () async {
          _ok(await repo.conversations());
        });
      });

      test(
        'open short chat',
        () => benchOpen('open chat, 5 messages', shortConv),
      );
      test('open long chat', () => benchOpen('open chat, 560 texts', longConv));
      test(
        'open photo chat',
        () => benchOpen('open chat, 560 with 70 previews', photoConv),
      );

      test('send text', () async {
        await bench('send text until the row returns', () async {
          _ok(
            await repo.send(
              id: randomMessageId(),
              conversationId: shortConv,
              body: 'at ${DateTime.now().microsecondsSinceEpoch}',
            ),
          );
        });
      });
    });
  }
}
