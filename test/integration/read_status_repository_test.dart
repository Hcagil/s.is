@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';

/// [SupabaseChatRepository.readMarks], `.readUpdates` and `.markRead` against
/// the real local stack: the real RPCs and the real Realtime broadcast that
/// `mark_read` sends.
///
/// Mutual, like last seen: priya and quinlan share read status; remy does
/// not, so what priya and quinlan see of remy -- and remy of them -- is
/// decided by sharing, not membership. A stranger (signed in, never
/// allowlisted) is refused by has_app_access alone.
///
/// Requires a running local Supabase and the warmup probe; --concurrency=1.
/// Accounts priya, quinlan and remy are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
SupabaseClient _client([String url = _url]) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

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

Future<SupabaseClient> _signedIn(String email) async {
  final client = await _signIn(email);
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

List<ReadMark> _ok(Result<List<ReadMark>> r) {
  expect(r, isA<Ok<List<ReadMark>>>(), reason: 'readMarks failed: $r');
  return (r as Ok<List<ReadMark>>).value;
}

ReadMark _of(List<ReadMark> marks, String userId) =>
    marks.singleWhere((m) => m.userId == userId);

/// Everything [stream] delivers, until [cancel].
class _Heard {
  _Heard(Stream<ReadMark> stream) {
    _sub = stream.listen(marks.add, onError: errors.add);
  }
  final marks = <ReadMark>[];
  final errors = <Object>[];
  late final StreamSubscription<ReadMark> _sub;
  Future<void> cancel() => _sub.cancel();
}

/// Repeats [send] until [heard] has a mark from [userId]: a broadcast sent
/// before Realtime relays the channel is gone, so one send proves nothing.
Future<ReadMark> _arrives(
  _Heard heard,
  String userId,
  Future<Result<void>> Function() send, {
  Duration within = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(within);
  var sends = 0;
  while (DateTime.now().isBefore(deadline)) {
    sends++;
    expect(await send(), isA<Ok<void>>(), reason: 'mark_read refused');
    for (var i = 0; i < 12; i++) {
      final hit = heard.marks.where((m) => m.userId == userId);
      if (hit.isNotEmpty) return hit.last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  fail(
    'no read from $userId arrived after $sends mark_read call(s) over '
    '$within (errors on the stream: ${heard.errors})',
  );
}

/// Holds for [window]: nothing from [userId] arrives.
Future<void> _silent(
  _Heard heard,
  String userId, {
  Duration window = const Duration(seconds: 5),
  required String reason,
}) async {
  await Future<void>.delayed(window);
  expect(heard.marks.where((m) => m.userId == userId), isEmpty, reason: reason);
}

/// Joins [topic] the way any client could and reports the server's answer.
Future<(RealtimeChannel, RealtimeSubscribeStatus)> _join(
  SupabaseClient client,
  String topic, {
  required bool private,
  void Function(Map<String, dynamic>)? heard,
}) async {
  final channel = client.channel(
    topic,
    opts: RealtimeChannelConfig(private: private),
  );
  if (heard != null) channel.onBroadcast(event: '*', callback: heard);
  final first = Completer<RealtimeSubscribeStatus>();
  channel.subscribe((status, _) {
    if (!first.isCompleted) first.complete(status);
  });
  final status = await first.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => RealtimeSubscribeStatus.timedOut,
  );
  return (channel, status);
}

void main() {
  late SupabaseClient priyaClient;
  late SupabaseClient quinlanClient;
  late SupabaseClient remyClient;
  late SupabaseChatRepository priya;
  late SupabaseChatRepository quinlan;
  late SupabaseChatRepository remy;
  late String priyaId;
  late String quinlanId;
  late String remyId;
  final extra = <SupabaseClient>[];

  /// priya, quinlan and remy; a new group each run.
  late String club;

  /// priya <-> quinlan.
  late String direct;

  Future<void> share(SupabaseClient c, bool on) async {
    final r = await SupabaseProfileRepository(c).save(shareReadStatus: on);
    expect(r, isA<Ok<OwnProfile>>(), reason: 'could not set read status');
    expect((r as Ok<OwnProfile>).value.shareReadStatus, on);
  }

  setUpAll(() async {
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priya = SupabaseChatRepository(priyaClient);
    quinlan = SupabaseChatRepository(quinlanClient);
    remy = SupabaseChatRepository(remyClient);
    priyaId = priyaClient.auth.currentUser!.id;
    quinlanId = quinlanClient.auth.currentUser!.id;
    remyId = remyClient.auth.currentUser!.id;
    club = (await priya.startGroupConversation(
      title: _stamp('reads'),
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

  test('a new member shares read status by default', () async {
    final fresh = await SupabaseProfileRepository(priyaClient).load();
    expect(fresh, isA<Ok<OwnProfile>>());
    // setUp turned it on; the default itself is pgTAP's. This proves the
    // repository reads the column back at all.
    expect((fresh as Ok<OwnProfile>).value.shareReadStatus, isTrue);
    await share(priyaClient, false);
    final off = await SupabaseProfileRepository(priyaClient).load();
    expect((off as Ok<OwnProfile>).value.shareReadStatus, isFalse);
  });

  group('readMarks', () {
    test('two members who both share see how far the other has read', () async {
      final sent = await priya.send(conversationId: club, body: _stamp('m'));
      final message = (sent as Ok<Message>).value;
      expect(await quinlan.markRead(club), isA<Ok<void>>());

      final marks = _ok(await priya.readMarks(club));
      expect(marks.map((m) => m.userId).toSet(), {
        quinlanId,
        remyId,
      }, reason: 'one row per OTHER member');
      final q = _of(marks, quinlanId);
      expect(q.shares, isTrue);
      expect(q.readAt, isNotNull);
      expect(
        q.hasRead(message.createdAt),
        isTrue,
        reason: 'quinlan read after the message was sent',
      );

      // and the other way round
      final back = _of(_ok(await quinlan.readMarks(club)), priyaId);
      expect(back.shares, isTrue);
    });

    test('a member who does not share is not shown, and sees nobody', () async {
      expect(await remy.markRead(club), isA<Ok<void>>());

      final r = _of(_ok(await priya.readMarks(club)), remyId);
      expect(r.shares, isFalse, reason: 'remy does not share');
      expect(r.readAt, isNull, reason: "remy's read time leaked");

      final hers = _ok(await remy.readMarks(club));
      expect(hers.map((m) => m.userId).toSet(), {priyaId, quinlanId});
      expect(
        hers.where((m) => m.shares || m.readAt != null),
        isEmpty,
        reason: 'remy, not sharing, must see nobody (mutual)',
      );
    });

    test('turning my own sharing off hides everyone from me, and back on '
        'shows them again', () async {
      expect(await quinlan.markRead(direct), isA<Ok<void>>());
      expect(_of(_ok(await priya.readMarks(direct)), quinlanId).shares, isTrue);

      await share(priyaClient, false);
      final off = _of(_ok(await priya.readMarks(direct)), quinlanId);
      expect((off.shares, off.readAt), (false, null));
      final theirs = _of(_ok(await quinlan.readMarks(direct)), priyaId);
      expect((theirs.shares, theirs.readAt), (false, null));

      await share(priyaClient, true);
      final on = _of(_ok(await priya.readMarks(direct)), quinlanId);
      expect(on.shares, isTrue);
      expect(on.readAt, isNotNull);
    });

    test('a read made while sharing is off stays hidden after sharing is '
        'back on', () async {
      // quinlan's last shared read, the one priya may keep seeing.
      expect(await quinlan.markRead(club), isA<Ok<void>>());
      final shared = _of(_ok(await priya.readMarks(club)), quinlanId).readAt;
      expect(shared, isNotNull, reason: 'control: the shared read is shown');

      await share(quinlanClient, false);
      final sent = await priya.send(conversationId: club, body: _stamp('off'));
      final message = (sent as Ok<Message>).value;
      expect(await quinlan.markRead(club), isA<Ok<void>>());
      await share(quinlanClient, true);

      final back = _of(_ok(await priya.readMarks(club)), quinlanId);
      expect(back.shares, isTrue);
      expect(back.readAt, shared, reason: 'the off-period read surfaced');
      expect(back.hasRead(message.createdAt), isFalse);

      // control: a read made now, while sharing, shows at once.
      expect(await quinlan.markRead(club), isA<Ok<void>>());
      final now = _of(_ok(await priya.readMarks(club)), quinlanId);
      expect(now.hasRead(message.createdAt), isTrue);
    });

    test('a conversation I am not in tells me nothing', () async {
      final r = await remy.readMarks(direct);
      if (r case Ok(:final value)) {
        expect(value, isEmpty, reason: 'a non-member saw read marks');
      }
    });

    test('an unreachable server is an Err, not an exception', () async {
      final dead = deadHostClient();
      extra.add(dead);
      final repo = SupabaseChatRepository(dead);
      expect(await repo.readMarks(club), isA<Err<List<ReadMark>>>());
      expect(await repo.markRead(club), isA<Err<void>>());
      expect(
        await repo.readUpdates(club).timeout(const Duration(seconds: 40)),
        isA<Err<Stream<ReadMark>>>(),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('readUpdates', () {
    test(
      "a sharing member's read arrives, as that member, with its time",
      () async {
        final sent = await priya.send(
          conversationId: direct,
          body: _stamp('r'),
        );
        final message = (sent as Ok<Message>).value;
        final sub = await priya.readUpdates(direct);
        expect(sub, isA<Ok<Stream<ReadMark>>>());
        final heard = _Heard((sub as Ok<Stream<ReadMark>>).value);
        addTearDown(heard.cancel);

        final mark = await _arrives(
          heard,
          quinlanId,
          () => quinlan.markRead(direct),
        );
        expect(mark.shares, isTrue);
        expect(mark.hasRead(message.createdAt), isTrue);
        final stored = _of(_ok(await priya.readMarks(direct)), quinlanId);
        expect(
          mark.readAt!.isAfter(stored.readAt!),
          isFalse,
          reason: 'the live time is later than the stored one',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test("a member who does not share: nothing arrives, though the channel "
        'is live', () async {
      final sub = await priya.readUpdates(club);
      final heard = _Heard((sub as Ok<Stream<ReadMark>>).value);
      addTearDown(heard.cancel);
      await _arrives(heard, quinlanId, () => quinlan.markRead(club));

      expect(await remy.markRead(club), isA<Ok<void>>());
      await _silent(heard, remyId, reason: "remy's read was broadcast");
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('while I do not share, no read reaches me', () async {
      await share(priyaClient, false);
      final sub = await priya.readUpdates(direct);
      if (sub case Ok(:final value)) {
        final heard = _Heard(value);
        addTearDown(heard.cancel);
        for (var i = 0; i < 5; i++) {
          expect(await quinlan.markRead(direct), isA<Ok<void>>());
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await _silent(heard, quinlanId, reason: 'reads reached a non-sharer');
      }

      // control: the same subscription, while sharing, does hear quinlan
      await priyaClient.removeAllChannels();
      await share(priyaClient, true);
      final again = await priya.readUpdates(direct);
      final heard = _Heard((again as Ok<Stream<ReadMark>>).value);
      addTearDown(heard.cancel);
      await _arrives(heard, quinlanId, () => quinlan.markRead(direct));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a conversation I am not in cannot be listened to', () async {
      final sub = await remy.readUpdates(direct);
      if (sub case Ok(:final value)) {
        // remy shares here, so only membership stops him.
        await share(remyClient, true);
        final heard = _Heard(value);
        addTearDown(heard.cancel);
        for (var i = 0; i < 5; i++) {
          await quinlan.markRead(direct);
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await _silent(heard, quinlanId, reason: 'a non-member heard reads');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('Realtime itself refuses the reads: channel to a non-sharer and '
      'to a non-member', () async {
    final (_, member) = await _join(priyaClient, 'reads:$club', private: true);
    expect(member, RealtimeSubscribeStatus.subscribed, reason: 'control');

    // quinlan is a member of the group, and only his sharing is off.
    await share(quinlanClient, false);
    final (_, nonSharer) = await _join(
      quinlanClient,
      'reads:$club',
      private: true,
    );
    expect(nonSharer, isNot(RealtimeSubscribeStatus.subscribed));

    // remy shares, but is not in priya and quinlan's 1:1.
    await share(remyClient, true);
    final (_, nonMember) = await _join(
      remyClient,
      'reads:$direct',
      private: true,
    );
    expect(nonMember, isNot(RealtimeSubscribeStatus.subscribed));
  }, timeout: const Timeout(Duration(minutes: 1)));

  group('no client can send a read', () {
    /// priya's raw private join of the group's reads: topic, and the first
    /// real read heard on it -- the wire shape a forgery copies, and the
    /// control that this listener does hear reads.
    Future<(List<Map<String, dynamic>>, Map<String, dynamic>)> listen() async {
      final seen = <Map<String, dynamic>>[];
      final (_, status) = await _join(
        priyaClient,
        'reads:$club',
        private: true,
        heard: seen.add,
      );
      expect(status, RealtimeSubscribeStatus.subscribed);
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
        await quinlan.markRead(club);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(seen, isNotEmpty, reason: 'control: no read went over the wire');
      return (seen, seen.first);
    }

    /// [wire] with quinlan claiming to have read it a day from now.
    Map<String, dynamic> forge(Map<String, dynamic> wire, String at) => {
      ...(wire['payload'] as Map).cast<String, dynamic>(),
      'user_id': quinlanId,
      'read_at': at,
    };

    bool forged(List<Map<String, dynamic>> seen, String at) =>
        seen.any((m) => '${m['payload']}'.contains(at));

    final at = DateTime.utc(2099, 1, 1).toIso8601String();

    test('a member cannot send one on the private channel', () async {
      final (seen, wire) = await listen();
      final (ch, _) = await _join(remyClient, 'reads:$club', private: true);
      for (var i = 0; i < 5; i++) {
        await ch.sendBroadcastMessage(
          event: wire['event'] as String,
          payload: forge(wire, at),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(forged(seen, at), isFalse, reason: 'a member forged a read');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an outsider on a public channel of the same name neither hears '
        'reads nor sends one', () async {
      final (seen, wire) = await listen();
      final outsider = _client();
      final witness = _client();
      extra.addAll([outsider, witness]);
      final overheard = <Map<String, dynamic>>[];
      final (_, ws) = await _join(
        witness,
        'reads:$club',
        private: false,
        heard: overheard.add,
      );
      final (pub, ps) = await _join(outsider, 'reads:$club', private: false);

      final count = seen.length;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (seen.length == count && DateTime.now().isBefore(deadline)) {
        await quinlan.markRead(club);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(seen.length, greaterThan(count), reason: 'control: no new read');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(overheard, isEmpty, reason: 'a public listener overheard reads');
      if (ps != RealtimeSubscribeStatus.subscribed) return;

      for (var i = 0; i < 5; i++) {
        await pub.sendBroadcastMessage(
          event: wire['event'] as String,
          payload: forge(wire, at),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(forged(seen, at), isFalse, reason: 'an outsider injected a read');
      if (ws == RealtimeSubscribeStatus.subscribed) {
        expect(
          overheard,
          isNotEmpty,
          reason: 'control: the public forgery never went out at all',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('without app access', () {
    test('a stranger is refused mark_read, and learns nothing', () async {
      final stranger = await _signIn('stranger-reads@integration.test');
      extra.add(stranger);
      expect(
        await stranger.rpc('activate_session'),
        isFalse,
        reason: 'the stranger fixture must not be allowlisted',
      );
      final repo = SupabaseChatRepository(stranger);

      final marked = await repo.markRead(club);
      expect(marked, isA<Err<void>>());
      expect((marked as Err<void>).failure, isA<DeniedFailure>());

      final marks = await repo.readMarks(club);
      if (marks case Ok(:final value)) expect(value, isEmpty);

      final sub = await repo
          .readUpdates(club)
          .timeout(const Duration(seconds: 40));
      expect(sub, isA<Err<Stream<ReadMark>>>());
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
