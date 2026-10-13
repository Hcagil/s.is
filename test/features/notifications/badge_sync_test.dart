// The app-icon badge (0.30.8), written from badge_controller.dart's public
// contract:
//  * appBadgeProvider defaults to a no-op;
//  * badgeSyncProvider, while listened to, re-reads unreadTotal() when the
//    chat list's unread numbers change and sets the badge to it once, after a
//    debounce of about 800 ms -- a burst of changes is one read;
//  * with no user id, SignedOut or Denied sets 0 once and reads nothing;
//    a restoring session, SessionLoading, SessionError and SetupRequired set
//    nothing; a failed read sets nothing;
//  * the function it returns schedules a read, and the app calls it on every
//    return to the screen (onShow).
//
// The list side is the real conversationListProvider over ChatFake, whose
// deliver() moves unread the way a Realtime insert does.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/badge_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

/// The icon, as the platform would hold it: every number set, in order.
class BadgeFake implements AppBadge {
  final sets = <int>[];
  @override
  Future<void> set(int count) async => sets.add(count);
}

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _SignedOut extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

class _Fixed extends SessionController {
  _Fixed(this.given);
  final SessionState? given; // null: still restoring, never answers
  @override
  Future<SessionState> build() =>
      given == null ? Completer<SessionState>().future : Future.value(given);
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('appBadgeProvider defaults to a no-op that completes', () async {
    final c = ProviderContainer.test();
    await expectLater(c.read(appBadgeProvider).set(3), completes);
    await expectLater(c.read(appBadgeProvider).set(0), completes);
  });

  group('badgeSyncProvider over the real chat list', () {
    late ChatFake chat;
    late BadgeFake badge;

    Future<ProviderContainer> mount({
      bool signedIn = true,
      bool settledFirst = true,
    }) async {
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          appBadgeProvider.overrideWithValue(badge),
          sessionControllerProvider.overrideWith(
            signedIn ? _SignedIn.new : _SignedOut.new,
          ),
        ],
      );
      // The session has answered (a resumed app); the cold start where it
      // has not yet is its own test below.
      if (settledFirst) {
        c.listen(currentUserIdProvider, (_, _) {});
        await c.read(sessionControllerProvider.future);
        await wait(10);
      }
      // Mounted as SisApp mounts both: the list is shown, the sync listened.
      c.listen(conversationListProvider, (_, _) {});
      c.listen(badgeSyncProvider, (_, _) {});
      return c;
    }

    int reads() => chat.calls.where((x) => x == 'unreadTotal').length;

    setUp(() {
      chat = ChatFake(self: me.userId, latency: const Duration(milliseconds: 2))
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Crew', unread: 2),
          Conversation(id: 'c2', title: 'Work', unread: 3),
        ]);
      badge = BadgeFake();
    });

    test(
      'debounced: nothing at 300 ms, the total exactly once by 1.6 s',
      () async {
        chat.unreadTotalResult = const Ok(
          7,
        ); // the server's number, not the list's
        await mount();
        await wait(300);
        expect(badge.sets, isEmpty, reason: 'still inside the debounce');
        await wait(1300);
        expect(badge.sets, [7]);
        expect(reads(), 1);
      },
    );

    test('a burst of arrivals is one read and one set', () async {
      await mount();
      await wait(1600);
      expect(badge.sets, [5]);

      for (var i = 0; i < 3; i++) {
        chat.deliver(
          Message(
            id: 'n$i',
            conversationId: 'c1',
            senderId: 'u2',
            body: 'hey $i',
            createdAt: DateTime.now(),
          ),
        );
        await wait(50);
      }
      await wait(1600);
      expect(badge.sets, [5, 8], reason: 'one set for the whole burst');
      expect(reads(), 2);
    });

    test('signed out: the badge is cleared and nothing is read', () async {
      await mount(signedIn: false);
      await wait(1600);
      expect(badge.sets, [0]);
      expect(reads(), 0);
    });

    Future<void> mountWith(SessionState? state) async {
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          appBadgeProvider.overrideWithValue(badge),
          sessionControllerProvider.overrideWith(() => _Fixed(state)),
        ],
      );
      c.listen(currentUserIdProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
      c.listen(badgeSyncProvider, (_, _) {});
    }

    test(
      'Denied (not on the allowlist): cleared to 0 once, nothing read',
      () async {
        await mountWith(const Denied());
        await wait(1600);
        expect(badge.sets, [0]);
        expect(reads(), 0);
      },
    );

    for (final (name, state) in <(String, SessionState?)>[
      ('still restoring (no answer yet)', null),
      ('SessionLoading', const SessionLoading()),
      ('SessionError', const SessionError('boom')),
      ('SetupRequired', const SetupRequired()),
    ]) {
      test('$name: the badge is left as it was', () async {
        await mountWith(state);
        await wait(1600);
        expect(badge.sets, isEmpty);
      });
    }

    test('a failed read leaves the badge as it was', () async {
      chat.unreadTotalResult = const Err(NetworkFailure('offline'));
      await mount();
      await wait(1600);
      expect(reads(), 1);
      expect(badge.sets, isEmpty);
    });

    test('a cold start that cannot read the total leaves the badge as the '
        'last push set it', () async {
      // Signed in, but the session is still being restored when the sync
      // starts; then the read fails (offline). The member is not signed
      // out at any point, so nothing may clear the number.
      chat.unreadTotalResult = const Err(NetworkFailure('offline'));
      await mount(settledFirst: false);
      await wait(1600);
      expect(reads(), 1);
      expect(badge.sets, isEmpty);
    });

    test('the returned function schedules a read', () async {
      final c = await mount();
      await wait(1600);
      expect(reads(), 1);

      chat.unreadTotalResult = const Ok(9); // read on another device
      c.read(badgeSyncProvider)();
      await wait(1600);
      expect(reads(), 2);
      expect(badge.sets, [5, 9]);
    });
  });

  testWidgets('returning to the app (onShow) re-reads the badge', (t) async {
    final chat = FakeChat(
      list: [const Conversation(id: 'c1', title: 'Crew', unread: 1)],
    );
    final badge = BadgeFake();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: 'https://x.supabase.co',
              supabasePublishableKey: 'k',
              googleWebClientId: 'c',
            ),
          ),
          authRepositoryProvider.overrideWithValue(
            FakeAuth(session: true, member: me),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          profileRepositoryProvider.overrideWithValue(
            ProfileFake(
              profile: const OwnProfile(
                userId: 'u1',
                displayName: 'Maya',
                tag: 'maya',
                onboardingDone: true,
              ),
            ),
          ),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          appBadgeProvider.overrideWithValue(badge),
        ],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    final before = chat.unreadTotalReads;
    expect(badge.sets, [1], reason: 'mounted by the app, it set the badge');

    chat.unreadTotalResult = const Ok(4);
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
      await t.pump();
    }
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();

    expect(chat.unreadTotalReads, before + 1);
    expect(badge.sets.last, 4);
  });
}
