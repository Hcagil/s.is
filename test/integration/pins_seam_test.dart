@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_archive_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_pin_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_delete_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/supabase_notification_settings_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';

/// Pins over the real local stack: [SupabaseChatPinRepository] against the
/// chat_pins table, its triggers and the pin RPCs, and SisApp wired as
/// main.dart wires it, pinning a chat and a message through the UI and
/// reading both back from the database. pina/pinb are this suite's own
/// accounts (supabase/seed.sql).
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
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

Failure _err<T>(Result<T> r, String what) {
  if (r is Ok<T>) fail('$what was allowed');
  return (r as Err<T>).failure;
}

String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient pina;
  late SupabaseClient pinb;
  late String direct;
  late String pinaId;

  Future<void> clearPins() async {
    await pina.from('chat_pins').delete().eq('user_id', pinaId);
    await pina.from('chat_archives').delete().eq('user_id', pinaId);
    await pina.rpc(
      'set_pinned_message',
      params: {'conversation': direct, 'message': null},
    );
  }

  Future<Message> say(String body) async => _ok(
    await SupabaseChatRepository(pina)
        .send(id: randomMessageId(), conversationId: direct, body: body),
    'pina writes',
  );

  Future<List<String>> pinnedChats() async => [
    for (final r
        in await pina
            .from('chat_pins')
            .select('conversation_id')
            .eq('user_id', pinaId))
      r['conversation_id'] as String,
  ];

  Future<String?> pinnedMessageId() async =>
      (await pina
              .from('conversations')
              .select('pinned_message_id')
              .eq('id', direct)
              .single())['pinned_message_id']
          as String?;

  setUpAll(() async {
    pina = await _signedIn('pina@integration.test');
    pinb = await _signedIn('pinb@integration.test');
    pinaId = pina.auth.currentUser!.id;
    await pina
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', pinaId);
    await findByTag(pina, [pinb]);
    direct = _ok(
      await SupabaseChatRepository(pina)
          .startDirectConversation(pinb.auth.currentUser!.id),
      'start the pina-pinb chat',
    );
    await say('pins seam');
    _ok(await SupabaseChatRepository(pina).markRead(direct), 'pina reads');
  });

  setUp(clearPins);

  tearDownAll(() async {
    await clearPins();
    await pina.dispose();
    await pinb.dispose();
  });

  group('SupabaseChatPinRepository', () {
    test('pins and unpins a chat; the list reads it back', () async {
      final repo = SupabaseChatPinRepository(pina);
      _ok(await repo.setChatPinned(direct, true), 'pin');
      _ok(await repo.setChatPinned(direct, true), 'pin again (idempotent)');
      expect(await pinnedChats(), [direct]);
      final list = _ok(
        await SupabaseChatRepository(pina).conversations(),
        'list',
      );
      expect(list.firstWhere((c) => c.id == direct).pinned, isTrue);
      _ok(await repo.setChatPinned(direct, false), 'unpin');
      expect(await pinnedChats(), isEmpty);
    });

    test('the 6th chat is PinLimitFailure; an archived chat is '
        'DeniedFailure', () async {
      final repo = SupabaseChatPinRepository(pina);
      final groups = <String>[];
      for (var i = 0; i < 5; i++) {
        groups.add(
          _ok(
            await SupabaseChatRepository(pina).startGroupConversation(
              title: _stamp('pins $i'),
              memberIds: [pinb.auth.currentUser!.id],
            ),
            'group $i',
          ),
        );
      }
      for (final g in groups) {
        _ok(await repo.setChatPinned(g, true), 'pin $g');
      }
      expect(
        _err(await repo.setChatPinned(direct, true), 'the 6th pin'),
        isA<PinLimitFailure>(),
      );
      _ok(await repo.setChatPinned(groups.first, true), 're-pin at 5');
      _ok(await repo.setChatPinned(groups.first, false), 'unpin one');
      _ok(
        await SupabaseChatArchiveRepository(pina).setArchived(direct, true),
        'archive',
      );
      expect(
        _err(await repo.setChatPinned(direct, true), 'pin an archived chat'),
        isA<DeniedFailure>(),
      );
    });

    test('a pinned message is shared, has its line, and goes away with '
        'the message', () async {
      final repo = SupabaseChatPinRepository(pina);
      final msg = await say(_stamp('pin me'));
      _ok(await repo.setPinnedMessage(direct, msg.id), 'pin the message');
      expect(await pinnedMessageId(), msg.id);

      final seen = _ok(
        await SupabaseChatPinRepository(pinb).pinnedMessage(direct, msg.id),
        'pinb fetches it',
      );
      expect(seen?.id, msg.id);
      expect(seen?.body, msg.body);
      final events = _ok(
        await SupabaseChatPinRepository(pinb).pinEvents(direct),
        'pinb reads the lines',
      );
      expect(
        events.where(
          (e) => e.kind == GroupEventKind.pinned && e.actorId == pinaId,
        ),
        isNotEmpty,
      );

      await pina.rpc('delete_message', params: {'message': msg.id});
      expect(await pinnedMessageId(), isNull, reason: 'the pin outlived it');
      expect(
        _ok(await repo.pinnedMessage(direct, msg.id), 'fetch deleted'),
        isNull,
      );
    });

    test('who may pin cannot be switched in a 1:1', () async {
      expect(
        _err(
          await SupabaseChatPinRepository(pina).setMembersCanPin(direct, false),
          'switch a 1:1',
        ),
        isA<DeniedFailure>(),
      );
    });
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<void> until(
    WidgetTester t,
    Future<bool> Function() ok,
    String what,
  ) async {
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      if ((await t.runAsync(ok))!) return;
    }
    fail('never happened: $what');
  }

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(
        const RuntimeConfig(
          supabaseUrl: _url,
          supabasePublishableKey: _key,
          googleWebClientId: 'c',
        ),
      ),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(
          session: true,
          member: Member(userId: pinaId, displayName: 'Pina'),
        ),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(pina)),
      presenceRepositoryProvider.overrideWithValue(
        SupabasePresenceRepository(pina),
      ),
      profileRepositoryProvider.overrideWithValue(
        SupabaseProfileRepository(pina),
      ),
      notificationSettingsRepositoryProvider.overrideWithValue(
        SupabaseNotificationSettingsRepository(pina),
      ),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      notificationExplainerStoreProvider.overrideWithValue(
        NotificationExplainerStoreFake(shown: true),
      ),
      chatArchiveRepositoryProvider.overrideWithValue(
        SupabaseChatArchiveRepository(pina),
      ),
      chatPinRepositoryProvider.overrideWithValue(
        SupabaseChatPinRepository(pina),
      ),
      chatDeleteRepositoryProvider.overrideWithValue(
        SupabaseChatDeleteRepository(pina),
      ),
    ],
    child: const SisApp(),
  );

  testWidgets('pinning a chat and a message through the UI writes both, '
      'and a fresh read says pinned', (t) async {
    final msg = (await t.runAsync(() => say(_stamp('pin from the UI'))))!;
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app());
    final row = byKey('conversation-$direct');
    await until(t, () async => row.evaluate().isNotEmpty, 'the chat row');

    // Long-press selects the row; the selection bar pins it.
    await t.longPress(row);
    await t.pumpAndSettle();
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    await until(
      t,
      () async => (await pinnedChats()).contains(direct),
      'chat_pins row for the chat',
    );
    final list = _ok(
      (await t.runAsync(() => SupabaseChatRepository(pina).conversations()))!,
      'list',
    );
    expect(list.firstWhere((c) => c.id == direct).pinned, isTrue);
    expect(byKey('pinned-$direct'), findsOneWidget);

    // Pinning ends the selection here (the real reload rebuilds the list);
    // leave it if it is still on, so the tap below opens the chat.
    if (byKey('selection-back').evaluate().isNotEmpty) {
      await t.tap(byKey('selection-back'));
      await t.pumpAndSettle();
    }
    await t.tap(row);
    final bubble = byKey('message-${msg.id}');
    await until(t, () async => bubble.evaluate().isNotEmpty, 'the message');
    await t.pumpAndSettle();
    await t.longPress(bubble);
    await t.pumpAndSettle();
    await t.tap(byKey('menu-pin'));
    await t.pumpAndSettle();
    await until(
      t,
      () async => await pinnedMessageId() == msg.id,
      'conversations.pinned_message_id',
    );
    expect(byKey('pinned-bar'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
