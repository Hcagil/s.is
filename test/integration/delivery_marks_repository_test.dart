@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

/// Delivery marks (Update 1 slice 5) on the real local stack:
/// [SupabaseChatRepository.markDelivered] through the `mark_delivered` RPC,
/// `readMarks().deliveredAt` from `read_marks`, and the `delivered:<conv>`
/// broadcast reaching `deliveredUpdates` -- plus the refusals: 42501 for a
/// non-member, an unreachable server.
///
/// Server contract (20261005150000): the position snaps to the newest
/// message created at or before least(upTo, now()); it only moves forward and
/// broadcasts only when it moves; it does not depend on read-status sharing;
/// mark_read moves it too.
///
/// Accounts priya, quinlan and remy are shared with
/// read_status_repository_test; each run uses a new group, so positions
/// from other runs never meet these. Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

Future<SupabaseClient> _signedIn(String email) async {
  await setLocalTestPassword(_url, email, localTestPassword);
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

List<ReadMark> _ok(Result<List<ReadMark>> r) {
  expect(r, isA<Ok<List<ReadMark>>>(), reason: 'readMarks failed: $r');
  return (r as Ok<List<ReadMark>>).value;
}

ReadMark _of(List<ReadMark> marks, String userId) =>
    marks.singleWhere((m) => m.userId == userId);

class _Heard {
  _Heard(Stream<ReadMark> stream) {
    _sub = stream.listen(marks.add, onError: errors.add);
  }
  final marks = <ReadMark>[];
  final errors = <Object>[];
  late final StreamSubscription<ReadMark> _sub;
  Future<void> cancel() => _sub.cancel();
}

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient;
  late SupabaseChatRepository priya, quinlan, remy;
  late String quinlanId, remyId;
  late String club; // priya, quinlan, remy: new each run
  late String direct; // priya <-> quinlan: remy is not in it
  final extra = <SupabaseClient>[];

  Future<void> share(SupabaseClient c, bool on) async {
    final r = await SupabaseProfileRepository(c).save(shareReadStatus: on);
    expect(r, isA<Ok<OwnProfile>>(), reason: 'could not set read status');
  }

  Future<Message> send(String conversation) async {
    final r = await priya.send(
      id: randomMessageId(),
      conversationId: conversation,
      body: _stamp('d'),
    );
    expect(r, isA<Ok<Message>>(), reason: 'send failed: $r');
    return (r as Ok<Message>).value;
  }

  setUpAll(() async {
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priya = SupabaseChatRepository(priyaClient);
    quinlan = SupabaseChatRepository(quinlanClient);
    remy = SupabaseChatRepository(remyClient);
    quinlanId = quinlanClient.auth.currentUser!.id;
    remyId = remyClient.auth.currentUser!.id;
    await findByTag(priyaClient, [quinlanClient, remyClient]);
    club = (await priya.startGroupConversation(
      title: _stamp('ticks'),
      memberIds: [quinlanId, remyId],
    ) as Ok<String>).value;
    direct =
        (await priya.startDirectConversation(quinlanId) as Ok<String>).value;
  });

  setUp(() async {
    await share(priyaClient, true);
    await share(quinlanClient, true);
    await share(remyClient, false);
  });

  tearDown(() async {
    for (final c in [priyaClient, quinlanClient, remyClient, ...extra]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    await share(remyClient, true);
    for (final c in [priyaClient, quinlanClient, remyClient, ...extra]) {
      await c.dispose();
    }
  });

  group('markDelivered -> readMarks().deliveredAt', () {
    test('before: one tick; after quinlan and remy (receipts off) report it: '
        "the message's own time, two grey; reading never turns it blue while "
        'remy has receipts off', () async {
      final m = await send(club);
      final before = _ok(await priya.readMarks(club));
      expect(_of(before, quinlanId).hasDelivered(m.createdAt), isFalse);
      expect(deliveryOf(m, before), Delivery.sent);

      expect(await quinlan.markDelivered(club), isA<Ok<void>>());
      final half = _ok(await priya.readMarks(club));
      final q = _of(half, quinlanId);
      expect(
        q.deliveredAt?.isAtSameMomentAs(m.createdAt),
        isTrue,
        reason: 'snapped to the message: ${q.deliveredAt} vs ${m.createdAt}',
      );
      expect(deliveryOf(m, half), Delivery.sent, reason: 'remy has not');

      expect(await remy.markDelivered(club), isA<Ok<void>>());
      final all = _ok(await priya.readMarks(club));
      final r = _of(all, remyId);
      expect(r.shares, isFalse, reason: 'fixture: remy shares nothing');
      expect(r.readAt, isNull);
      expect(
        r.hasDelivered(m.createdAt),
        isTrue,
        reason: 'delivery does not depend on sharing',
      );
      expect(deliveryOf(m, all), Delivery.delivered);

      expect(await quinlan.markRead(club), isA<Ok<void>>());
      expect(await remy.markRead(club), isA<Ok<void>>());
      expect(
        deliveryOf(m, _ok(await priya.readMarks(club))),
        Delivery.delivered,
        reason: 'remy has receipts off: never blue',
      );
    });

    test(
      'upTo before the message: not delivered; upTo at it: delivered',
      () async {
        final m = await send(direct);
        expect(
          await quinlan.markDelivered(
            direct,
            upTo: m.createdAt.subtract(const Duration(seconds: 1)),
          ),
          isA<Ok<void>>(),
        );
        expect(
          _of(
            _ok(await priya.readMarks(direct)),
            quinlanId,
          ).hasDelivered(m.createdAt),
          isFalse,
          reason: 'upTo was not passed, or the server ignored it',
        );
        expect(
          await quinlan.markDelivered(direct, upTo: m.createdAt.toLocal()),
          isA<Ok<void>>(),
        );
        final q = _of(_ok(await priya.readMarks(direct)), quinlanId);
        expect(q.hasDelivered(m.createdAt), isTrue, reason: '${q.deliveredAt}');
      },
    );

    test(
      'reading implies delivery: markRead alone moves deliveredAt',
      () async {
        final m = await send(direct);
        expect(await quinlan.markRead(direct), isA<Ok<void>>());
        final q = _of(_ok(await priya.readMarks(direct)), quinlanId);
        expect(q.hasDelivered(m.createdAt), isTrue);
        expect(
          deliveryOf(m, _ok(await priya.readMarks(direct))),
          Delivery.read,
        );
      },
    );

    test('a non-member is refused with 42501, as an Err', () async {
      final raw = remyClient.rpc(
        'mark_delivered',
        params: {'conversation': direct},
      );
      await expectLater(
        raw,
        throwsA(
          isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
        ),
      );
      final r = await remy.markDelivered(direct);
      expect(r, isA<Err<void>>(), reason: 'a refusal reported as Ok');
      final f = (r as Err<void>).failure;
      expect(
        f is DeniedFailure || (f is NetworkFailure && !f.retryable),
        isTrue,
        reason: 'a refusal is not a retryable network failure: $f',
      );
    });

    test('an unreachable server is an Err, not an exception', () async {
      final dead = deadHostClient();
      extra.add(dead);
      final repo = SupabaseChatRepository(dead);
      expect(await repo.markDelivered(club), isA<Err<void>>());
      expect(
        await repo.deliveredUpdates(club).timeout(const Duration(seconds: 40)),
        isA<Err<Stream<ReadMark>>>(),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('deliveredUpdates (delivered:<conv>)', () {
    /// Until [heard] has a delivery from [userId] at or after the message
    /// sent in that round: each round sends a new message so the position
    /// really moves (a repeat broadcasts nothing).
    Future<(ReadMark, Message)> arrives(
      _Heard heard,
      String conversation,
      SupabaseChatRepository who,
      String userId,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        final m = await send(conversation);
        expect(await who.markDelivered(conversation), isA<Ok<void>>());
        for (var i = 0; i < 12; i++) {
          final hit = heard.marks.where(
            (x) => x.userId == userId && x.hasDelivered(m.createdAt),
          );
          if (hit.isNotEmpty) return (hit.last, m);
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      fail('no delivery from $userId arrived (errors: ${heard.errors})');
    }

    test("quinlan's delivery arrives as quinlan, at the message's time, "
        'shares false', () async {
      final sub = await priya.deliveredUpdates(club);
      expect(sub, isA<Ok<Stream<ReadMark>>>(), reason: '$sub');
      final heard = _Heard((sub as Ok<Stream<ReadMark>>).value);
      addTearDown(heard.cancel);

      final (mark, m) = await arrives(heard, club, quinlan, quinlanId);
      expect(mark.shares, isFalse);
      expect(mark.readAt, isNull);
      expect(mark.deliveredAt!.isAtSameMomentAs(m.createdAt), isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('not gated on sharing: remy (receipts off) is heard, and priya hears '
        'it with her own receipts off', () async {
      await share(priyaClient, false);
      final sub = await priya.deliveredUpdates(club);
      expect(sub, isA<Ok<Stream<ReadMark>>>(), reason: '$sub');
      final heard = _Heard((sub as Ok<Stream<ReadMark>>).value);
      addTearDown(heard.cancel);
      await arrives(heard, club, remy, remyId);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a conversation I am not in: refused, or nothing arrives', () async {
      final sub = await remy.deliveredUpdates(direct);
      if (sub case Ok(:final value)) {
        final heard = _Heard(value);
        addTearDown(heard.cancel);
        for (var i = 0; i < 4; i++) {
          await send(direct);
          await quinlan.markDelivered(direct);
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(heard.marks, isEmpty, reason: 'a non-member heard deliveries');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
