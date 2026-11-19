import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/account_deletion_controller.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/account_deletion_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

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

class DeleteFake implements AccountDeletionRepository {
  DeleteFake(this.result);
  final Result<DateTime> result;
  int calls = 0;
  @override
  Future<Result<DateTime>> requestDeletion() async {
    calls++;
    return result;
  }

  @override
  Future<Result<Set<String>>> missingUsers(List<String> ids) async =>
      const Ok(<String>{});
}

List<Override> overrides({
  FakeAuth? auth,
  FakeUpdate? update,
  ProfileFake? profile,
  PushRegistryFake? push,
  AttachmentCacheFake? photos,
  DeleteFake? del,
}) => [
  ...videoOverrides(),
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
  pushSourceProvider.overrideWithValue(PushSourceFake()),
  pushRegistryProvider.overrideWithValue(push ?? PushRegistryFake()),
  attachmentCacheProvider.overrideWithValue(photos ?? AttachmentCacheFake()),
  if (del != null) accountDeletionRepositoryProvider.overrideWithValue(del),
];

Future<void> pumpApp(
  WidgetTester t, {
  FakeAuth? auth,
  FakeUpdate? update,
  ProfileFake? profile,
  PushRegistryFake? push,
  AttachmentCacheFake? photos,
  DeleteFake? del,
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides(
        auth: auth,
        update: update,
        profile: profile,
        push: push,
        photos: photos,
        del: del,
      ),
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

Finder byKey(String k) => find.byKey(ValueKey(k));

Future<void> openPage(WidgetTester t, String row) async {
  await openSettings(t);
  await t.tap(byKey(row));
  await t.pumpAndSettle();
}

Future<void> openSettings(WidgetTester t) async {
  await t.tap(byKey('home-settings'));
  await t.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

void main() {
  group('delete account reauth box', () {
    testWidgets('a stale session shows the Sign out box', (t) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      final del = DeleteFake(Err(ReauthRequiredFailure()));
      await pumpApp(t, auth: auth, del: del);
      await openPage(t, 'settings-account');
      await t.ensureVisible(byKey('account-delete'));
      await t.tap(byKey('account-delete'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-confirm'));
      await t.pumpAndSettle();
      expect(byKey('account-delete-sign-out'), findsOneWidget);
      expect(del.calls, 1);
      expect(auth.signOuts, 0);
    });

    testWidgets('Sign out in the box signs out and leaves the settings pages', (
      t,
    ) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      final del = DeleteFake(Err(ReauthRequiredFailure()));
      await pumpApp(t, auth: auth, del: del);
      await openPage(t, 'settings-account');
      await t.ensureVisible(byKey('account-delete'));
      await t.tap(byKey('account-delete'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-confirm'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-sign-out'));
      await t.pumpAndSettle();
      expect(auth.signOuts, 1);
      expect(find.byType(SettingsScreen), findsNothing);
    });

    testWidgets('Cancel closes the box and does not sign out', (t) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      final del = DeleteFake(Err(ReauthRequiredFailure()));
      await pumpApp(t, auth: auth, del: del);
      await openPage(t, 'settings-account');
      await t.ensureVisible(byKey('account-delete'));
      await t.tap(byKey('account-delete'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-confirm'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel').last);
      await t.pumpAndSettle();
      expect(byKey('account-delete-sign-out'), findsNothing);
      expect(auth.signOuts, 0);
    });

    testWidgets('another refusal shows no Sign out box', (t) async {
      final auth = FakeAuth(session: true, member: mayaAccount);
      final del = DeleteFake(Err(ProviderFailure('nope')));
      await pumpApp(t, auth: auth, del: del);
      await openPage(t, 'settings-account');
      await t.ensureVisible(byKey('account-delete'));
      await t.tap(byKey('account-delete'));
      await t.pumpAndSettle();
      await t.tap(byKey('account-delete-confirm'));
      await t.pumpAndSettle();
      expect(byKey('account-delete-sign-out'), findsNothing);
      expect(del.calls, 1);
      await t.pump(const Duration(seconds: 3)); // the refusal notice times out
      expect(auth.signOuts, 0);
    });
  });
}
