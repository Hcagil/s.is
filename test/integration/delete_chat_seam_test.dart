// Delete chat, end to end: chatDeleteProvider wired as main.dart mounts it
// (SupabaseChatRepository, SupabaseGroupSettingsRepository,
// SupabaseChatDeleteRepository over one client) against the local stack.
// Each case waits out the real 5 s undo window, then checks the server and a
// fresh list read -- the seam a fake cannot see: does the reload after the
// commit really leave the chat out, and does undo really leave the server
// alone.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_delete_controller.dart';
import 'package:sis/features/chat/data/supabase_chat_delete_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_group_settings_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
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

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r, [String what = '']) {
  if (r case Err(:final failure)) fail('$what refused: ${failure.message}');
  return (r as Ok<T>).value;
}

String _nonce() => DateTime.now().microsecondsSinceEpoch.toString();

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

/// One member's app, with main.dart's overrides over [client]; [deleteVia]
/// replaces only the delete repository's client (the offline case).
class _App {
  _App(this.client, {SupabaseClient? deleteVia}) {
    final me = client.auth.currentUser!.id;
    container = ProviderContainer.test(
      overrides: [
        sessionControllerProvider.overrideWith(
          () => _SignedIn(Member(userId: me, displayName: me)),
        ),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
        groupSettingsRepositoryProvider.overrideWithValue(
          SupabaseGroupSettingsRepository(client),
        ),
        chatDeleteRepositoryProvider.overrideWithValue(
          SupabaseChatDeleteRepository(deleteVia ?? client),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(client),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(client),
        ),
      ],
    );
    container.listen(conversationListProvider, (_, _) {});
    container.listen(chatDeleteProvider, (_, _) {});
  }

  final SupabaseClient client;
  late final ProviderContainer container;

  Future<void> ready() async {
    await container.read(sessionControllerProvider.future);
    await container.read(conversationListProvider.future);
  }

  List<Conversation> get rows =>
      container.read(conversationListProvider).value ?? const [];
  bool lists(String id) => rows.any((c) => c.id == id);
  Conversation row(String id) => rows.firstWhere((c) => c.id == id);
  ChatDeleteState get state => container.read(chatDeleteProvider);
  ChatDelete get delete => container.read(chatDeleteProvider.notifier);

  /// Starts a delete of [ids] and waits out the window and the commit.
  Future<void> deleteAndWait(List<String> ids, {required bool both}) async {
    delete.start([for (final id in ids) row(id)], alsoForOthers: both);
    for (final id in ids) {
      expect(lists(id), isFalse, reason: '$id still listed during the window');
    }
    await Future<void>.delayed(const Duration(seconds: 5));
    await _until(() => state.notice == null, 'the undo window to close');
    // the commit and its quiet reload
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  /// A fresh read through a new app, as on the next cold start.
  Future<List<String>> freshIds() async {
    final r = _ok(await SupabaseChatRepository(client).conversations(), 'list');
    return [for (final c in r) c.id];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient ash, bea, cyd, service;
  String idOf(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    ash = await _signedIn('dc-ash@integration.test');
    bea = await _signedIn('dc-bea@integration.test');
    cyd = await _signedIn('dc-cyd@integration.test');
    service = SupabaseClient(_url, serviceKey());
    for (final c in [ash, bea, cyd]) {
      await c
          .from('profiles')
          .update({'onboarding_done': true})
          .eq('user_id', idOf(c));
    }
    try {
      await findByTag(ash, [bea, cyd]);
      await findByTag(bea, [cyd]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
  });

  tearDownAll(() async {
    for (final c in [ash, bea, cyd, service]) {
      await c.dispose();
    }
  });

  /// A fresh 1:1 between [a] and [b] with one message from each. A pair has
  /// one 1:1, so a rerun first clears what an earlier run left behind.
  Future<String> direct(SupabaseClient a, SupabaseClient b) async {
    final id = _ok(
      await SupabaseChatRepository(a).startDirectConversation(idOf(b)),
      'start 1:1',
    );
    await service.from('chat_hides').delete().eq('conversation_id', id);
    for (final c in [a, b]) {
      _ok(
        await SupabaseChatRepository(c).send(
          id: randomMessageId(),
          conversationId: id,
          body: 'dc ${_nonce()}',
        ),
        'send',
      );
    }
    return id;
  }

  Future<String> group(
    SupabaseClient admin,
    List<SupabaseClient> others,
  ) async {
    final id = _ok(
      await SupabaseChatRepository(admin).startGroupConversation(
        title: 'dc ${_nonce()}',
        memberIds: [for (final o in others) idOf(o)],
      ),
      'start group',
    );
    _ok(
      await SupabaseChatRepository(admin)
          .send(id: randomMessageId(), conversationId: id, body: 'dc group'),
      'send',
    );
    return id;
  }

  Future<int> readable(SupabaseClient c, String conv) async =>
      (await c.from('messages').select('id').eq('conversation_id', conv))
          .length;

  Future<bool> exists(String conv) async =>
      (await service
          .from('conversations')
          .select('id')
          .eq('id', conv)
          .maybeSingle()) !=
      null;

  test('delete for me: the 1:1 is hidden for ash only and stays out of '
      'the reloaded list', () async {
    final conv = await direct(ash, bea);
    final app = _App(ash);
    addTearDown(app.container.dispose);
    await app.ready();
    expect(app.lists(conv), isTrue);
    final beaSees = await readable(bea, conv);

    await app.deleteAndWait([conv], both: false);

    expect(app.state.failure, isNull);
    expect(app.lists(conv), isFalse, reason: 'back after the quiet reload');
    expect(await app.freshIds(), isNot(contains(conv)));
    expect(await readable(ash, conv), 0);
    expect(await readable(bea, conv), beaSees, reason: 'bea lost messages');
    expect(
      await ash.from('chat_hides').select().eq('conversation_id', conv),
      hasLength(1),
    );
    expect(await exists(conv), isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('delete for both: the 1:1 is gone for both', () async {
    final conv = await direct(ash, cyd);
    final app = _App(ash);
    addTearDown(app.container.dispose);
    await app.ready();

    await app.deleteAndWait([conv], both: true);

    expect(app.state.failure, isNull);
    expect(app.lists(conv), isFalse);
    expect(await exists(conv), isFalse);
    final cydList = _ok(await SupabaseChatRepository(cyd).conversations());
    expect([for (final c in cydList) c.id], isNot(contains(conv)));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a group as a member: bea leaves it, then it is hidden for her; the '
      'group lives on', () async {
    final g = await group(ash, [bea, cyd]);
    final app = _App(bea);
    addTearDown(app.container.dispose);
    await app.ready();
    expect(app.row(g).isAdmin, isFalse);

    await app.deleteAndWait([g], both: false);

    expect(app.state.failure, isNull);
    expect(app.lists(g), isFalse);
    expect(await app.freshIds(), isNot(contains(g)));
    final mine = await service
        .from('conversation_members')
        .select('left_at')
        .eq('conversation_id', g)
        .eq('user_id', idOf(bea))
        .single();
    expect(mine['left_at'], isNotNull, reason: 'bea did not leave');
    expect(await exists(g), isTrue);
    expect(await readable(ash, g), 1);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('the only admin, ticked: the group is deleted for everyone', () async {
    final g = await group(ash, [bea]);
    final app = _App(ash);
    addTearDown(app.container.dispose);
    await app.ready();
    expect(app.row(g).isAdmin, isTrue);

    await app.deleteAndWait([g], both: true);

    expect(app.state.failure, isNull);
    expect(app.lists(g), isFalse);
    expect(await exists(g), isFalse);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('undo: the row is back and the server never heard of it', () async {
    final conv = await direct(bea, cyd);
    final app = _App(bea);
    addTearDown(app.container.dispose);
    await app.ready();
    final before = [for (final c in app.rows) c.id];
    final seen = await readable(bea, conv);

    app.delete.start([app.row(conv)], alsoForOthers: true);
    expect(app.lists(conv), isFalse);
    await Future<void>.delayed(const Duration(seconds: 2));
    app.delete.undo();
    expect([for (final c in app.rows) c.id], before);

    await Future<void>.delayed(const Duration(seconds: 6));
    expect(app.lists(conv), isTrue);
    expect(await exists(conv), isTrue);
    expect(await readable(bea, conv), seen);
    expect(
      await bea.from('chat_hides').select().eq('conversation_id', conv),
      isEmpty,
    );
    expect(await app.freshIds(), contains(conv));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('offline: the delete fails, a failure is reported and the row comes '
      'back on reload', () async {
    final conv = await direct(ash, bea);
    final dead = await deadButSignedIn(ash);
    addTearDown(dead.dispose);
    final app = _App(ash, deleteVia: dead);
    addTearDown(app.container.dispose);
    await app.ready();
    final seen = await readable(ash, conv);

    await app.deleteAndWait([conv], both: false);
    await _until(() => app.lists(conv), 'the row to come back');

    expect(app.state.failure, isNotNull);
    expect(
      await readable(ash, conv),
      seen,
      reason: 'something reached the server',
    );
    expect(await app.freshIds(), contains(conv));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
