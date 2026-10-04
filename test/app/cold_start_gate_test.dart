// Cold start from the stored state, as main.dart mounts it (SisApp, the real
// session controller, gate and route observer), with fakes only at the
// repository and store boundaries -- and every network fake held, so a screen
// that waits for the network cannot pass by accident.
//
// B1 (security design 2026-10-04): when the answer is Denied or the session
// ends, every page above the first is removed without a transition: one 1 ms
// pump later no chat is on screen, not even sliding out.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/join_chat.dart';
import '../support/last_session_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const bob = Conversation(id: 'c1', lastMessage: 'where are you');
const noticeText = "Can't reach SIS. Showing your saved chats; trying again.";
final notice = find.byKey(const ValueKey('offline-notice'));
final noticeTexts = find.text(noticeText);
// The two strips 0.30.16 had, one per cause; neither may come back.
final oldNotices = [
  find.byKey(const ValueKey('session-check-notice')),
  find.byKey(const ValueKey('chat-list-stale-notice')),
];
final row = find.byKey(const ValueKey('conversation-c1'));
final home = find.byType(HomeScreen);
final deniedText = find.textContaining('not currently approved');
final signIn = find.text('Continue with Google');

class World {
  World({
    MemoryLastSessionStore? markerStore,
    this.launchChat,
    bool holdProfile = true,
  }) : auth = ColdAuth(),
       markers = markerStore ?? MemoryLastSessionStore(marker()),
       snapshot = MemorySnapshotStore(owner: 'u1', list: const [bob]),
       chat = JoinChat()
         ..conversationsResult = const Ok([bob])
         ..holdJoin()
         ..holdList(),
       profile = ProfileFake(
         profile: const OwnProfile(
           userId: 'u1',
           displayName: 'Maya',
           tag: 'maya',
           onboardingDone: true,
         ),
       ) {
    if (holdProfile) profile.holdLoad();
  }
  final ColdAuth auth;
  final MemoryLastSessionStore markers;
  final MemorySnapshotStore snapshot;
  final JoinChat chat;
  final ProfileFake profile;
  final String? launchChat;
  final cache = AttachmentCacheFake();

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(auth),
      lastSessionStoreProvider.overrideWithValue(markers),
      chatListSnapshotStoreProvider.overrideWithValue(snapshot),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      profileRepositoryProvider.overrideWithValue(profile),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(
        PushSourceFake()..launchConversationId = launchChat,
      ),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      notificationExplainerStoreProvider.overrideWithValue(
        NotificationExplainerStoreFake(shown: true),
      ),
      attachmentCacheProvider.overrideWithValue(cache),
    ],
    child: const SisApp(),
  );
}

/// Turns of the event loop with no time passing: whatever shows here did not
/// wait for any timer, animation or network answer.
Future<void> turns(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(Duration.zero);
  }
}

/// Frames with time passing, without settling (a SIS wait pulses forever).
Future<void> frames(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('the stored chat list shows with every network call still '
      'unanswered and no profile read made', (t) async {
    final w = World();
    await t.pumpWidget(w.app());
    await turns(t);

    expect(home, findsOneWidget, reason: 'home waited for the network');
    expect(row, findsOneWidget, reason: 'the stored list is not on screen');
    expect(w.auth.checks.single.answered, isFalse);
    expect(w.auth.memberReads, 0);
    expect(notice, findsNothing);
  });

  testWidgets('control: without a marker the same start waits for the '
      'server (the gated path)', (t) async {
    final w = World(markerStore: MemoryLastSessionStore());
    await t.pumpWidget(w.app());
    await frames(t);
    expect(home, findsNothing);
    expect(row, findsNothing);
  });

  group('B1: Denied after the list is shown removes every page at once', () {
    Future<void> deniedWithChatOpen(WidgetTester t, World w) async {
      expect(find.byType(MessageScreen), findsOneWidget);
      // A dialog or sheet over the chat, as the message menu opens one.
      final nav = Navigator.of(t.element(find.byType(MessageScreen)));
      nav.push(
        DialogRoute<void>(
          context: t.element(find.byType(MessageScreen)),
          builder: (_) => const Text('a dialog over the chat'),
        ),
      );
      await frames(t);
      expect(find.text('a dialog over the chat'), findsOneWidget);

      w.auth.last.deny();
      await t.pump(const Duration(milliseconds: 1));

      expect(deniedText, findsOneWidget, reason: 'Denied is not on screen');
      expect(find.byType(MessageScreen), findsNothing, reason: 'chat stayed');
      expect(find.text('a dialog over the chat'), findsNothing);
      expect(row, findsNothing, reason: 'the list stayed visible');
      await frames(t);
      expect(w.markers.stored, isNull);
      expect(w.snapshot.list, isNull, reason: 'the stored list survived');
      expect(w.cache.clears, greaterThanOrEqualTo(1));
    }

    testWidgets('a chat opened from the list', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await turns(t);
      await t.tap(row);
      await frames(t);
      await deniedWithChatOpen(t, w);
    });

    testWidgets('a chat opened by the notification that launched the app', (
      t,
    ) async {
      final w = World(launchChat: 'c1');
      await t.pumpWidget(w.app());
      await frames(t);
      await deniedWithChatOpen(t, w);
    });

    testWidgets('the session ending (expired, signed out elsewhere) with a '
        'chat open shows sign-in and no chat', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.allow();
      await frames(t);
      await t.tap(row);
      await frames(t);
      expect(find.byType(MessageScreen), findsOneWidget);

      w.auth.endSession();
      await t.pump(const Duration(milliseconds: 1));
      expect(signIn, findsOneWidget);
      expect(find.byType(MessageScreen), findsNothing);
      await frames(t);
      expect(w.markers.stored, isNull);
    });
  });

  group('offline start', () {
    testWidgets('the check failing keeps the list and shows the notice at the '
        'top of Home; coming back to the app asks again at once; the allow '
        'removes the notice', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.fail();
      await turns(t);

      expect(notice, findsOneWidget);
      expect(
        find.descendant(of: notice, matching: find.text(noticeText)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: home, matching: notice),
        findsOneWidget,
        reason: 'the notice is not on Home',
      );
      expect(
        t.getTopLeft(notice).dy,
        lessThan(t.getTopLeft(row).dy),
        reason: 'the notice is not above the list',
      );
      expect(row, findsOneWidget);
      expect(w.auth.checks, hasLength(1));

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await turns(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await turns(t);
      expect(w.auth.checks, hasLength(2), reason: 'resume did not recheck');

      w.auth.last.allow();
      await frames(t);
      expect(notice, findsNothing);
      expect(row, findsOneWidget);
    });
  });

  group('one offline notice, whichever cause', () {
    ProviderContainer box(WidgetTester t) =>
        ProviderScope.containerOf(t.element(home));

    /// Exactly one strip, with its one text, at the top of Home above the
    /// stored list, and no strip of the old kinds.
    void oneNotice(WidgetTester t, String why) {
      expect(notice, findsOneWidget, reason: why);
      expect(noticeTexts, findsOneWidget, reason: '$why: the text twice');
      expect(
        find.descendant(of: notice, matching: noticeTexts),
        findsOneWidget,
      );
      expect(find.descendant(of: home, matching: notice), findsOneWidget);
      expect(t.getTopLeft(notice).dy, lessThan(t.getTopLeft(row).dy));
      for (final old in oldNotices) {
        expect(old, findsNothing, reason: '$why: an old strip is back');
      }
      expect(row, findsOneWidget, reason: '$why: the stored list went away');
    }

    void noNotice(String why) {
      expect(notice, findsNothing, reason: why);
      expect(noticeTexts, findsNothing, reason: why);
      for (final old in oldNotices) {
        expect(old, findsNothing, reason: why);
      }
    }

    /// A World whose held list read answers offline when released (the
    /// fake answers with what the server held when the read was made).
    World offlineList() => World()
      ..chat.conversationsResult = const Err(
        NetworkFailure('offline', retryable: true),
      );

    Future<void> listFails(WidgetTester t, World w) async {
      w.chat.releaseList();
      await turns(t);
    }

    testWidgets('only the list read failing (the check still in flight): '
        'one notice', (t) async {
      final w = offlineList();
      await t.pumpWidget(w.app());
      await turns(t);
      await listFails(t, w);

      expect(w.auth.checks.single.answered, isFalse, reason: 'fixture');
      expect(box(t).read(conversationListStaleProvider), isTrue);
      expect(box(t).read(sessionCheckFailedProvider), isFalse);
      oneNotice(t, 'list stale only');
    });

    testWidgets('only the session check failing (the list read still in '
        'flight): one notice', (t) async {
      final w = World();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.fail();
      await turns(t);

      expect(box(t).read(sessionCheckFailedProvider), isTrue);
      expect(box(t).read(conversationListStaleProvider), isFalse);
      oneNotice(t, 'session check only');
    });

    testWidgets('both failing: still one notice; it stays while either is '
        'failing and goes once both have succeeded', (t) async {
      final w = offlineList();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.fail();
      await turns(t);
      await listFails(t, w);
      expect(box(t).read(sessionCheckFailedProvider), isTrue);
      expect(box(t).read(conversationListStaleProvider), isTrue);
      oneNotice(t, 'both');

      // The server check comes back first; the list is still the saved one.
      box(t).read(sessionControllerProvider.notifier).recheck();
      await turns(t);
      w.auth.last.allow();
      await frames(t);
      expect(box(t).read(sessionCheckFailedProvider), isFalse);
      oneNotice(t, 'the list still stale');

      // Then the list reads again.
      w.chat.conversationsResult = const Ok([bob]);
      unawaited(box(t).read(conversationListProvider.notifier).reloadQuietly());
      await frames(t);
      expect(box(t).read(conversationListStaleProvider), isFalse);
      noNotice('both succeeded');
      expect(row, findsOneWidget);
    });

    testWidgets('the list back first, the check still failing: the notice '
        'stays until the check succeeds', (t) async {
      final w = offlineList();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.fail();
      await turns(t);
      await listFails(t, w);
      oneNotice(t, 'both');

      w.chat.conversationsResult = const Ok([bob]);
      unawaited(box(t).read(conversationListProvider.notifier).reloadQuietly());
      await frames(t);
      expect(box(t).read(conversationListStaleProvider), isFalse);
      oneNotice(t, 'the check still failing');

      box(t).read(sessionControllerProvider.notifier).recheck();
      await turns(t);
      w.auth.last.allow();
      await frames(t);
      noNotice('both succeeded');
    });

    testWidgets('control: the check and the list both succeed: no notice', (
      t,
    ) async {
      final w = World();
      await t.pumpWidget(w.app());
      await turns(t);
      w.auth.last.allow();
      w.chat.releaseList();
      await frames(t);
      expect(box(t).read(conversationListProvider).hasValue, isTrue);
      noNotice('all fine');
      expect(row, findsOneWidget);
    });
  });

  group('Home while the profile loads, from the onboarded marker', () {
    testWidgets('the profile read failing still shows Home with the list', (
      t,
    ) async {
      final w = World(holdProfile: false);
      w.profile.loadResult = const Err(NetworkFailure('offline'));
      await t.pumpWidget(w.app());
      await frames(t);
      expect(home, findsOneWidget, reason: 'an error/loader replaced Home');
      expect(row, findsOneWidget);
    });

    testWidgets('control: confirmed on the gated path (no onboarded marker), '
        'a held profile read keeps Home back as before', (t) async {
      final w = World(markerStore: MemoryLastSessionStore())
        ..auth.autoAllow = true;
      await t.pumpWidget(w.app());
      await frames(t);
      expect(home, findsNothing);
    });
  });
}
