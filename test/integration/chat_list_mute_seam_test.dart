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
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/supabase_notification_settings_repository.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/sis_ui.dart' as ui;

/// The chat list's long-press mute (Update 1 slice 4) wired as main.dart
/// wires it: SisApp over the REAL SupabaseChatRepository and the REAL
/// SupabaseNotificationSettingsRepository, driven through the card, checked
/// against the table with an independent read, and remounted from nothing to
/// prove the bell comes from the server, not from widget state.
///
/// The widget tests prove the row over a fake repository; they cannot prove
/// that the card's pick reaches notification_mutes as a conversation mute,
/// nor that the bell a fresh mount shows is the one the server holds.
///
/// Requires a running local Supabase. Reuses cleo and ann (as
/// notification_settings_seam_test.dart does); cleo's mutes are cleared
/// before and after. Run with --concurrency=1 like the rest of the suite.
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

void main() {
  // Real timers: the real Realtime channel's own timers never settle under
  // the fake clock (see notification_settings_seam_test.dart).
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient cleo;
  late SupabaseClient ann;
  late String convId;

  Future<void> clearMutes() => cleo
      .from('notification_mutes')
      .delete()
      .eq('user_id', cleo.auth.currentUser!.id);

  setUpAll(() async {
    cleo = await _signedIn('cleo@integration.test');
    ann = await _signedIn('ann@integration.test');
    await cleo
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', cleo.auth.currentUser!.id);
    convId = _ok(
      await SupabaseChatRepository(cleo)
          .startDirectConversation(ann.auth.currentUser!.id),
      'start the cleo-ann chat',
    );
    // A chat with a message, as a real one has (the time the bell sits
    // under), cleo's own so nothing is unread: the empty-chat and the
    // muted-with-unread rows are widget tests.
    _ok(
      await SupabaseChatRepository(
        cleo,
      ).send(id: randomMessageId(), conversationId: convId, body: 'mute seam'),
      'cleo writes',
    );
    _ok(await SupabaseChatRepository(cleo).markRead(convId), 'cleo reads');
    await clearMutes();
  });

  setUp(() async => clearMutes());

  tearDownAll(() async {
    await clearMutes();
    await cleo.dispose();
    await ann.dispose();
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder row() => byKey('conversation-$convId');
  Finder bell() => byKey('muted-$convId');

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      if (ok()) return;
    }
    fail('never happened: $what');
  }

  Future<void> frames(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Widget app(SupabaseClient notifClient) => ProviderScope(
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
          member: Member(userId: cleo.auth.currentUser!.id, displayName: 'C'),
        ),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(cleo)),
      presenceRepositoryProvider.overrideWithValue(
        SupabasePresenceRepository(cleo),
      ),
      profileRepositoryProvider.overrideWithValue(
        SupabaseProfileRepository(cleo),
      ),
      notificationSettingsRepositoryProvider.overrideWithValue(
        SupabaseNotificationSettingsRepository(notifClient),
      ),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      notificationExplainerStoreProvider.overrideWithValue(
        NotificationExplainerStoreFake(shown: true),
      ),
    ],
    child: const SisApp(),
  );

  /// A fresh mount from nothing: whatever it shows came from the server.
  Future<void> mount(WidgetTester t, [SupabaseClient? notif]) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(notif ?? cleo));
    await until(t, () => row().evaluate().isNotEmpty, 'the chat row');
    await frames(t);
  }

  Future<void> unmount(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => cleo.removeAllChannels());
  }

  Future<void> openMuteOptions(WidgetTester t) async {
    await t.longPress(row());
    await frames(t);
    expect(byKey('chat-menu'), findsOneWidget);
    if (byKey('chat-mute-off').evaluate().isEmpty &&
        byKey('chat-mute-oneHour').evaluate().isEmpty) {
      await t.tap(byKey('chat-menu-mute'));
      await frames(t);
    }
  }

  Future<List<Mute>> serverMutes() async => _ok(
    await SupabaseNotificationSettingsRepository(cleo).mutes(),
    'read mutes',
  ).where((m) => m.activeAt(DateTime.now())).toList();

  testWidgets(
    'mute from the card reaches the table, the bell survives a remount; '
    'unmute removes it from the table and the screen',
    (t) async {
      await mount(t);
      expect(bell(), findsNothing, reason: 'fixture: not muted');

      await openMuteOptions(t);
      await t.tap(byKey('chat-mute-oneDay'));
      await until(t, () => bell().evaluate().isNotEmpty, 'the bell');

      final saved = await t.runAsync(serverMutes);
      final mine = saved!.where(
        (m) => m.kind == MuteKind.conversation && m.target == convId,
      );
      expect(mine, hasLength(1), reason: 'not saved as a conversation mute');
      expect(
        mine.single.until!
            .difference(DateTime.now().add(const Duration(days: 1)))
            .abs(),
        lessThan(const Duration(minutes: 2)),
      );

      await unmount(t);
      await mount(t);
      expect(bell(), findsOneWidget, reason: 'the bell did not survive');

      await openMuteOptions(t);
      await t.tap(byKey('chat-mute-off'));
      await until(t, () => bell().evaluate().isEmpty, 'the bell gone');
      final after = await t.runAsync(serverMutes);
      expect(
        after!.where((m) => m.target == convId),
        isEmpty,
        reason: 'the unmute did not reach the table',
      );

      await unmount(t);
      await mount(t);
      expect(bell(), findsNothing, reason: 'the bell came back');
      await unmount(t);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  testWidgets(
    'the mutes connection down: the pick shows a notice, no bell, nothing '
    'saved',
    (t) async {
      final dead = (await t.runAsync(() => deadButSignedIn(cleo)))!;
      addTearDown(dead.dispose);
      await mount(t, dead);

      await openMuteOptions(t);
      await t.tap(byKey('chat-mute-oneHour'));
      await until(t, () => ui.notice.evaluate().isNotEmpty, 'a notice');
      expect(bell(), findsNothing);
      expect(await t.runAsync(serverMutes), isEmpty);
      await unmount(t);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
