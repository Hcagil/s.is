// Opening the app (v0.21.4, docs/DECISIONS.md 2026-09-28 "The app opens
// faster"), from the contract: once the session is Allowed, the member's own
// profile and the chat list are both asked for at once -- neither waits for
// the other -- and which screen the gate shows (onboarding, the notification
// explainer, or Home) depends on the profile and the explainer flag only,
// never on how the list is doing.
//
// Mounted as main.dart mounts it: SisApp behind its session gate, fakes only
// at the repository boundaries. The profile read and the list read are held
// open by the test, and the list's Realtime join can take forever (JoinChat).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/notifications/presentation/notification_explainer_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/onboarding_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/join_chat.dart';
import '../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const me = Member(userId: 'u1', displayName: 'Maya');

const onboarded = OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
);

const newcomer = OwnProfile(
  userId: 'u1',
  displayName: 'Maya Google',
  tag: 'maya_google',
  onboardingDone: false,
);

final onboarding = find.byType(OnboardingScreen);
final explainer = find.byType(NotificationExplainerScreen);
final home = find.byType(HomeScreen);

Widget app({
  required JoinChat chat,
  required ProfileFake profile,
  bool explainerShown = true,
}) => ProviderScope(
  overrides: [
    ...videoOverrides(),
    runtimeConfigProvider.overrideWithValue(config),
    authRepositoryProvider.overrideWithValue(
      FakeAuth(session: true, member: me),
    ),
    updateRepositoryProvider.overrideWithValue(FakeUpdate()),
    chatRepositoryProvider.overrideWithValue(chat),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    profileRepositoryProvider.overrideWithValue(profile),
    linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
    pushSourceProvider.overrideWithValue(
      PushSourceFake(status: PushPermissionStatus.notDetermined),
    ),
    pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    notificationExplainerStoreProvider.overrideWithValue(
      NotificationExplainerStoreFake(shown: explainerShown),
    ),
    attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
  ],
  child: const SisApp(),
);

/// Frames without settling: a SIS wait pulses forever.
Future<void> frames(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

const bob = Conversation(id: 'c1', lastMessage: 'where are you');

void main() {
  testWidgets('once Allowed, the profile and the chat list are both asked '
      'for before either answers', (t) async {
    final profile = ProfileFake(profile: onboarded)..holdLoad();
    final chat = JoinChat()
      ..conversationsResult = const Ok([bob])
      ..holdJoin()
      ..holdList();
    await t.pumpWidget(app(chat: chat, profile: profile));
    await frames(t);

    expect(profile.calls, contains('load'));
    expect(
      chat.calls,
      contains('conversations'),
      reason: 'the list waited for the profile',
    );
    expect(chat.calls, contains('incomingAll'));
    expect(home, findsNothing, reason: 'home before the profile answered');

    // Either may answer first; here the list, while the profile is out.
    chat.releaseList();
    await frames(t);
    expect(home, findsNothing, reason: 'the list decided the screen');
    profile.releaseLoad();
    await frames(t);
    expect(home, findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    expect(
      chat.calls.where((c) => c == 'conversations'),
      hasLength(1),
      reason: 'home asked for the list a second time',
    );
  });

  testWidgets('the profile answering first shows home with the list '
      'still on its way, and the list fills in', (t) async {
    final profile = ProfileFake(profile: onboarded)..holdLoad();
    final chat = JoinChat()
      ..conversationsResult = const Ok([bob])
      ..holdList();
    await t.pumpWidget(app(chat: chat, profile: profile));
    await frames(t);
    expect(chat.calls, contains('conversations'));

    profile.releaseLoad();
    await frames(t);
    expect(home, findsOneWidget, reason: 'home waited for the list');
    expect(find.byKey(const ValueKey('conversation-c1')), findsNothing);

    chat.releaseList();
    await frames(t);
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
  });

  group(
    'the screen depends on the profile and the explainer, not the list',
    () {
      final lists = <String, JoinChat Function()>{
        'never answers': () => JoinChat()
          ..conversationsResult = const Ok([bob])
          ..holdJoin()
          ..holdList(),
        'fails': () => JoinChat()
          ..conversationsResult = const Err(NetworkFailure('no route to host'))
          ..incomingAllResult = const Err(NetworkFailure('realtime down')),
      };

      for (final MapEntry(key: how, value: makeChat) in lists.entries) {
        testWidgets('not onboarded, list $how: onboarding', (t) async {
          final chat = makeChat();
          await t.pumpWidget(
            app(
              chat: chat,
              profile: ProfileFake(profile: newcomer),
            ),
          );
          await frames(t);
          expect(onboarding, findsOneWidget);
          expect(explainer, findsNothing);
          expect(home, findsNothing);
          expect(
            chat.calls,
            contains('conversations'),
            reason: 'list not asked',
          );
        });

        testWidgets('onboarded, explainer not shown yet, list $how: the '
            'explainer', (t) async {
          final chat = makeChat();
          await t.pumpWidget(
            app(
              chat: chat,
              profile: ProfileFake(profile: onboarded),
              explainerShown: false,
            ),
          );
          await frames(t);
          expect(explainer, findsOneWidget);
          expect(onboarding, findsNothing);
          expect(home, findsNothing);
        });

        testWidgets('onboarded, explainer shown, list $how: home', (t) async {
          final chat = makeChat();
          await t.pumpWidget(
            app(
              chat: chat,
              profile: ProfileFake(profile: onboarded),
            ),
          );
          await frames(t);
          expect(home, findsOneWidget);
          expect(onboarding, findsNothing);
          expect(explainer, findsNothing);
        });
      }
    },
  );
}
