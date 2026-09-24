// NotificationSettingsController and MutesController against a fake
// repository written from the NotificationSettingsRepository contract. The
// SDK is never here; the seam to the real database is
// test/integration/notification_settings_repository_test.dart and
// test/integration/notification_settings_seam_test.dart.
//
// Mirrors profile_controller_test.dart: no auth/runtime-config override is
// needed just to settle `currentUserIdProvider` (an incomplete runtime
// config settles the session on SetupRequired, which is enough to unblock
// the `ref.watch` both controllers make); the account-switch tests drive a
// real sign-out/sign-in cycle through a [FakeAuth] instead, the same
// mechanism `currentUserIdProvider` is built on in production (see
// account_switch_providers_test.dart for the fuller, per-provider version of
// this contract).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';

import '../../../support/fakes.dart';

ProviderContainer make(NotificationSettingsFake fake) => ProviderContainer.test(
  overrides: [notificationSettingsRepositoryProvider.overrideWithValue(fake)],
);

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

ProviderContainer makeWithAuth(NotificationSettingsFake fake, FakeAuth auth) =>
    ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        notificationSettingsRepositoryProvider.overrideWithValue(fake),
      ],
    );

int loads(NotificationSettingsFake fake) =>
    fake.calls.where((c) => c == 'load').length;
int muteLoads(NotificationSettingsFake fake) =>
    fake.calls.where((c) => c == 'mutes').length;

/// Lets a real sign-out/sign-in cycle's Stream-driven refresh run to
/// completion: `signedInChanges` fires, `_refresh` runs, and everything
/// watching `currentUserIdProvider` rebuilds — all real futures, no fake
/// clock, so this just gives the microtask queue room to drain.
Future<void> drain() async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Signs out, then in as [who], and waits for `currentUserIdProvider` to
/// settle on it.
Future<void> switchTo(ProviderContainer c, FakeAuth auth, Member who) async {
  await c.read(sessionControllerProvider.notifier).signOut();
  await drain();
  auth.member = who;
  await c.read(sessionControllerProvider.notifier).signIn();
  await drain();
  expect(c.read(currentUserIdProvider), who.userId, reason: 'switch failed');
}

void main() {
  group('NotificationSettingsController', () {
    test('build loads the settings', () async {
      final fake = NotificationSettingsFake(
        settings: const NotificationSettings(
          enabled: false,
          preview: NotificationPreview.sender,
        ),
      );
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      final s = await c.read(notificationSettingsProvider.future);
      expect(s.enabled, isFalse);
      expect(s.preview, NotificationPreview.sender);
    });

    test('nothing saved yet reads as the defaults', () async {
      final fake = NotificationSettingsFake();
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      final s = await c.read(notificationSettingsProvider.future);
      expect(s, const NotificationSettings());
    });

    test('a load failure settles on AsyncError and is not retried', () async {
      final fake = NotificationSettingsFake()
        ..loadResult = const Err(NetworkFailure('no route to host'));
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      await expectLater(
        c.read(notificationSettingsProvider.future),
        throwsA(anything),
      );

      final state = c.read(notificationSettingsProvider);
      expect(state.hasError, isTrue);
      expect((state.error! as Failure).message, 'no route to host');
      // Riverpod retries a failed build by default; the screen must settle.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(loads(fake), 1, reason: 'a failed load was retried silently');
      expect(c.read(notificationSettingsProvider).hasError, isTrue);
    });

    test('retry loads again and recovers', () async {
      final fake = NotificationSettingsFake()
        ..loadResult = const Err(NetworkFailure('offline'));
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      await expectLater(
        c.read(notificationSettingsProvider.future),
        throwsA(anything),
      );

      fake.loadResult = null;
      await c.read(notificationSettingsProvider.notifier).retry();
      final s = await c.read(notificationSettingsProvider.future);
      expect(loads(fake), 2);
      expect(s, const NotificationSettings());
    });

    test('save sends the new settings and publishes them on success', () async {
      final fake = NotificationSettingsFake();
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      await c.read(notificationSettingsProvider.future);

      final next = const NotificationSettings(
        enabled: false,
        preview: NotificationPreview.none,
      );
      final result = await c
          .read(notificationSettingsProvider.notifier)
          .save(next);

      expect(result, isA<Ok<void>>());
      expect(fake.saves.single, next);
      expect(c.read(notificationSettingsProvider).requireValue, next);
    });

    test('a refused save leaves the settings on screen exactly as they were, '
        'and returns the reason', () async {
      final fake = NotificationSettingsFake(
        settings: const NotificationSettings(enabled: true),
      );
      final c = make(fake);
      c.listen(notificationSettingsProvider, (_, _) {});
      await c.read(notificationSettingsProvider.future);

      fake.saveResult = const Err(NetworkFailure('the network is unreachable'));
      final result = await c
          .read(notificationSettingsProvider.notifier)
          .save(const NotificationSettings(enabled: false));

      expect(result, isA<Err<void>>());
      expect(
        (result as Err<void>).failure.message,
        'the network is unreachable',
      );
      expect(
        c.read(notificationSettingsProvider).requireValue,
        const NotificationSettings(enabled: true),
        reason: 'a refused save must not change the settings on screen',
      );
    });

    test('a new account reloads its own settings', () async {
      final fake = NotificationSettingsFake(
        settings: const NotificationSettings(enabled: false),
      );
      final auth = FakeAuth(
        session: true,
        member: const Member(userId: 'u1', displayName: 'A'),
      );
      final c = makeWithAuth(fake, auth);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(notificationSettingsProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      await c.read(notificationSettingsProvider.future);
      final before = loads(fake);

      fake.settings = const NotificationSettings(
        preview: NotificationPreview.none,
      );
      await switchTo(c, auth, const Member(userId: 'u2', displayName: 'B'));
      final s = await c.read(notificationSettingsProvider.future);
      expect(loads(fake), greaterThan(before), reason: 'a switch must reload');
      expect(s.preview, NotificationPreview.none);
    });
  });

  group('MutesController', () {
    test('build loads every saved mute', () async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'u2')],
      );
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      final mutes = await c.read(mutesProvider.future);
      expect(mutes, hasLength(1));
      expect(mutes.single.target, 'u2');
    });

    test('a load failure settles on AsyncError and is not retried', () async {
      final fake = NotificationSettingsFake()
        ..mutesResult = const Err(NetworkFailure('no route to host'));
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      await expectLater(c.read(mutesProvider.future), throwsA(anything));

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(muteLoads(fake), 1, reason: 'a failed load was retried silently');
      expect(c.read(mutesProvider).hasError, isTrue);
    });

    test('mute adds a new entry with the length\'s until', () async {
      final fake = NotificationSettingsFake();
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      await c.read(mutesProvider.future);

      final before = DateTime.now();
      final result = await c
          .read(mutesProvider.notifier)
          .mute(MuteKind.conversation, 'c1', MuteLength.eightHours);
      final after = DateTime.now();

      expect(result, isA<Ok<void>>());
      final (kind, target, until) = fake.muteCalls.single;
      expect((kind, target), (MuteKind.conversation, 'c1'));
      expect(until, isNotNull);
      expect(
        until!.difference(before),
        greaterThanOrEqualTo(const Duration(hours: 8)),
      );
      expect(
        until.difference(after),
        lessThanOrEqualTo(const Duration(hours: 8)),
      );
      final state = c.read(mutesProvider).requireValue;
      expect(state.single.target, 'c1');
    });

    test(
      'muting an already-muted target replaces it, not duplicates it',
      () async {
        final now = DateTime.now();
        final fake = NotificationSettingsFake(
          mutes: [
            Mute(
              kind: MuteKind.person,
              target: 'u2',
              until: now.add(const Duration(hours: 1)),
            ),
          ],
        );
        final c = make(fake);
        c.listen(mutesProvider, (_, _) {});
        await c.read(mutesProvider.future);

        await c
            .read(mutesProvider.notifier)
            .mute(MuteKind.person, 'u2', MuteLength.always);

        final state = c.read(mutesProvider).requireValue;
        expect(
          state.where((m) => m.kind == MuteKind.person && m.target == 'u2'),
          hasLength(1),
          reason:
              're-muting the same target must replace, not add a second '
              'entry',
        );
        expect(state.single.until, isNull, reason: 'always = no until');
      },
    );

    test('a refused mute leaves the mutes on screen unchanged', () async {
      final fake = NotificationSettingsFake()
        ..muteResult = const Err(NetworkFailure('offline'));
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      await c.read(mutesProvider.future);

      final result = await c
          .read(mutesProvider.notifier)
          .mute(MuteKind.person, 'u2', MuteLength.eightHours);

      expect(result, isA<Err<void>>());
      expect(c.read(mutesProvider).requireValue, isEmpty);
    });

    test('unmute removes the entry', () async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'u2')],
      );
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      await c.read(mutesProvider.future);

      final result = await c
          .read(mutesProvider.notifier)
          .unmute(MuteKind.person, 'u2');

      expect(result, isA<Ok<void>>());
      expect(c.read(mutesProvider).requireValue, isEmpty);
      expect(fake.unmuteCalls.single, (MuteKind.person, 'u2'));
    });

    test('a refused unmute leaves the mute on screen', () async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'u2')],
      )..unmuteResult = const Err(NetworkFailure('offline'));
      final c = make(fake);
      c.listen(mutesProvider, (_, _) {});
      await c.read(mutesProvider.future);

      final result = await c
          .read(mutesProvider.notifier)
          .unmute(MuteKind.person, 'u2');

      expect(result, isA<Err<void>>());
      expect(c.read(mutesProvider).requireValue, hasLength(1));
    });

    test('a new account reloads its own mutes', () async {
      final fake = NotificationSettingsFake(
        mutes: const [Mute(kind: MuteKind.person, target: 'u2')],
      );
      final auth = FakeAuth(
        session: true,
        member: const Member(userId: 'u1', displayName: 'A'),
      );
      final c = makeWithAuth(fake, auth);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(mutesProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      await c.read(mutesProvider.future);
      final before = muteLoads(fake);

      fake.savedMutes = [];
      await switchTo(c, auth, const Member(userId: 'u3', displayName: 'C'));
      final mutes = await c.read(mutesProvider.future);
      expect(
        muteLoads(fake),
        greaterThan(before),
        reason: 'a switch must reload',
      );
      expect(mutes, isEmpty);
    });
  });

  group('activeMute', () {
    final now = DateTime.utc(2026, 9, 24, 12);
    test('ignores a different kind or target', () {
      final mutes = [Mute(kind: MuteKind.person, target: 'u2')];
      expect(activeMute(mutes, MuteKind.conversation, 'u2', now), isNull);
      expect(activeMute(mutes, MuteKind.person, 'u3', now), isNull);
    });

    test('finds the matching, still-active mute', () {
      final mutes = [
        Mute(kind: MuteKind.person, target: 'u2'),
        Mute(
          kind: MuteKind.conversation,
          target: 'c1',
          until: now.add(const Duration(hours: 1)),
        ),
      ];
      expect(activeMute(mutes, MuteKind.conversation, 'c1', now)?.target, 'c1');
    });

    test('an expired mute counts as none', () {
      final mutes = [
        Mute(
          kind: MuteKind.person,
          target: 'u2',
          until: now.subtract(const Duration(minutes: 1)),
        ),
      ];
      expect(activeMute(mutes, MuteKind.person, 'u2', now), isNull);
    });
  });
}
