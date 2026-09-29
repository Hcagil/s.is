@Tags(['integration'])
library;

// Leaving a group, removing members, adding them back, admins (v0.23.0),
// through the real stack: SupabaseChatRepository against a running local
// Supabase, the RPCs as the app calls them, row-level security and Realtime
// as they run. Written from the contract (docs/DECISIONS.md 2026-09-29,
// docs/SECURITY.md "Membership windows", "Admins"), never from the code.
//
// The concurrency races go through two separate clients, each its own HTTP
// connection and so its own database transaction, fired at the same moment:
// only the per-group lock and the commit-time guard can keep two admins who
// demote (or remove) each other at once from leaving a group with nobody in
// charge.
//
// Accounts gia/hol/ike/jun/kai/lux are this suite's alone (supabase/seed.sql).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/group_controller.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/timeline.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> signedIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class Person {
  Person(this.client) : repo = SupabaseChatRepository(client);
  final SupabaseClient client;
  final SupabaseChatRepository repo;
  String get id => client.auth.currentUser!.id;
}

T ok<T>(Result<T> r, [String what = '']) {
  if (r case Err(:final failure)) {
    fail('$what refused: ${failure.message}');
  }
  return (r as Ok<T>).value;
}

Future<Message> say(Person p, String conv, String body) async => ok(
  await p.repo.send(id: randomMessageId(), conversationId: conv, body: body),
  'send "$body"',
);

String nonce() => DateTime.now().microsecondsSinceEpoch.toString();

/// The truth about a group's rows, whatever row-level security says.
Future<List<Map<String, dynamic>>> rowsOf(String conv) async {
  final service = SupabaseClient(_url, serviceKey());
  try {
    final rows = await service
        .from('conversation_members')
        .select('user_id, role, left_at, left_reason')
        .eq('conversation_id', conv);
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  } finally {
    await service.dispose();
  }
}

Future<Set<String>> currentAdmins(String conv) async => {
  for (final r in await rowsOf(conv))
    if (r['left_at'] == null && r['role'] == 'admin') r['user_id'] as String,
};

Future<Set<String>> currentMembers(String conv) async => {
  for (final r in await rowsOf(conv))
    if (r['left_at'] == null) r['user_id'] as String,
};

/// Collects what a stream delivers.
class Tap<T> {
  Tap(Stream<T> s) {
    sub = s.listen(seen.add);
  }
  final seen = <T>[];
  late final StreamSubscription<T> sub;

  Future<void> until(bool Function(List<T>) done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done(seen)) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  final clients = <SupabaseClient>[];
  late Person gia, hol, ike, jun, kai, lux;

  setUpAll(() async {
    Future<Person> p(String e) async {
      final c = await signedIn('$e@integration.test');
      clients.add(c);
      return Person(c);
    }

    gia = await p('gia');
    hol = await p('hol');
    ike = await p('ike');
    jun = await p('jun');
    kai = await p('kai');
    lux = await p('lux');
    // gia reaches everyone but lux. A tag find is stored, so a rerun against
    // the same stack already has it; find_by_tag's rate limit (RLMT1) on a
    // quick rerun is not a failure of this suite. Without the reach every
    // group below fails to start, loudly.
    try {
      await findByTag(gia.client, [
        hol.client,
        ike.client,
        jun.client,
        kai.client,
      ]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
  });

  tearDownAll(() async {
    for (final c in clients) {
      await c.dispose();
    }
  });

  Future<String> newGroup(List<Person> others) async => ok(
    await gia.repo.startGroupConversation(
      title: 'gm ${nonce()}',
      memberIds: [for (final o in others) o.id],
    ),
    'start group',
  );

  test(
    'the roster: the creator is its only admin; a stranger is refused',
    () async {
      final g = await newGroup([hol, ike]);
      final roster = ok(await gia.repo.groupRoster(g), 'roster');
      expect(
        {for (final m in roster) m.member.userId: m.isAdmin},
        {gia.id: true, hol.id: false, ike.id: false},
      );
      expect(roster.every((m) => !m.hasLeft), isTrue);
      expect(
        roster.firstWhere((m) => m.member.userId == hol.id).member.displayName,
        isNotEmpty,
        reason: 'the roster carries names',
      );

      expect(ok(await jun.repo.groupEvents(g)), isEmpty);
    },
  );

  test('a 1:1 has no roster and cannot be left: both refused', () async {
    final direct = ok(await gia.repo.startDirectConversation(ike.id));
    expect(await gia.repo.leaveGroup(direct), isA<Err<void>>());
    final roster = await gia.repo.groupRoster(direct);
    expect(
      roster,
      isA<Err<List<GroupMember>>>(),
      reason:
          'ChatRepository.groupRoster: "The server refuses (DeniedFailure) '
          'for a 1:1"; got ${switch (roster) {
            Ok(:final value) => [for (final m in value) '${m.member.displayName} admin=${m.isAdmin}'],
            Err(:final failure) => failure,
          }}',
    );
    expect((roster as Err).failure, isA<DeniedFailure>());
  });

  test('a group the caller was never in: the roster is refused', () async {
    final g = await newGroup([hol]);
    final roster = await jun.repo.groupRoster(g);
    expect(
      roster,
      isA<Err<List<GroupMember>>>(),
      reason:
          'ChatRepository.groupRoster: refused "for a conversation the '
          'caller was never in"; got ${switch (roster) {
            Ok(:final value) => '${value.length} rows',
            Err(:final failure) => failure,
          }}',
    );
  });

  test('leaving: history up to then, nothing newer by REST or Realtime, the '
      'group stays listed as left, and the admins see who left', () async {
    final g = await newGroup([hol, ike]);
    ok(await gia.repo.setAdmin(g, ike.id, isAdmin: true), 'make ike admin');

    // hol's live subscriptions, proven delivering before she leaves.
    final holOne = Tap(ok(await hol.repo.incoming(g)));
    final holAll = Tap(ok(await hol.repo.incomingAll()));
    final ikeOne = Tap(ok(await ike.repo.incoming(g)));
    final before = await say(gia, g, 'before hol left');
    await holOne.until(
      (s) => s.any((m) => m.id == before.id),
      'hol receives while a member',
    );
    await holAll.until(
      (s) => s.any((m) => m.id == before.id),
      'hol\'s list receives while a member',
    );

    ok(await hol.repo.leaveGroup(g), 'hol leaves');
    final after = await say(gia, g, 'after hol left');
    await ikeOne.until(
      (s) => s.any((m) => m.id == after.id),
      'control: ike receives the later message',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      holOne.seen.map((m) => m.id),
      isNot(contains(after.id)),
      reason: 'Realtime delivered a message sent after she left',
    );
    expect(holAll.seen.map((m) => m.id), isNot(contains(after.id)));
    await holOne.sub.cancel();
    await holAll.sub.cancel();
    await ikeOne.sub.cancel();

    final history = ok(await hol.repo.messages(g)).map((m) => m.id);
    expect(history, contains(before.id));
    expect(
      history,
      isNot(contains(after.id)),
      reason: 'REST read past leaving',
    );
    final search = ok(await hol.repo.search('left', conversationId: g));
    expect(search.map((m) => m.id), [before.id]);

    final listed = ok(await hol.repo.conversations()).where((c) => c.id == g);
    expect(listed, hasLength(1), reason: 'a left group stays in her list');
    expect(listed.single.hasLeft, isTrue);
    expect(listed.single.lastMessage, 'before hol left');
    expect(
      ok(await gia.repo.conversations()).firstWhere((c) => c.id == g).hasLeft,
      isFalse,
    );

    expect(
      await hol.repo.send(id: randomMessageId(), conversationId: g, body: 'x'),
      isA<Err<Message>>(),
      reason: 'a departed member wrote',
    );
    expect(await hol.repo.leaveGroup(g), isA<Err<void>>());

    final roster = ok(await gia.repo.groupRoster(g));
    expect(
      roster.firstWhere((m) => m.member.userId == hol.id).leftReason,
      LeftReason.left,
    );
    for (final admin in [gia, ike]) {
      final events = ok(await admin.repo.groupEvents(g));
      expect(
        events
            .where((e) => e.kind == GroupEventKind.left)
            .map((e) => e.subjectId),
        [hol.id],
      );
    }
    expect(ok(await hol.repo.groupEvents(g)), isEmpty);
  });

  test('removal and adding back without history: the old window stays, the '
      'gap never shows; the departed never learns who came later', () async {
    final g = await newGroup([hol, ike]);
    final early = await say(gia, g, 'early');
    ok(await gia.repo.removeMember(g, hol.id), 'remove hol');
    expect(await gia.repo.removeMember(g, gia.id), isA<Err<void>>());
    expect(await ike.repo.removeMember(g, gia.id), isA<Err<void>>());
    final gap = await say(gia, g, 'gap');

    // lux is not reachable: the whole call fails, kai is not added either.
    expect(
      await gia.repo.addMembers(g, [kai.id, lux.id], withHistory: true),
      isA<Err<void>>(),
    );
    expect(await currentMembers(g), isNot(contains(kai.id)));

    ok(await gia.repo.addMembers(g, [kai.id], withHistory: false), 'add kai');
    final holRoster = ok(await hol.repo.groupRoster(g));
    expect(
      holRoster.map((m) => m.member.userId),
      isNot(contains(kai.id)),
      reason: 'the departed member saw someone who joined after her',
    );
    expect(
      ok(await kai.repo.groupRoster(g)).map((m) => m.member.userId),
      isNot(contains(hol.id)),
      reason: 'a member added without history saw someone who left before',
    );

    final now = await say(gia, g, 'now');
    expect(ok(await kai.repo.messages(g)).map((m) => m.id), [now.id]);

    ok(await gia.repo.addMembers(g, [hol.id], withHistory: false), 'hol back');
    final again = await say(gia, g, 'again');
    expect(ok(await hol.repo.messages(g)).map((m) => m.id), [
      early.id,
      again.id,
    ], reason: 'her old window and her new one, never the gap ${gap.id}');
    final listed = ok(await hol.repo.conversations()).where((c) => c.id == g);
    expect(listed, hasLength(1), reason: 'one row for a rejoined member');
    expect(listed.single.hasLeft, isFalse);
  });

  test(
    'added with history: everything, and everyone who was ever there',
    () async {
      final g = await newGroup([hol]);
      final first = await say(gia, g, 'first');
      ok(await hol.repo.leaveGroup(g));
      ok(await gia.repo.addMembers(g, [jun.id], withHistory: true));
      expect(ok(await jun.repo.messages(g)).map((m) => m.id), [first.id]);
      final roster = ok(await jun.repo.groupRoster(g));
      expect(
        roster.firstWhere((m) => m.member.userId == hol.id).leftReason,
        LeftReason.left,
      );
    },
  );

  test('the controller wired to the real repository: leave marks the list '
      'left and the admin\'s timeline gets the event line', () async {
    final g = await newGroup([hol]);
    await say(gia, g, 'hello');
    final holC = ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(hol.repo)],
    );
    final giaC = ProviderContainer.test(
      overrides: [chatRepositoryProvider.overrideWithValue(gia.repo)],
    );
    holC.listen(conversationListProvider, (_, _) {});
    await holC.read(conversationListProvider.future);

    final r = await holC.read(groupControllerProvider).leave(g);
    expect(r, isA<Ok<bool>>());
    final c = holC
        .read(conversationListProvider)
        .requireValue
        .where((x) => x.id == g);
    expect(c.single.hasLeft, isTrue);

    giaC.listen(conversationListProvider, (_, _) {});
    await giaC.read(conversationListProvider.future);
    giaC.read(openConversationProvider.notifier).open(g);
    giaC.listen(chatTimelineProvider, (_, _) {});
    giaC.listen(messagesProvider, (_, _) {});
    giaC.listen(groupEventsProvider(g), (_, _) {});
    await giaC.read(messagesProvider.future);
    await giaC.read(groupEventsProvider(g).future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final kinds = [
      for (final e in giaC.read(chatTimelineProvider))
        if (e case EventEntry(:final event)) event.kind,
    ];
    expect(kinds, [GroupEventKind.left]);
    holC.dispose();
    giaC.dispose();
  });

  group('two admins at once never leave a group without one', () {
    /// A fresh group run by ike and jun, with kai as its ordinary member.
    Future<String> twoAdmins() async {
      final g = await newGroup([ike, jun, kai]);
      ok(await gia.repo.setAdmin(g, ike.id, isAdmin: true));
      ok(await gia.repo.setAdmin(g, jun.id, isAdmin: true));
      ok(await gia.repo.leaveGroup(g));
      expect(await currentAdmins(g), {ike.id, jun.id}, reason: 'fixture');
      return g;
    }

    const rounds = 6;

    test('demote each other', () async {
      for (var i = 0; i < rounds; i++) {
        final g = await twoAdmins();
        final r = await Future.wait([
          ike.repo.setAdmin(g, jun.id, isAdmin: false),
          jun.repo.setAdmin(g, ike.id, isAdmin: false),
        ]);
        expect(await currentAdmins(g), isNotEmpty, reason: 'round $i: $r');
        expect(r.whereType<Ok<void>>(), hasLength(1), reason: 'round $i');
      }
    });

    test('remove each other', () async {
      for (var i = 0; i < rounds; i++) {
        final g = await twoAdmins();
        final r = await Future.wait([
          ike.repo.removeMember(g, jun.id),
          jun.repo.removeMember(g, ike.id),
        ]);
        expect(await currentAdmins(g), isNotEmpty, reason: 'round $i: $r');
        expect(r.whereType<Ok<void>>(), hasLength(1), reason: 'round $i');
      }
    });

    test('one leaves while the other demotes herself', () async {
      for (var i = 0; i < rounds; i++) {
        final g = await twoAdmins();
        await Future.wait([
          ike.repo.leaveGroup(g),
          jun.repo.setAdmin(g, jun.id, isAdmin: false),
        ]);
        expect(
          await currentAdmins(g),
          isNotEmpty,
          reason: 'round $i: ${await rowsOf(g)}',
        );
      }
    });
  });
}
