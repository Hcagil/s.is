@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_reaction_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/reaction.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// Reactions (Update 1 slice 6) on the real local stack, through
/// [SupabaseReactionRepository]: set / change / clear through the
/// `set_reaction` RPC, the reactions() load (non-null emojis, newest change
/// first, at most 1000), the postgres_changes feed on `message_reactions`
/// filtered by conversation (a clear arrives as a null emoji), usage over the
/// caller's last 300 reactions, and the server's refusals as the migration
/// (20261005140000) defines them: 42501 -> DeniedFailure for a non-member or a
/// deleted message; 22023 for an emoji that is empty, over 64 bytes, or holds
/// whitespace -- a failure, but not a DeniedFailure.
///
/// Accounts priya, quinlan and remy are shared with other suites; every run
/// makes new conversations. The bulk fixtures (1001 rows) are written with the
/// service key and removed at the end. Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what${DateTime.now().microsecondsSinceEpoch}';

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok: $r');
  return (r as Ok<T>).value;
}

Failure _err<T>(Result<T> r) {
  expect(r, isA<Err<T>>(), reason: 'expected Err: $r');
  return (r as Err<T>).failure;
}

List<(String, String, String?)> _rows(Iterable<Reaction> rs) => [
  for (final r in rs) (r.messageId, r.userId, r.emoji),
];

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient;
  late SupabaseChatRepository priyaChat;
  late SupabaseReactionRepository priya, quinlan, remy;
  late String priyaId, quinlanId;
  late String club; // priya + quinlan; remy is not in it
  late String other; // priya + quinlan, a second chat for the feed filter
  final cleanup = <String>[];
  SupabaseClient? service;

  Future<String> send(String conversation) async {
    final r = await priyaChat.send(
      id: randomMessageId(),
      conversationId: conversation,
      body: _stamp('r '),
    );
    return _ok(r).id;
  }

  setUpAll(() async {
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priyaChat = SupabaseChatRepository(priyaClient);
    priya = SupabaseReactionRepository(priyaClient);
    quinlan = SupabaseReactionRepository(quinlanClient);
    remy = SupabaseReactionRepository(remyClient);
    priyaId = priyaClient.auth.currentUser!.id;
    quinlanId = quinlanClient.auth.currentUser!.id;
    await findByTag(priyaClient, [quinlanClient, remyClient]);
    club = _ok(
      await priyaChat.startGroupConversation(
        title: _stamp('reactions '),
        memberIds: [quinlanId],
      ),
    );
    other = _ok(
      await priyaChat.startGroupConversation(
        title: _stamp('reactions other '),
        memberIds: [quinlanId],
      ),
    );
    cleanup.addAll([club, other]);
  });

  tearDown(() async {
    for (final c in [priyaClient, quinlanClient, remyClient]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    final s = service;
    if (s != null) {
      for (final id in cleanup) {
        await s.from('conversations').delete().eq('id', id);
      }
      await s.dispose();
    }
    for (final c in [priyaClient, quinlanClient, remyClient]) {
      await c.dispose();
    }
  });

  group('set, change, clear -> reactions()', () {
    test('one reaction per person; a change replaces it; a clear removes it; '
        'newest change first; no null emojis', () async {
      final m = await send(club);
      _ok(await priya.setReaction(m, '👍'));
      expect(_rows(_ok(await quinlan.reactions(club))), [(m, priyaId, '👍')]);

      _ok(await priya.setReaction(m, '❤️'));
      _ok(await quinlan.setReaction(m, '😂'));
      expect(_rows(_ok(await priya.reactions(club))), [
        (m, quinlanId, '😂'),
        (m, priyaId, '❤️'),
      ]);

      _ok(await priya.setReaction(m, null));
      expect(_rows(_ok(await priya.reactions(club))), [(m, quinlanId, '😂')]);

      // Set again: the server never toggles, so the same call twice is one
      // reaction, and a clear twice is harmless.
      _ok(await priya.setReaction(m, '🔥'));
      _ok(await priya.setReaction(m, '🔥'));
      _ok(await priya.setReaction(m, null));
      _ok(await priya.setReaction(m, null));
      expect(_rows(_ok(await quinlan.reactions(club))), [(m, quinlanId, '😂')]);
    });
  });

  group('reactionUpdates', () {
    test('a set and a clear reach the other member; the clear as a null '
        'emoji; another chat\'s reactions do not', () async {
      final m = await send(club);
      final elsewhere = await send(other);
      final stream = _ok(await quinlan.reactionUpdates(club));
      final heard = <Reaction>[];
      final sub = stream.listen(heard.add);
      addTearDown(sub.cancel);
      final topic = 'realtime:reactions:$club';
      bool open() => quinlanClient.getChannels().any((c) => c.topic == topic);
      expect(open(), isTrue, reason: 'the channel is reactions:<cid>');

      Future<void> until(bool Function() ok, String what) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (!ok()) {
          if (DateTime.now().isAfter(end)) fail('never heard $what: $heard');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      _ok(await priya.setReaction(elsewhere, '👀'));
      _ok(await priya.setReaction(m, '🎉'));
      await until(
        () => heard.any((r) => r.messageId == m && r.emoji == '🎉'),
        'the set',
      );
      _ok(await priya.setReaction(m, null));
      await until(
        () => heard.any((r) => r.messageId == m && r.emoji == null),
        'the clear',
      );
      // Realtime reads the WAL behind the writes: changes made before this
      // subscription (earlier tests) can still arrive on it, so only this
      // message's events are compared.

      expect(
        _rows(heard.where((r) => r.messageId == m)),
        reason: 'heard: ${_rows(heard)}',
        [(m, priyaId, '🎉'), (m, priyaId, null)],
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(heard.where((r) => r.messageId == elsewhere), isEmpty);

      // Cancelling the stream leaves the channel.
      await sub.cancel();
      await until(() => !open(), 'the channel left');
    });

    test('a non-member subscribing hears nothing of the chat', () async {
      final m = await send(club);
      final joined = await remy.reactionUpdates(club);
      final heard = <Reaction>[];
      if (joined case Ok(:final value)) {
        final sub = value.listen(heard.add, onError: (_) {});
        addTearDown(sub.cancel);
      }
      // Give the join time to be confirmed before the change.
      await Future<void>.delayed(const Duration(seconds: 1));
      _ok(await priya.setReaction(m, '🤫'));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(heard, isEmpty);
    });
  });

  group('refusals', () {
    test('a non-member: setReaction is DeniedFailure (42501); reactions() '
        'shows nothing', () async {
      final m = await send(club);
      _ok(await priya.setReaction(m, '👍'));
      expect(_err(await remy.setReaction(m, '👍')), isA<DeniedFailure>());
      expect(_err(await remy.setReaction(m, null)), isA<DeniedFailure>());
      expect(_ok(await remy.reactions(club)), isEmpty);
    });

    test('a deleted message: DeniedFailure, and its reactions are gone from '
        'the load', () async {
      final m = await send(club);
      _ok(await quinlan.setReaction(m, '👍'));
      final msg = _ok(await priyaChat.messages(club))
          .singleWhere((x) => x.id == m);
      _ok(await priyaChat.deleteForEveryone(msg));
      expect(_err(await quinlan.setReaction(m, '❤️')), isA<DeniedFailure>());
      expect(
        _ok(await quinlan.reactions(club)).where((r) => r.messageId == m),
        isEmpty,
      );
    });

    test('the emoji limits: 1..64 bytes, no whitespace or control '
        'characters; a bad one fails, and not as DeniedFailure', () async {
      final m = await send(club);
      final sixtyFour = List.filled(16, '😀').join(); // 4 bytes each
      expect(utf8.encode(sixtyFour), hasLength(64));
      _ok(await priya.setReaction(m, sixtyFour));
      for (final bad in ['', '$sixtyFour!', '👍 ', 'a\tb', 'x\u0007']) {
        final f = _err(await priya.setReaction(m, bad));
        expect(f, isNot(isA<DeniedFailure>()), reason: 'emoji "$bad"');
      }
      expect(
        _rows(_ok(await priya.reactions(club)).where((r) => r.messageId == m)),
        [(m, priyaId, sixtyFour)],
        reason: 'a refused set leaves the reaction as it was',
      );
    });

    test('signed out: myReactionUsage is DeniedFailure', () async {
      final nobody = _client(_key);
      addTearDown(nobody.dispose);
      expect(
        _err(await SupabaseReactionRepository(nobody).myReactionUsage()),
        isA<DeniedFailure>(),
      );
    });
  });

  group('usage', () {
    test('counts the caller\'s own reactions per emoji', () async {
      final a = await send(club);
      final b = await send(club);
      final x = _stamp('x');
      _ok(await priya.setReaction(a, x));
      _ok(await priya.setReaction(b, x));
      _ok(await quinlan.setReaction(a, '${x}q'));
      final used = _ok(await priya.myReactionUsage());
      expect(used[x], 2);
      expect(used.containsKey('${x}q'), isFalse, reason: 'not someone else\'s');
    });
  });

  group('the caps, on 1001 reactions', () {
    late String bulk;
    late List<String> ids; // oldest reaction first
    late String oldEmoji, newEmoji;

    setUpAll(() async {
      service = _client(serviceKey());
      bulk = _ok(
        await priyaChat.startGroupConversation(
          title: _stamp('reactions bulk '),
          memberIds: [quinlanId],
        ),
      );
      cleanup.add(bulk);
      ids = [for (var i = 0; i < 1001; i++) randomMessageId()];
      final t0 = DateTime.now().toUtc().subtract(const Duration(hours: 1));
      await service!.from('messages').insert([
        for (var i = 0; i < ids.length; i++)
          {
            'id': ids[i],
            'conversation_id': bulk,
            'sender_id': quinlanId,
            'body': 'bulk $i',
            'created_at': t0.add(Duration(milliseconds: i)).toIso8601String(),
          },
      ]);
      // priya's newest reactions anywhere: an hour ahead of now, so nothing
      // set during the run is newer.
      final r0 = DateTime.now().toUtc().add(const Duration(hours: 1));
      oldEmoji = _stamp('o');
      newEmoji = _stamp('n');
      await service!.from('message_reactions').insert([
        for (var i = 0; i < ids.length; i++)
          {
            'message_id': ids[i],
            'user_id': priyaId,
            'conversation_id': bulk,
            'emoji': i >= ids.length - 300 ? newEmoji : oldEmoji,
            'updated_at': r0.add(Duration(seconds: i)).toIso8601String(),
          },
      ]);
    });

    test('reactions(): at most 1000, the newest change first', () async {
      final got = _ok(await quinlan.reactions(bulk));
      expect(got, hasLength(1000));
      expect(got.first.messageId, ids.last);
      expect(got.last.messageId, ids[1]);
      expect(got.map((r) => r.messageId), isNot(contains(ids.first)));
    });

    test('usage: only the caller\'s last 300 reactions count', () async {
      final used = _ok(await priya.myReactionUsage());
      expect(used[newEmoji], 300);
      expect(used.containsKey(oldEmoji), isFalse);
    });
  });
}
