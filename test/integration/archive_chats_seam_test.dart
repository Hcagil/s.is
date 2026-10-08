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
import 'package:sis/features/chat/data/supabase_chat_archive_repository.dart';
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
import '../support/video_fakes.dart';

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
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient cleo;
  late SupabaseClient ann;
  late String convId;

  // Each test starts from an unarchived chat.
  Future<void> clearArchives() =>
      cleo.from('chat_archives').delete().eq('conversation_id', convId);

  setUpAll(() async {
    cleo = await _signedIn('cleo@integration.test');
    ann = await _signedIn('ann@integration.test');
    await cleo
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', cleo.auth.currentUser!.id);
    await findByTag(cleo, [ann]);
    convId = _ok(
      await SupabaseChatRepository(cleo)
          .startDirectConversation(ann.auth.currentUser!.id),
      'start the cleo-ann chat',
    );
    _ok(
      await SupabaseChatRepository(cleo).send(
        id: randomMessageId(),
        conversationId: convId,
        body: 'archive seam',
      ),
      'cleo writes',
    );
    _ok(await SupabaseChatRepository(cleo).markRead(convId), 'cleo reads');
    await clearArchives();
  });

  setUp(() async => clearArchives());

  tearDownAll(() async {
    await clearArchives();
    await cleo.dispose();
    await ann.dispose();
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));
  Finder row() => byKey('conversation-$convId');

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
      ...videoOverrides(),
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
      chatArchiveRepositoryProvider.overrideWithValue(
        SupabaseChatArchiveRepository(cleo),
      ),
    ],
    child: const SisApp(),
  );

  Future<void> mount(WidgetTester t, [SupabaseClient? notif]) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(notif ?? cleo));
    await until(t, () => row().evaluate().isNotEmpty, 'the chat row');
    await frames(t);
  }

  Future<void> swipeLeft(WidgetTester t, Finder finder) async {
    final g = await t.startGesture(t.getCenter(finder));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(-20, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
  }

  Future<void> waitForArchiveRow(
    WidgetTester t,
    int expectedCount,
    String what,
  ) async {
    for (var i = 0; i < 100; i++) {
      final rows = await t.runAsync(
        () => cleo
            .from('chat_archives')
            .select('conversation_id')
            .eq('conversation_id', convId),
      );
      final count = rows!.length;
      if (count == expectedCount) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail('never happened: $what');
  }

  testWidgets(
    'archiving through the UI writes chat_archives and a fresh read says archived',
    (t) async {
      await mount(t);

      await swipeLeft(t, byKey('archive-swipe-$convId'));

      await waitForArchiveRow(
        t,
        1,
        'archive row should appear in chat_archives table',
      );

      final convs = _ok(
        (await t.runAsync(() => SupabaseChatRepository(cleo).conversations()))!,
        'conversations',
      );
      final conv = convs.firstWhere((c) => c.id == convId);
      expect(conv.archived, isTrue);

      expect(row(), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  testWidgets('unarchiving on the Archived page deletes the row', (t) async {
    await mount(t);

    await swipeLeft(t, byKey('archive-swipe-$convId'));

    await waitForArchiveRow(
      t,
      1,
      'archive row should appear in chat_archives table',
    );

    // Reveal the archived section
    await t.drag(
      find.byKey(const ValueKey('conversation-list')),
      const Offset(0, 120),
    );
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('archived-chats-row')));
    await t.pumpAndSettle();

    await until(
      t,
      () => find.byKey(ValueKey('archived-tile-$convId')).evaluate().isNotEmpty,
      'archived tile appears',
    );

    await swipeLeft(t, byKey('archive-swipe-$convId'));

    await waitForArchiveRow(
      t,
      0,
      'archive row should be removed from chat_archives table',
    );

    final convs = _ok(
      (await t.runAsync(() => SupabaseChatRepository(cleo).conversations()))!,
      'conversations',
    );
    final conv = convs.firstWhere((c) => c.id == convId);
    expect(conv.archived, isFalse);

    // Back on the main list, the chat is there again.
    await t.pageBack();
    await t.pumpAndSettle();
    expect(row(), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
