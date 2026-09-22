// OwnProfileController against a fake repository written from the
// ProfileRepository contract. The SDK is never here; the seam to the real
// database is test/integration/profile_integration_test.dart.
//
// The rename coverage that used to live in the chat controller tests moved
// here with the feature: a save sends what was asked for, and a refusal comes
// back with its reason and keeps what was on screen.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

const fresh = OwnProfile(
  userId: 'u1',
  displayName: 'Çağıl Öztürk',
  tag: 'cagil_ozturk',
  onboardingDone: false,
);

ProviderContainer make(ProfileFake fake) => ProviderContainer.test(
  overrides: [profileRepositoryProvider.overrideWithValue(fake)],
);

/// Reads the profile the way a screen does: watched, so autoDispose keeps it.
Future<ProviderContainer> loaded(ProfileFake fake) async {
  final c = make(fake);
  c.listen(ownProfileProvider, (_, _) {});
  await c.read(ownProfileProvider.future);
  return c;
}

OwnProfileController notifier(ProviderContainer c) =>
    c.read(ownProfileProvider.notifier);

int loads(ProfileFake fake) => fake.calls.where((c) => c == 'load').length;

void main() {
  group('build', () {
    test('loads the member\'s own profile', () async {
      final fake = ProfileFake(profile: fresh);
      final c = await loaded(fake);
      final p = c.read(ownProfileProvider).requireValue;
      expect(p.displayName, 'Çağıl Öztürk');
      expect(p.tag, 'cagil_ozturk');
      expect(p.onboardingDone, isFalse);
    });

    test('a failed load settles on the failure and is not retried', () async {
      final fake = ProfileFake(profile: fresh)
        ..loadResult = const Err(NetworkFailure('no route to host'));
      final c = make(fake);
      c.listen(ownProfileProvider, (_, _) {});
      await expectLater(c.read(ownProfileProvider.future), throwsA(anything));

      final state = c.read(ownProfileProvider);
      expect(state.hasError, isTrue);
      expect(
        (state.error! as Failure).message,
        'no route to host',
        reason: 'the screen needs the reason, not a generic error',
      );
      // Riverpod retries a failed build by default; the screen would never
      // settle on the error it has to show.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(loads(fake), 1, reason: 'a failed load was retried silently');
      expect(c.read(ownProfileProvider).hasError, isTrue);
    });

    test('retry loads again and recovers', () async {
      final fake = ProfileFake(profile: fresh)
        ..loadResult = const Err(NetworkFailure('no route to host'));
      final c = make(fake);
      c.listen(ownProfileProvider, (_, _) {});
      await expectLater(c.read(ownProfileProvider.future), throwsA(anything));

      fake.loadResult = null;
      await notifier(c).retry();
      await c.read(ownProfileProvider.future);

      expect(loads(fake), 2);
      expect(c.read(ownProfileProvider).requireValue.tag, 'cagil_ozturk');
    });

    test('a profile nobody watches is dropped, so the next member on this '
        'phone never sees the previous one', () async {
      final fake = ProfileFake(profile: fresh);
      final c = make(fake);
      final sub = c.listen(ownProfileProvider, (_, _) {});
      await c.read(ownProfileProvider.future);
      sub.close();
      await c.pump();

      fake.profile = const OwnProfile(
        userId: 'u9',
        displayName: 'Noor',
        tag: 'noor',
        onboardingDone: true,
      );
      c.listen(ownProfileProvider, (_, _) {});
      final next = await c.read(ownProfileProvider.future);
      expect(next.userId, 'u9', reason: 'the previous member\'s profile stuck');
      expect(loads(fake), 2);
    });
  });

  group('save', () {
    test('sends name and tag in one save and publishes the result', () async {
      final fake = ProfileFake(profile: fresh);
      final c = await loaded(fake);

      final result = await notifier(c).save(displayName: 'Çağıl', tag: 'cagil');

      expect(result, isA<Ok<OwnProfile>>());
      expect(fake.saves, hasLength(1), reason: 'a save must be one statement');
      expect(fake.saves.single.displayName, 'Çağıl');
      expect(fake.saves.single.tag, 'cagil');
      final now = c.read(ownProfileProvider).requireValue;
      expect(now.displayName, 'Çağıl', reason: 'the screen shows the old name');
      expect(now.tag, 'cagil');
    });

    test('a tag another member holds is refused with its reason, and the '
        'profile on screen is kept', () async {
      final fake = ProfileFake(profile: fresh, takenByOthers: ['bob']);
      final c = await loaded(fake);

      final result = await notifier(c).save(displayName: 'X', tag: 'bob');

      expect(result, isA<Err<OwnProfile>>());
      expect((result as Err<OwnProfile>).failure.message, isNotEmpty);
      final state = c.read(ownProfileProvider);
      expect(state.hasError, isFalse, reason: 'a refusal blanked the screen');
      expect(state.requireValue.tag, 'cagil_ozturk');
      expect(state.requireValue.displayName, 'Çağıl Öztürk');
      expect(fake.profile.displayName, 'Çağıl Öztürk', reason: 'half-saved');
    });

    test('a refused name comes back with the reason', () async {
      final fake = ProfileFake(profile: fresh);
      final c = await loaded(fake);

      final result = await notifier(c).save(displayName: 'z' * 81);

      expect(result, isA<Err<OwnProfile>>());
      expect((result as Err<OwnProfile>).failure.message, isNotEmpty);
      expect(
        c.read(ownProfileProvider).requireValue.displayName,
        fresh.displayName,
      );
    });
  });

  group('completeOnboarding', () {
    test(
      'with nothing given keeps the Google name and generated tag',
      () async {
        final fake = ProfileFake(profile: fresh);
        final c = await loaded(fake);

        final result = await notifier(c).completeOnboarding();

        expect(result, isA<Ok<OwnProfile>>());
        expect(fake.saves, hasLength(1));
        expect(fake.saves.single.onboardingDone, isTrue);
        expect(fake.profile.displayName, 'Çağıl Öztürk');
        expect(fake.profile.tag, 'cagil_ozturk');
        expect(fake.profile.onboardingDone, isTrue);
        expect(c.read(ownProfileProvider).requireValue.onboardingDone, isTrue);
      },
    );

    test('with a name and tag saves them and the flag together', () async {
      final fake = ProfileFake(profile: fresh);
      final c = await loaded(fake);

      final result = await notifier(c)
          .completeOnboarding(displayName: 'Çağıl', tag: 'cagil');

      expect(result, isA<Ok<OwnProfile>>());
      expect(
        fake.saves,
        hasLength(1),
        reason:
            'name, tag and the flag must land in one statement, or a '
            'refused tag leaves onboarding marked done',
      );
      final s = fake.saves.single;
      expect(
        (s.displayName, s.tag, s.onboardingDone),
        ('Çağıl', 'cagil', true),
      );
      final now = c.read(ownProfileProvider).requireValue;
      expect(
        (now.displayName, now.tag, now.onboardingDone),
        ('Çağıl', 'cagil', true),
      );
    });

    test('a refused tag leaves onboarding not done', () async {
      final fake = ProfileFake(profile: fresh, takenByOthers: ['bob']);
      final c = await loaded(fake);

      final result = await notifier(c).completeOnboarding(tag: 'bob');

      expect(result, isA<Err<OwnProfile>>());
      expect((result as Err<OwnProfile>).failure.message, isNotEmpty);
      expect(fake.profile.onboardingDone, isFalse);
      expect(
        c.read(ownProfileProvider).requireValue.onboardingDone,
        isFalse,
        reason: 'the member would be let past a screen whose save failed',
      );
    });
  });

  group('checkTag', () {
    test('answers from the repository', () async {
      final fake = ProfileFake(profile: fresh, takenByOthers: ['bob']);
      final c = await loaded(fake);

      expect(
        await notifier(c).checkTag('bob'),
        isA<Ok<bool>>().having((r) => r.value, 'value', isFalse),
      );
      expect(
        (await notifier(c).checkTag('free_tag') as Ok<bool>).value,
        isTrue,
      );
      expect(
        (await notifier(c).checkTag('cagil_ozturk') as Ok<bool>).value,
        isTrue,
        reason: 'the member\'s own tag counts as available',
      );
    });

    test('a failed check comes back as a failure, not as "taken"', () async {
      final fake = ProfileFake(profile: fresh)
        ..availabilityResult = const Err(NetworkFailure('offline'));
      final c = await loaded(fake);

      final result = await notifier(c).checkTag('free_tag');
      expect(result, isA<Err<bool>>());
    });
  });
}
