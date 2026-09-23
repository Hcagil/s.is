// The settings hub and its pages, written from the contract: the profile
// card, Privacy, Account (with sign-out) and About (version and licences).
//
// Mounted as production mounts them — SisApp behind the session gate, fakes
// only at the repository boundary — except the hub's own loading and failure
// states: home is never shown before the profile has loaded, so those are
// reached by mounting SettingsScreen alone over a profile read that is held
// or refused.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/brand.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/main.dart' as entry;

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

const mayaAccount = Member(
  userId: 'u1',
  displayName: 'Maya Google',
  email: 'maya.k@example.org',
);

List<Override> overrides({
  FakeAuth? auth,
  FakeUpdate? update,
  ProfileFake? profile,
}) => [
  runtimeConfigProvider.overrideWithValue(config),
  authRepositoryProvider.overrideWithValue(
    auth ?? FakeAuth(session: true, member: mayaAccount),
  ),
  updateRepositoryProvider.overrideWithValue(update ?? FakeUpdate()),
  chatRepositoryProvider.overrideWithValue(FakeChat()),
  presenceRepositoryProvider.overrideWithValue(PresenceFake()),
  profileRepositoryProvider.overrideWithValue(
    profile ?? ProfileFake(profile: maya),
  ),
];

Future<void> pumpApp(
  WidgetTester t, {
  FakeAuth? auth,
  FakeUpdate? update,
  ProfileFake? profile,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides(auth: auth, update: update, profile: profile),
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

Finder byKey(String k) => find.byKey(ValueKey(k));

Finder under(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text));

Finder appBarTitle(String title) =>
    find.descendant(of: find.byType(AppBar), matching: find.text(title));

Future<void> openSettings(WidgetTester t) async {
  await t.tap(byKey('home-settings'));
  await t.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

Future<void> openPage(WidgetTester t, String row) async {
  await openSettings(t);
  await t.tap(byKey(row));
  await t.pumpAndSettle();
}

/// Whether [text] sits inside something round.
bool inCircle(Finder text) => find
    .ancestor(of: text, matching: find.byWidgetPredicate((_) => true))
    .evaluate()
    .map((e) => e.widget)
    .any(
      (w) => switch (w) {
        CircleAvatar() || ClipOval() => true,
        Container(decoration: BoxDecoration(shape: BoxShape.circle)) => true,
        DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle)) => true,
        Container(decoration: ShapeDecoration(shape: CircleBorder())) => true,
        DecoratedBox(decoration: ShapeDecoration(shape: CircleBorder())) =>
          true,
        Material(shape: CircleBorder()) => true,
        Material(type: MaterialType.circle) => true,
        _ => false,
      },
    );

void main() {
  group('settings hub', () {
    testWidgets('is titled Settings and leads with the profile card', (
      t,
    ) async {
      await pumpApp(t);
      await openSettings(t);

      expect(appBarTitle('Settings'), findsOneWidget);
      final initials = under('settings-profile', 'MP');
      expect(initials, findsOneWidget, reason: 'no initials on the card');
      expect(inCircle(initials), isTrue, reason: 'initials are not round');
      expect(under('settings-profile', 'Maya Profile'), findsOneWidget);
      expect(under('settings-profile', '@maya'), findsOneWidget);
      expect(
        find.textContaining('Maya Google'),
        findsNothing,
        reason: 'the card must name the member by the profile, not Google',
      );
    });

    testWidgets('lists Privacy, Account and About below the card', (t) async {
      await pumpApp(t);
      await openSettings(t);

      final card = t.getTopLeft(byKey('settings-profile')).dy;
      var above = card;
      for (final (key, label) in [
        ('settings-privacy', 'Privacy'),
        ('settings-account', 'Account'),
        ('settings-about', 'About'),
      ]) {
        expect(under(key, label), findsOneWidget, reason: '$key label');
        final y = t.getTopLeft(byKey(key)).dy;
        expect(y, greaterThan(above), reason: '$key is out of order');
        above = y;
      }
    });

    for (final (key, title) in [
      ('settings-profile', 'Profile'),
      ('settings-privacy', 'Privacy'),
      ('settings-account', 'Account'),
      ('settings-about', 'About'),
    ]) {
      testWidgets('$key opens "$title"', (t) async {
        await pumpApp(t);
        await openPage(t, key);
        expect(appBarTitle(title), findsOneWidget);
        expect(find.byType(SettingsScreen), findsNothing, reason: 'not pushed');
        await t.pageBack();
        await t.pumpAndSettle();
        expect(appBarTitle('Settings'), findsOneWidget);
      });
    }

    testWidgets('the profile page holds the form, and Save says "Saved"', (
      t,
    ) async {
      final p = ProfileFake(profile: maya);
      await pumpApp(t, profile: p);
      await openPage(t, 'settings-profile');

      expect(byKey('profile-name'), findsOneWidget);
      expect(byKey('profile-tag'), findsOneWidget);
      await t.enterText(byKey('profile-name'), 'Maya Kaya');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      await t.tap(byKey('profile-submit'));
      await t.pumpAndSettle();

      expect(find.text('Saved'), findsOneWidget);
      expect(p.saves.single.displayName, 'Maya Kaya');
      await t.pumpAndSettle(const Duration(seconds: 6));
    });

    Widget alone(ProfileFake p) => ProviderScope(
      overrides: overrides(profile: p),
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        home: const SettingsScreen(),
      ),
    );

    testWidgets('shows a spinner while the profile loads', (t) async {
      final p = ProfileFake(profile: maya)..holdLoad();
      await t.pumpWidget(alone(p));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(byKey('settings-profile'), findsNothing);

      p.releaseLoad();
      await t.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(under('settings-profile', 'Maya Profile'), findsOneWidget);
    });

    testWidgets('a profile that cannot be read shows why, and Try again '
        'works', (t) async {
      final p = ProfileFake(profile: maya)
        ..loadResult = const Err(NetworkFailure('no route to host'));
      await t.pumpWidget(alone(p));
      await t.pumpAndSettle();

      expect(find.textContaining('no route to host'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(byKey('settings-profile'), findsNothing);

      p.loadResult = null;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.textContaining('no route to host'), findsNothing);
      expect(under('settings-profile', 'Maya Profile'), findsOneWidget);
    });
  });

  group('privacy page', () {
    testWidgets('holds the three sharing switches, labelled', (t) async {
      await pumpApp(t);
      await openPage(t, 'settings-privacy');

      expect(appBarTitle('Privacy'), findsOneWidget);
      for (final (key, label) in [
        ('share-presence', 'Show when I am online'),
        ('share-typing', 'Show when I am typing'),
        ('share-last-seen', 'Show my last seen'),
      ]) {
        await t.ensureVisible(byKey(key));
        expect(under(key, label), findsOneWidget, reason: '$key label');
        expect(
          find.descendant(
            of: byKey(key),
            matching: find.byType(Switch),
            matchRoot: true,
          ),
          findsOneWidget,
          reason: '$key is not a switch',
        );
      }
      expect(
        under(
          'share-last-seen',
          'While this is off, you can\'t see anyone else\'s either.',
        ),
        findsOneWidget,
      );
    });
  });

  group('account page', () {
    testWidgets('names the Google account signed in', (t) async {
      await pumpApp(t);
      await openPage(t, 'settings-account');

      expect(appBarTitle('Account'), findsOneWidget);
      expect(find.text('Signed in with Google as'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('account-email'),
          matching: find.text('maya.k@example.org'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Unknown account'), findsNothing);
    });

    testWidgets('says "Unknown account" when the email is not known', (
      t,
    ) async {
      await pumpApp(
        t,
        auth: FakeAuth(
          session: true,
          member: const Member(userId: 'u1', displayName: 'Maya'),
        ),
      );
      await openPage(t, 'settings-account');

      expect(
        find.descendant(
          of: byKey('account-email'),
          matching: find.text('Unknown account'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('sign-out returns to the root first, then signs out, and '
        'leaves no settings page behind', (t) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      await pumpApp(t, auth: auth);
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      bool? couldPopAtSignOut;
      auth.onSignOut = () => couldPopAtSignOut = nav.canPop();

      await openPage(t, 'settings-account');
      expect(nav.canPop(), isTrue);
      await t.tap(byKey('account-sign-out'));
      await t.pumpAndSettle();

      expect(auth.signOuts, 1);
      expect(
        couldPopAtSignOut,
        isFalse,
        reason: 'signed out with settings pages still on the stack',
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(nav.canPop(), isFalse, reason: 'a page is left on the stack');
      for (final gone in [
        find.byType(SettingsScreen, skipOffstage: false),
        find.text('Signed in with Google as', skipOffstage: false),
        find.byKey(const ValueKey('account-sign-out'), skipOffstage: false),
        find.byType(HomeScreen, skipOffstage: false),
      ]) {
        expect(gone, findsNothing);
      }

      // Signing back in lands on home, not on a stale settings page.
      await t.tap(find.text('Continue with Google'));
      await t.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
      expect(nav.canPop(), isFalse);
    });
  });

  group('about page', () {
    testWidgets('shows the brand and the running version', (t) async {
      await pumpApp(t, update: FakeUpdate(installed: 217, version: '1.4.2'));
      await openPage(t, 'settings-about');

      expect(appBarTitle('About'), findsOneWidget);
      expect(find.byType(SisLogo), findsOneWidget);
      expect(find.byType(SisWordmark), findsOneWidget);
      expect(find.text('Stay in sync'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('about-version'),
          matching: find.text('Version 1.4.2 (217)'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('lists the bundled font licences that main.dart registers', (
      t,
    ) async {
      LicenseRegistry.reset();
      addTearDown(LicenseRegistry.reset);
      // Without dart-defines main() registers the licences, then mounts the
      // "Setup required" app, which is swapped out at once. A frame first, so
      // runApp's warm-up frame is not stamped with the previous test's clock.
      await t.pumpWidget(const SizedBox());
      await entry.main();
      await t.pumpWidget(const SizedBox());

      final entries = await t.runAsync(() => LicenseRegistry.licenses.toList());
      for (final font in ['manrope', 'sora']) {
        final e = entries!.where((e) => e.packages.contains(font)).toList();
        expect(e, hasLength(1), reason: 'no licence registered for $font');
        final text = e.single.paragraphs.map((p) => p.text).join('\n');
        expect(text, contains('SIL OPEN FONT LICENSE'), reason: font);
      }

      await pumpApp(t);
      await openPage(t, 'settings-about');
      expect(under('about-licences', 'Open-source licences'), findsOneWidget);
      await t.tap(byKey('about-licences'));
      // The page spins while it reads the registry off the real asset bundle.
      for (var i = 0; i < 50 && find.text('sora').evaluate().isEmpty; i++) {
        // The registry reads the licence files off disk: real I/O.
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
      }
      await t.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.text('manrope'), findsOneWidget);
      expect(find.text('sora'), findsOneWidget);
    });
  });
}
