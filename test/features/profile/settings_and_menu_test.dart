// Settings and the way into it from home, mounted as production mounts
// them: the whole app behind the session gate, with fakes only at the repository boundary.
//
// This is where the rename dialog's coverage moved: a rename is sent, shows
// at once, and a refused one shows its reason.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/sis_ui.dart';
import '../../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const maya = OwnProfile(
  userId: 'u1',
  displayName: 'Maya Profile',
  tag: 'maya',
  onboardingDone: true,
);

Future<void> pumpApp(
  WidgetTester t,
  ProfileFake p, {
  FakeAuth? auth,
  PresenceFake? presence,
  ChatRepository? chat,
  PushRegistryFake? push,
  PushSourceFake? source,
  AttachmentCacheFake? photos,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          auth ?? FakeAuth(session: true),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(chat ?? FakeChat()),
        presenceRepositoryProvider.overrideWithValue(
          presence ?? PresenceFake(),
        ),
        profileRepositoryProvider.overrideWithValue(p),
        pushSourceProvider.overrideWithValue(source ?? PushSourceFake()),
        pushRegistryProvider.overrideWithValue(push ?? PushRegistryFake()),
        attachmentCacheProvider.overrideWithValue(
          photos ?? AttachmentCacheFake(),
        ),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

/// The home header's settings button: the only way into settings.
Future<void> openSettings(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('home-settings')));
  await t.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

Future<void> openSettingsPage(WidgetTester t, String row, String title) async {
  await openSettings(t);
  await t.tap(find.byKey(ValueKey(row)));
  await t.pumpAndSettle();
  expect(
    find.descendant(of: find.byType(AppBar), matching: find.text(title)),
    findsOneWidget,
    reason: '$row did not open "$title"',
  );
}

/// Settings > Profile: the name and tag form.
Future<void> openProfile(WidgetTester t) =>
    openSettingsPage(t, 'settings-profile', 'Profile');

/// Settings > Account > Sign out.
Future<void> signOut(WidgetTester t) async {
  await openSettingsPage(t, 'settings-account', 'Account');
  await t.tap(find.byKey(const ValueKey('account-sign-out')));
  await t.pumpAndSettle();
}

/// The settings profile card names the member by [name].
Finder cardWith(String name) => find.descendant(
  of: find.byKey(const ValueKey('settings-profile')),
  matching: find.text(name),
);

String fieldText(WidgetTester t, String key) => t
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Future<void> save(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 600)); // tag debounce
  await t.pumpAndSettle();
  await t.tap(find.byKey(const ValueKey('profile-submit')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('home offers settings, and no menu, sign-out or rename '
      'dialog', (t) async {
    await pumpApp(t, ProfileFake(profile: maya));

    final button = find.byKey(const ValueKey('home-settings'));
    expect(button, findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: button),
      findsOneWidget,
      reason: 'the settings button is not in the home header',
    );
    expect(find.byKey(const ValueKey('home-menu')), findsNothing);
    expect(find.byKey(const ValueKey('menu-sign-out')), findsNothing);
    expect(find.textContaining('Sign out'), findsNothing);
    expect(find.text('Change display name'), findsNothing);

    await openSettings(t);
    expect(
      cardWith('Maya Profile'),
      findsOneWidget,
      reason: 'settings must name the member by the profile',
    );
  });

  testWidgets('the profile page opens on the current name and tag', (t) async {
    await pumpApp(t, ProfileFake(profile: maya));
    await openProfile(t);

    expect(fieldText(t, 'profile-name'), 'Maya Profile');
    expect(fieldText(t, 'profile-tag'), 'maya');
  });

  testWidgets('a rename is saved, confirmed, and shows in settings at once', (
    t,
  ) async {
    final p = ProfileFake(profile: maya);
    await pumpApp(t, p);
    await openProfile(t);

    await t.enterText(find.byKey(const ValueKey('profile-name')), 'Maya R');
    await save(t);

    expect(find.text('Saved'), findsOneWidget);
    expect(p.saves.single.displayName, 'Maya R');
    expect(p.profile.displayName, 'Maya R');

    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      cardWith('Maya R'),
      findsOneWidget,
      reason: 'settings still shows the old name after a rename',
    );
    expect(cardWith('Maya Profile'), findsNothing);
    expect(
      p.calls.where((c) => c == 'load'),
      hasLength(1),
      reason: 'the new name should come from the save, not a re-read',
    );
    await t.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a new tag is checked, saved and confirmed', (t) async {
    final p = ProfileFake(profile: maya, takenByOthers: ['bob']);
    await pumpApp(t, p);
    await openProfile(t);

    await t.enterText(find.byKey(const ValueKey('profile-tag')), '@Maya_R');
    await save(t);

    expect(p.checks, ['maya_r']);
    expect(p.profile.tag, 'maya_r');
    expect(find.text('Saved'), findsOneWidget);

    await t.pageBack();
    await t.pumpAndSettle();
    expect(cardWith('@maya_r'), findsOneWidget, reason: 'old tag on the card');
    await t.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a refused save shows the reason, not "Saved", and keeps the '
      'typing', (t) async {
    final p = ProfileFake(profile: maya);
    await pumpApp(t, p);
    await openProfile(t);

    await t.enterText(find.byKey(const ValueKey('profile-name')), 'Maya R');
    await t.enterText(find.byKey(const ValueKey('profile-tag')), 'maya_r');
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpAndSettle();
    p.claimByOther('maya_r'); // taken between the check and the save
    await t.tap(find.byKey(const ValueKey('profile-submit')));
    await t.pumpAndSettle();

    expect(
      find.textContaining('That tag was just taken by someone.'),
      findsOneWidget,
      reason: 'a refused save failed silently',
    );
    expect(find.text('Saved'), findsNothing);
    expect(fieldText(t, 'profile-name'), 'Maya R');
    expect(fieldText(t, 'profile-tag'), 'maya_r');
    expect(p.profile.displayName, 'Maya Profile', reason: 'half-saved');
    await t.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a failed save shows the reason', (t) async {
    final p = ProfileFake(profile: maya)
      ..saveResult = const Err(NetworkFailure('no route to host'));
    await pumpApp(t, p);
    await openProfile(t);

    await t.enterText(find.byKey(const ValueKey('profile-name')), 'Maya R');
    await save(t);

    expect(find.textContaining('no route to host'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
    await t.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('sign-out signs out, and the next member sees their own name', (
    t,
  ) async {
    final auth = FakeAuth(session: true);
    final p = ProfileFake(profile: maya);
    final push = PushRegistryFake();
    final source = PushSourceFake();
    final photos = AttachmentCacheFake();
    bool? sessionActiveWhenForgotten;
    push.onForget = (_) => sessionActiveWhenForgotten = auth.session;
    int? signOutsWhenCleared;
    photos.onClear = () => signOutsWhenCleared = auth.signOuts;
    await pumpApp(t, p, auth: auth, push: push, source: source, photos: photos);

    await signOut(t);
    expect(auth.signOuts, 1);
    expect(
      source.clearAllCalls,
      1,
      reason:
          'the Sign out button must take every notification of this '
          'account out of the shade',
    );
    expect(
      sessionActiveWhenForgotten,
      isTrue,
      reason: 'forget() must run while the session still exists',
    );
    expect(
      push.forgotten,
      isNotEmpty,
      reason: 'the device was never forgotten',
    );
    expect(photos.clears, 1, reason: 'the attachment cache was never cleared');
    expect(
      signOutsWhenCleared,
      1,
      reason:
          'the cache must be cleared after signing out, so the next '
          'account on this phone does not inherit the last one\'s photos',
    );
    expect(find.text('Continue with Google'), findsOneWidget);

    // Someone else signs in on the same phone.
    p.profile = const OwnProfile(
      userId: 'u9',
      displayName: 'Noor',
      tag: 'noor',
      onboardingDone: true,
    );
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    await openSettings(t);

    expect(
      cardWith('Noor'),
      findsOneWidget,
      reason: 'the previous member\'s profile survived sign-out',
    );
    expect(find.textContaining('Maya Profile'), findsNothing);
  });

  group('sharing switches', () {
    bool switchOn(WidgetTester t, String key) =>
        switchedOn(t, find.byKey(ValueKey(key)));

    Future<void> flip(WidgetTester t, String key) async {
      await t.ensureVisible(find.byKey(ValueKey(key)));
      await t.tap(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
    }

    Future<void> openPrivacy(WidgetTester t) =>
        openSettingsPage(t, 'settings-privacy', 'Privacy');

    OwnProfile sharing({required bool presence, required bool typing}) =>
        OwnProfile(
          userId: maya.userId,
          displayName: maya.displayName,
          tag: maya.tag,
          onboardingDone: true,
          sharePresence: presence,
          shareTyping: typing,
        );

    testWidgets('the switches show what the profile holds', (t) async {
      await pumpApp(
        t,
        ProfileFake(profile: sharing(presence: false, typing: true)),
      );
      await openPrivacy(t);
      expect(switchOn(t, 'share-presence'), isFalse);
      expect(switchOn(t, 'share-typing'), isTrue);
    });

    testWidgets('turning online status off saves only that, and the app '
        'rejoins hidden', (t) async {
      final p = ProfileFake(profile: maya);
      final presence = PresenceFake();
      // A 1:1 on the list: its tile is what watches who is online.
      final chat = ChatFake()
        ..conversationsResult = const Ok([
          Conversation(
            id: 'c1',
            other: Member(userId: 'u2', displayName: 'Bob'),
          ),
        ]);
      await pumpApp(t, p, presence: presence, chat: chat);
      expect(presence.announcing, hasLength(1));
      await openPrivacy(t);

      await flip(t, 'share-presence');

      final s = p.saves.single;
      expect((s.sharePresence, s.shareTyping), (false, null));
      expect(s.displayName, isNull);
      expect(s.tag, isNull);
      expect(p.profile.sharePresence, isFalse);
      expect(switchOn(t, 'share-presence'), isFalse);
      expect(
        presence.announcing,
        isEmpty,
        reason: 'the member still announced after opting out',
      );

      // Home rejoins, hidden, once it is on screen again.
      await t.pageBack();
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(find.text('New chat'), findsOneWidget);
      expect(presence.calls.last, 'online:hidden');
      expect(presence.live, hasLength(1));
      expect(presence.announcing, isEmpty);
    });

    testWidgets('turning typing off saves only that', (t) async {
      final p = ProfileFake(profile: maya);
      await pumpApp(t, p);
      await openPrivacy(t);

      await flip(t, 'share-typing');

      final s = p.saves.single;
      expect((s.sharePresence, s.shareTyping), (null, false));
      expect(p.profile.shareTyping, isFalse);
      expect(switchOn(t, 'share-typing'), isFalse);
    });

    testWidgets('a refused change keeps the stored value and says why', (
      t,
    ) async {
      final p = ProfileFake(profile: maya)
        ..saveResult = const Err(NetworkFailure('the network is unreachable'));
      await pumpApp(t, p);
      await openPrivacy(t);

      await flip(t, 'share-presence');

      expect(p.saves, hasLength(1));
      expect(switchOn(t, 'share-presence'), isTrue);
      expect(find.textContaining('the network is unreachable'), findsWidgets);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('turning read status off saves only that', (t) async {
      final p = ProfileFake(profile: maya);
      await pumpApp(t, p);
      await openPrivacy(t);

      expect(
        switchOn(t, 'share-read-status'),
        isTrue,
        reason: 'a new member shares read status by default',
      );
      await flip(t, 'share-read-status');

      final s = p.saves.single;
      expect(
        (s.sharePresence, s.shareTyping, s.shareLastSeen, s.shareReadStatus),
        (null, null, null, false),
        reason:
            'only shareReadStatus is sent -- a partial save, not a whole '
            'profile write',
      );
      expect(p.profile.shareReadStatus, isFalse);
      expect(switchOn(t, 'share-read-status'), isFalse);
    });
  });
}
