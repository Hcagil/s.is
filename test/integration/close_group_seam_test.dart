@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_group_settings_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

/// Close group, the app's repositories against the real local stack: the
/// close_group and group_member_events RPCs, the roster read and the
/// debug_chat flag as the conversation list reads it. Own accounts (clo-*).
///
/// Requires the local stack and SUPABASE_TEST_SERVICE_KEY.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r, [String what = '']) {
  if (r case Err(:final failure)) fail('$what refused: ${failure.message}');
  return (r as Ok<T>).value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient boss, mate, other, service;
  String idOf(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    boss = await _signedIn('clo-boss@integration.test');
    mate = await _signedIn('clo-mate@integration.test');
    other = await _signedIn('clo-other@integration.test');
    service = SupabaseClient(_url, serviceKey());
    try {
      await findByTag(boss, [mate, other]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
  });

  tearDownAll(() async {
    for (final c in [boss, mate, other, service]) {
      await c.dispose();
    }
  });

  Future<String> newGroup() async => _ok(
    await SupabaseChatRepository(boss).startGroupConversation(
      title: 'clo ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [idOf(mate), idOf(other)],
    ),
    'start group',
  );

  Future<void> hello(String g) async => service.from('messages').insert({
    'conversation_id': g,
    'sender_id': idOf(boss),
    'body': 'hi',
  });

  test('closeGroup: the admin closes; a member and a second close are '
      'refused; closeEvents then holds one closed event', () async {
    final g = await newGroup();
    await hello(g); // an empty group is dropped at once, not closed
    final admin = SupabaseGroupSettingsRepository(boss);
    final member = SupabaseGroupSettingsRepository(mate);

    // A removal earlier on leaves a 'removed' event that closeEvents must skip.
    _ok(await SupabaseChatRepository(boss).removeMember(g, idOf(other)));
    expect(_ok(await admin.closeEvents(g)), isEmpty);
    final denied = await member.closeGroup(g);
    expect(denied, isA<Err<void>>());
    expect((denied as Err<void>).failure, isA<DeniedFailure>());
    expect(
      (await service
          .from('conversations')
          .select('closed_at')
          .eq('id', g)
          .single())['closed_at'],
      isNull,
      reason: 'the refused call closed nothing',
    );

    expect(await admin.closeGroup(g), isA<Ok<void>>());
    final again = await admin.closeGroup(g);
    expect(again, isA<Err<void>>());
    expect((again as Err<void>).failure, isA<DeniedFailure>());

    // Every member, also one the close removed, reads the one closed event.
    for (final c in [boss, mate]) {
      final events = _ok(
        await SupabaseGroupSettingsRepository(c).closeEvents(g),
      );
      expect(events, hasLength(1));
      expect(events.single.kind, GroupEventKind.closed);
      expect(events.single.conversationId, g);
      expect(events.single.actorId, idOf(boss));
      expect(events.single.subjectId, idOf(boss));
    }
  });

  test('roster: readable for a member of an open group and after the '
      'close, which names the closer through the closed event', () async {
    final g = await newGroup();
    await hello(g);
    // Regression guard: the roster read must not select a column clients
    // cannot read (it once did, and every roster came back denied).
    for (final c in [boss, mate]) {
      final before = _ok(await SupabaseChatRepository(c).groupRoster(g));
      expect(before, hasLength(3));
      expect(before.any((m) => m.hasLeft), isFalse);
    }

    _ok(await SupabaseGroupSettingsRepository(boss).closeGroup(g), 'close');
    for (final c in [boss, mate]) {
      final roster = _ok(await SupabaseChatRepository(c).groupRoster(g));
      expect(roster, hasLength(3));
      for (final m in roster) {
        expect(m.leftReason, LeftReason.removed, reason: m.member.userId);
      }
      final closed = _ok(
        await SupabaseGroupSettingsRepository(c).closeEvents(g),
      );
      expect(closed.single.actorId, idOf(boss));
    }
  });

  test('isClosed: the real chat_list() marks a closed group closed, an open '
      'one open, for the admin and for a removed member', () async {
    final open = await newGroup();
    final shut = await newGroup();
    await hello(open);
    await hello(shut);
    Future<Map<String, bool>> closedFlags(SupabaseClient c) async {
      final list = _ok(await SupabaseChatRepository(c).conversations());
      return {for (final x in list) x.id: x.isClosed};
    }

    var flags = await closedFlags(boss);
    expect(flags[open], isFalse);
    expect(flags[shut], isFalse, reason: 'not closed yet');

    _ok(await SupabaseGroupSettingsRepository(boss).closeGroup(shut), 'close');
    for (final c in [boss, mate]) {
      flags = await closedFlags(c);
      expect(flags[shut], isTrue, reason: 'closed group, ${idOf(c)}');
      expect(flags[open], isFalse, reason: 'the other group stays open');
    }
  });

  test('debugChat: true for the Debug group, false for a normal one, as the '
      'conversation list reads it', () async {
    final debug = await newGroup();
    final plain = await newGroup();
    // The bot_accounts insert (pgTAP debug_chat_flag_test) sets the column;
    // here only the app's read of it is under test.
    await service
        .from('conversations')
        .update({'debug_chat': true})
        .eq('id', debug);
    final list = _ok(await SupabaseChatRepository(boss).conversations());
    final byId = {for (final c in list) c.id: c};
    expect(byId[debug]!.settings.debugChat, isTrue);
    expect(byId[plain]!.settings.debugChat, isFalse);
  });

  test('offline: closeGroup and closeEvents fail with a reason', () async {
    final g = await newGroup();
    await hello(g);
    final dead = await deadButSignedIn(boss);
    addTearDown(dead.dispose);
    final repo = SupabaseGroupSettingsRepository(dead);
    expect(await repo.closeGroup(g), isA<Err<void>>());
    expect(await repo.closeEvents(g), isA<Err<List<GroupEvent>>>());
    expect(
      (await service
          .from('conversations')
          .select('closed_at')
          .eq('id', g)
          .single())['closed_at'],
      isNull,
    );
  });
}
