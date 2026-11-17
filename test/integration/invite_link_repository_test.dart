@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_group_settings_repository.dart';
import 'package:sis/features/chat/data/supabase_invite_link_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/invite_link.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// Invite link repository integration tests against the real local Supabase stack.
/// Accounts: ilk-boss@mail.test (boss), ilk-mate@mail.test (mate),
/// ilk-other@mail.test (other), ilk-rater@mail.test (rater).
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

Object _fail<T>(Result<T> r) => (r as Err<T>).failure;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient boss, mate, other, rater, service;
  String idOf(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    boss = await _signedIn('ilk-boss@mail.test');
    mate = await _signedIn('ilk-mate@mail.test');
    other = await _signedIn('ilk-other@mail.test');
    rater = await _signedIn('ilk-rater@mail.test');
    service = SupabaseClient(_url, serviceKey());
    try {
      await findByTag(boss, [mate, other, rater]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
  });

  tearDownAll(() async {
    for (final c in [boss, mate, other, rater, service]) {
      await c.dispose();
    }
  });

  Future<String> newGroup() async => _ok(
    await SupabaseChatRepository(boss).startGroupConversation(
      title: 'ilk ${DateTime.now().microsecondsSinceEpoch}',
      memberIds: [idOf(mate)],
    ),
    'start group',
  );

  Future<void> hello(String g) async => service.from('messages').insert({
    'conversation_id': g,
    'sender_id': idOf(boss),
    'body': 'hi',
  });

  test('the admin resets, reads and turns the link off', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    final reset1 = _ok(await bossIr.resetInviteLink(g, validDays: 7), 'reset1');
    expect(reset1.token.length, 24);
    final now = DateTime.now();
    expect(
      reset1.expiresAt!
          .difference(now.add(const Duration(days: 7)))
          .inSeconds
          .abs(),
      lessThan(120),
    );
    final link1 = _ok(await bossIr.inviteLink(g), 'link1');
    expect(link1!.token, reset1.token);
    final reset2 = _ok(
      await bossIr.resetInviteLink(g, validDays: null),
      'reset2',
    );
    expect(reset2.expiresAt, isNull);
    expect(reset2.token, isNot(reset1.token));
    _ok(await bossIr.turnOffInviteLink(g), 'turnOff');
    final linkAfterOff = _ok(await bossIr.inviteLink(g), 'linkAfterOff');
    expect(linkAfterOff, isNull);
    _ok(await bossIr.turnOffInviteLink(g), 'turnOffAgain');
  });

  test('a member and a stranger are refused', () async {
    final g = await newGroup();
    for (final c in [mate, other]) {
      final ir = SupabaseInviteLinkRepository(c);
      expect(await ir.inviteLink(g), isA<Err<InviteLink?>>());
      expect(await ir.resetInviteLink(g, validDays: 7), isA<Err<InviteLink>>());
      expect(await ir.turnOffInviteLink(g), isA<Err<void>>());
    }
  });

  test('an invalid validity is refused', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    expect(
      await bossIr.resetInviteLink(g, validDays: 5),
      isA<Err<InviteLink>>(),
    );
  });

  test('preview does not join, join does, join twice is fine, the admin reads the joined event', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    final otherIr = SupabaseInviteLinkRepository(other);
    final reset = _ok(await bossIr.resetInviteLink(g, validDays: 7), 'reset');
    final token = reset.token;
    final preview = _ok(await otherIr.previewInvite(token), 'preview');
    expect(preview.title.startsWith('ilk'), isTrue);
    expect(preview.memberCount, 2);
    expect(preview.conversationId, g);
    final before = await service
        .from('conversation_members')
        .select('user_id')
        .eq('conversation_id', g)
        .eq('user_id', idOf(other));
    expect(before, isEmpty);
    final join = _ok(await otherIr.joinByInvite(token), 'join');
    expect(join, g);
    final after = await service
        .from('conversation_members')
        .select('user_id')
        .eq('conversation_id', g)
        .eq('user_id', idOf(other));
    expect(after, hasLength(1));
    final joinAgain = _ok(await otherIr.joinByInvite(token), 'joinAgain');
    expect(joinAgain, g);
    final events = _ok(await bossIr.joinEvents(g), 'events');
    expect(events, hasLength(1));
    expect(events.single.kind, GroupEventKind.joined);
    expect(events.single.conversationId, g);
  });

  test('a reset and a turn off kill the old token', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    final otherIr = SupabaseInviteLinkRepository(other);
    final t1 = _ok(await bossIr.resetInviteLink(g, validDays: 7), 't1');
    final t2 = _ok(await bossIr.resetInviteLink(g, validDays: 7), 't2');
    final fail1 = _fail(await otherIr.joinByInvite(t1.token));
    expect(fail1, isA<InviteLinkFailure>());
    expect((fail1 as InviteLinkFailure).problem, InviteLinkProblem.invalid);
    _ok(await bossIr.turnOffInviteLink(g), 'turnOff');
    final fail2 = _fail(await otherIr.previewInvite(t2.token));
    expect(fail2, isA<InviteLinkFailure>());
    expect((fail2 as InviteLinkFailure).problem, InviteLinkProblem.invalid);
  });

  test('a person an admin removed gets removed', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    final otherIr = SupabaseInviteLinkRepository(other);
    final reset = _ok(await bossIr.resetInviteLink(g, validDays: 7), 'reset');
    final token = reset.token;
    final join = _ok(await otherIr.joinByInvite(token), 'join');
    expect(join, g);
    _ok(
      await SupabaseChatRepository(boss).removeMember(g, idOf(other)),
      'remove',
    );
    final fail = _fail(await otherIr.joinByInvite(token));
    expect(fail, isA<InviteLinkFailure>());
    expect((fail as InviteLinkFailure).problem, InviteLinkProblem.removed);
    final preview = _fail(await otherIr.previewInvite(token));
    expect(preview, isA<InviteLinkFailure>());
    expect((preview as InviteLinkFailure).problem, InviteLinkProblem.removed);
  });

  test('a closed group answers closed', () async {
    final g = await newGroup();
    await hello(g);
    final bossIr = SupabaseInviteLinkRepository(boss);
    final otherIr = SupabaseInviteLinkRepository(other);
    final reset = _ok(await bossIr.resetInviteLink(g, validDays: 7), 'reset');
    final token = reset.token;
    _ok(await SupabaseGroupSettingsRepository(boss).closeGroup(g), 'close');
    final preview = _fail(await otherIr.previewInvite(token));
    expect(preview, isA<InviteLinkFailure>());
    expect((preview as InviteLinkFailure).problem, InviteLinkProblem.closed);
  });

  test('junk codes are invalid', () async {
    final otherIr = SupabaseInviteLinkRepository(other);
    final junk1 = _fail(await otherIr.joinByInvite('Q' * 24));
    expect(junk1, isA<InviteLinkFailure>());
    expect((junk1 as InviteLinkFailure).problem, InviteLinkProblem.invalid);
    final junk2 = _fail(await otherIr.joinByInvite('short'));
    expect(junk2, isA<InviteLinkFailure>());
    expect((junk2 as InviteLinkFailure).problem, InviteLinkProblem.invalid);
  });

  test('the shared limit answers SearchLimitFailure', () async {
    final g = await newGroup();
    final bossIr = SupabaseInviteLinkRepository(boss);
    final token = _ok(
      await bossIr.resetInviteLink(g, validDays: 7),
      'reset',
    ).token;
    final raterIr = SupabaseInviteLinkRepository(rater);
    for (var i = 1; i <= 25; i++) {
      final r = await raterIr.previewInvite(token);
      if (r case Err(:final failure)) {
        expect(failure, isA<SearchLimitFailure>());
        expect(i, inInclusiveRange(1, 21));
        return;
      }
    }
    fail('no refusal after 25 previews');
  });
}
