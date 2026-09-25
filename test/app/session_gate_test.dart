import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/onboarding_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_repository.dart';

import '../support/fakes.dart';
import '../support/sis_ui.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Widget app(FakeAuth a, FakeUpdate u, [FakeChat? c, ProfileFake? p]) =>
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(a),
        updateRepositoryProvider.overrideWithValue(u),
        // The home of an allowed member is the conversation list.
        chatRepositoryProvider.overrideWithValue(c ?? FakeChat()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        // Every allowed member's profile is read before home is shown.
        profileRepositoryProvider.overrideWithValue(p ?? ProfileFake()),
      ],
      child: const SisApp(),
    );

const newcomer = OwnProfile(
  userId: 'u1',
  displayName: 'Maya Google',
  tag: 'maya_google',
  onboardingDone: false,
);

Finder profileCard(String text) => find.descendant(
  of: find.byKey(const ValueKey('settings-profile')),
  matching: find.text(text),
);

final retryButton = find.textContaining(
  RegExp('retry|try again', caseSensitive: false),
);

void main() {
  testWidgets('signed out shows button and the last failure reason', (t) async {
    final a = FakeAuth(
      signInResult: const Err(
        ProviderFailure('Google sign-in canceled: console', userCanceled: true),
      ),
    );
    await t.pumpWidget(app(a, FakeUpdate()));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('console'), findsOneWidget);
  });
  testWidgets('denied', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true, allowed: false), FakeUpdate()),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('not currently approved'), findsOneWidget);
  });
  testWidgets('allowed reaches the conversation list', (t) async {
    await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate()));
    await t.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    expect(find.byType(OnboardingScreen), findsNothing);
    // The member is still identified, now on the settings profile card.
    await t.tap(find.byKey(const ValueKey('home-settings')));
    await t.pumpAndSettle();
    expect(profileCard('Maya'), findsOneWidget);
    expect(profileCard('@maya'), findsOneWidget);
  });

  group('onboarding', () {
    testWidgets('a member who has not onboarded sees onboarding, not home', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer);
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.text('New chat'), findsNothing);
      // The generated name and tag are offered, not a blank form.
      expect(find.text('Maya Google'), findsWidgets);
      expect(find.text('maya_google'), findsWidgets);
    });

    testWidgets('skipping goes home and keeps the Google name and tag', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer);
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('onboarding-skip')));
      await t.pumpAndSettle();

      expect(find.text('New chat'), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(p.saves, hasLength(1));
      expect(p.profile.onboardingDone, isTrue);
      expect(p.profile.displayName, 'Maya Google');
      expect(p.profile.tag, 'maya_google');
    });

    testWidgets('continuing saves name, tag and the flag, then goes home', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer);
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const ValueKey('profile-name')), 'Maya R');
      await t.enterText(find.byKey(const ValueKey('profile-tag')), 'maya_r');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('profile-submit')));
      await t.pumpAndSettle();

      expect(find.text('New chat'), findsOneWidget);
      expect(p.saves, hasLength(1), reason: 'not one statement');
      final s = p.saves.single;
      expect(
        (s.displayName, s.tag, s.onboardingDone),
        ('Maya R', 'maya_r', true),
      );
      // Settings names the member by the profile just saved, not by the
      // Google account the session started with ("Maya").
      await t.tap(find.byKey(const ValueKey('home-settings')));
      await t.pumpAndSettle();
      expect(profileCard('Maya R'), findsOneWidget);
      expect(profileCard('@maya_r'), findsOneWidget);
      expect(find.textContaining('Maya Google'), findsNothing);
    });

    testWidgets('a refused continue stays on onboarding with the reason', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer);
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const ValueKey('profile-tag')), 'maya');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      p.claimByOther('maya'); // someone else got there first
      await t.tap(find.byKey(const ValueKey('profile-submit')));
      await t.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.text('New chat'), findsNothing);
      expect(
        find.textContaining('That tag was just taken by someone.'),
        findsOneWidget,
      );
      expect(p.profile.onboardingDone, isFalse);
    });

    testWidgets('a failed skip stays on onboarding with the reason', (t) async {
      final p = ProfileFake(profile: newcomer)
        ..saveResult = const Err(NetworkFailure('no route to host'));
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('onboarding-skip')));
      await t.pumpAndSettle();

      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.textContaining('no route to host'), findsOneWidget);
      await t.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('a profile that cannot be read shows why, and retry works', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer)
        ..loadResult = const Err(NetworkFailure('no route to host'));
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pumpAndSettle();

      expect(find.textContaining('no route to host'), findsOneWidget);
      expect(find.text('New chat'), findsNothing);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(retryButton, findsOneWidget);

      p.loadResult = null;
      await t.tap(retryButton);
      await t.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
    });

    testWidgets('home is not shown while the profile is still loading', (
      t,
    ) async {
      final p = ProfileFake(profile: newcomer)..holdLoad();
      await t.pumpWidget(app(FakeAuth(session: true), FakeUpdate(), null, p));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(
        find.text('New chat'),
        findsNothing,
        reason: 'home flashed before we knew onboarding was due',
      );
      p.releaseLoad();
      await t.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
    });
  });
  testWidgets('update required hides the app', (t) async {
    await t.pumpWidget(
      app(FakeAuth(session: true), FakeUpdate(min: const Ok(999))),
    );
    await t.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    expect(find.text('New chat'), findsNothing);
  });
  testWidgets('flexible update shows a dismissible banner', (t) async {
    await t.pumpWidget(
      app(
        FakeAuth(session: true),
        FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107))),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    await t.tap(find.text('Later'));
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
  });
  testWidgets('error shows reason and retry', (t) async {
    final a = FakeAuth(
      signInResult: const Err(
        ProviderFailure('Supabase rejected the Google token: boom'),
      ),
    );
    await t.pumpWidget(app(a, FakeUpdate()));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue with Google'));
    await t.pumpAndSettle();
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('incomplete config shows setup required without any backend', (
    t,
  ) async {
    await t.pumpWidget(const ProviderScope(overrides: [], child: SisApp()));
    await t.pumpAndSettle();
    expect(find.text('Setup required'), findsOneWidget);
  });

  testWidgets('finished download shows restart', (t) async {
    await t.pumpWidget(
      app(
        FakeAuth(session: true),
        FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107))),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Update'));
    await t.pumpAndSettle();
    expect(find.text('Ready to install'), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);
  });

  group('returning to the app re-checks for updates', () {
    /// Background, then foreground, the way Android reports it.
    Future<void> leaveAndReturn(WidgetTester t) async {
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
    }

    testWidgets('a build released while backgrounded shows the banner', (
      t,
    ) async {
      final u = FakeUpdate();
      await t.pumpWidget(app(FakeAuth(session: true), u));
      await t.pumpAndSettle();
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Update available'), findsNothing);
      final before = u.checks;

      u.offer(108);
      await leaveAndReturn(t);
      await t.pumpAndSettle();

      expect(u.checks, greaterThan(before), reason: 'resume never asked Play');
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('a download finished while backgrounded offers restart', (
      t,
    ) async {
      final u = FakeUpdate()..offer(107);
      await t.pumpWidget(app(FakeAuth(session: true), u));
      await t.pumpAndSettle();
      expect(find.text('Update available'), findsOneWidget);

      u.play = const Ok(PlayUpdateCheck(offeredBuild: 107, downloaded: true));
      await leaveAndReturn(t);
      await t.pumpAndSettle();

      expect(find.text('Ready to install'), findsOneWidget);
      await t.tap(find.text('Restart'));
      await t.pumpAndSettle();
      expect(u.calls, ['complete']);
    });

    testWidgets('a failing Play check on resume leaves the app usable', (
      t,
    ) async {
      final u = FakeUpdate();
      await t.pumpWidget(app(FakeAuth(session: true), u));
      await t.pumpAndSettle();
      final before = u.checks;

      u.play = const Err(NetworkFailure('no Play'));
      await leaveAndReturn(t);
      await t.pumpAndSettle();

      expect(u.checks, greaterThan(before));
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Update available'), findsNothing);
      expect(find.textContaining('no Play'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('below the minimum, resume keeps the block without flicker', (
      t,
    ) async {
      final u = FakeUpdate(min: const Ok(999));
      await t.pumpWidget(app(FakeAuth(session: true), u));
      await t.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
      final before = u.minReads;

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
      // Every frame while the re-check resolves still shows the block.
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(
          find.text('Update required'),
          findsOneWidget,
          reason: 'frame $i',
        );
        expect(sisWait, findsNothing);
      }
      await t.pumpAndSettle();
      expect(u.minReads, greaterThan(before), reason: 'policy not re-read');
      expect(find.text('Update required'), findsOneWidget);
      expect(u.calls, isNot(contains('immediate')));
    });
  });
}
