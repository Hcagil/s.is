// Settings and the home menu, mounted as production mounts them: the whole
// app behind the session gate, with fakes only at the repository boundary.
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
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

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

Future<void> pumpApp(WidgetTester t, ProfileFake p, {FakeAuth? auth}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(
          auth ?? FakeAuth(session: true),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(FakeChat()),
        profileRepositoryProvider.overrideWithValue(p),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Future<void> openMenu(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('home-menu')));
  await t.pumpAndSettle();
}

Future<void> openSettings(WidgetTester t) async {
  await openMenu(t);
  await t.tap(find.byKey(const ValueKey('menu-settings')));
  await t.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

Finder signOutWith(String name) => find.descendant(
  of: find.byKey(const ValueKey('menu-sign-out')),
  matching: find.textContaining(name),
  matchRoot: true,
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
  testWidgets('the menu offers settings and sign-out, and no rename dialog', (
    t,
  ) async {
    await pumpApp(t, ProfileFake(profile: maya));
    await openMenu(t);

    expect(find.byKey(const ValueKey('menu-settings')), findsOneWidget);
    expect(
      signOutWith('Maya Profile'),
      findsOneWidget,
      reason: 'sign-out must name the member by the profile',
    );
    expect(find.text('Change display name'), findsNothing);
  });

  testWidgets('settings opens on the current name and tag', (t) async {
    await pumpApp(t, ProfileFake(profile: maya));
    await openSettings(t);

    expect(fieldText(t, 'profile-name'), 'Maya Profile');
    expect(fieldText(t, 'profile-tag'), 'maya');
  });

  testWidgets('a rename is saved, confirmed, and shows in the menu at once', (
    t,
  ) async {
    final p = ProfileFake(profile: maya);
    await pumpApp(t, p);
    await openSettings(t);

    await t.enterText(find.byKey(const ValueKey('profile-name')), 'Maya R');
    await save(t);

    expect(find.text('Saved'), findsOneWidget);
    expect(p.saves.single.displayName, 'Maya R');
    expect(p.profile.displayName, 'Maya R');

    await t.pageBack();
    await t.pumpAndSettle();
    await openMenu(t);
    expect(
      signOutWith('Maya R'),
      findsOneWidget,
      reason: 'the menu still shows the old name after a rename',
    );
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
    await openSettings(t);

    await t.enterText(find.byKey(const ValueKey('profile-tag')), '@Maya_R');
    await save(t);

    expect(p.checks, ['maya_r']);
    expect(p.profile.tag, 'maya_r');
    expect(find.text('Saved'), findsOneWidget);
    await t.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a refused save shows the reason, not "Saved", and keeps the '
      'typing', (t) async {
    final p = ProfileFake(profile: maya);
    await pumpApp(t, p);
    await openSettings(t);

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
    await openSettings(t);

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
    await pumpApp(t, p, auth: auth);

    await openMenu(t);
    await t.tap(find.byKey(const ValueKey('menu-sign-out')));
    await t.pumpAndSettle();
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
    await openMenu(t);

    expect(
      signOutWith('Noor'),
      findsOneWidget,
      reason: 'the previous member\'s profile survived sign-out',
    );
    expect(find.textContaining('Maya Profile'), findsNothing);
  });
}
