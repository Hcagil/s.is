import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_repository.dart';
import 'package:sis/features/update/domain/update_state.dart';

import '../../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

/// An allowed, active session by default; the policy is only read then.
ProviderContainer make(FakeUpdate f, {bool signedIn = true}) =>
    ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(FakeAuth(session: signedIn)),
        updateRepositoryProvider.overrideWithValue(f),
      ],
    );

Future<UpdateState> settle(ProviderContainer c) async {
  await c.read(sessionControllerProvider.future);
  await Future<void>.delayed(Duration.zero);
  return c.read(updateControllerProvider.future);
}

void main() {
  test('no update, supported → idle', () async {
    expect(await settle(make(FakeUpdate())), isA<UpdateIdle>());
  });

  test('Play has newer build → flexible available', () async {
    final s = await settle(
      make(FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107)))),
    );
    expect(s, isA<UpdateAvailableFlexible>());
    expect((s as UpdateAvailableFlexible).versionCode, 107);
  });

  test('below minimum → required, even without Play info', () async {
    final s = await settle(make(FakeUpdate(min: const Ok(110))));
    expect(s, isA<UpdateRequired>());
    expect((s as UpdateRequired).minimum, 110);
  });

  test('signed out → the minimum is not consulted', () async {
    final f = FakeUpdate(min: const Ok(110));
    expect(await settle(make(f, signedIn: false)), isA<UpdateIdle>());
  });

  test('declined download → back to the offer', () async {
    final f = FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107)))
      ..failFlexible = true;
    final c = make(f);
    await settle(c);
    await c.read(updateControllerProvider.notifier).download();
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateAvailableFlexible>(),
    );
  });

  test('immediate update unavailable → store listing', () async {
    final f = FakeUpdate(min: const Ok(110))..failImmediate = true;
    final c = make(f);
    await settle(c);
    await c.read(updateControllerProvider.notifier).updateNow();
    expect(f.calls, ['immediate', 'store']);
  });

  test('policy fetch fails → never block', () async {
    final s = await settle(
      make(FakeUpdate(min: const Err(NetworkFailure('offline')))),
    );
    expect(s, isA<UpdateIdle>());
  });

  test('dismiss → idle', () async {
    final c = make(
      FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107))),
    );
    await settle(c);
    c.read(updateControllerProvider.notifier).dismiss();
    expect(c.read(updateControllerProvider).requireValue, isA<UpdateIdle>());
  });

  test('download → downloading then ready', () async {
    final f = FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107)));
    final c = make(f);
    await settle(c);
    await c.read(updateControllerProvider.notifier).download();
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateReadyToInstall>(),
    );
    expect(f.calls, ['flexible']);
  });

  group('recheck', () {
    UpdateController notifier(ProviderContainer c) =>
        c.read(updateControllerProvider.notifier);
    UpdateState now(ProviderContainer c) =>
        c.read(updateControllerProvider).requireValue;

    test('a build released while running is offered, same container', () async {
      final f = FakeUpdate();
      final c = make(f);
      expect(await settle(c), isA<UpdateIdle>());
      final live = notifier(c);

      f.offer(108);
      await live.recheck();

      expect(
        identical(notifier(c), live),
        isTrue,
        reason: 'rebuilt, not rechecked',
      );
      expect(f.checks, 2);
      final s = now(c);
      expect(s, isA<UpdateAvailableFlexible>());
      expect((s as UpdateAvailableFlexible).versionCode, 108);
    });

    test('a newer offer replaces an older one', () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      f.offer(109);
      await notifier(c).recheck();
      expect((now(c) as UpdateAvailableFlexible).versionCode, 109);
    });

    test(
      'dismissed, then resumed with the same build → offered again',
      () async {
        final f = FakeUpdate()..offer(107);
        final c = make(f);
        await settle(c);
        notifier(c).dismiss();
        expect(now(c), isA<UpdateIdle>());

        await notifier(c).recheck();
        final s = now(c);
        expect(s, isA<UpdateAvailableFlexible>());
        expect((s as UpdateAvailableFlexible).versionCode, 107);
      },
    );

    test('a minimum raised while running blocks on recheck', () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      f.min = const Ok(110);
      await notifier(c).recheck();
      final s = now(c);
      expect(s, isA<UpdateRequired>());
      expect((s as UpdateRequired).minimum, 110);
      expect(f.calls, isEmpty, reason: 'recheck must not start an update');
    });

    test('an offer withdrawn by Play goes back to idle', () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      f.play = const Ok(PlayUpdateCheck());
      await notifier(c).recheck();
      expect(now(c), isA<UpdateIdle>());
    });
  });

  group('downloaded in the background', () {
    for (final offered in [null, 107]) {
      test('on start → ready to install (offeredBuild: $offered)', () async {
        final f = FakeUpdate(
          play: Ok(PlayUpdateCheck(offeredBuild: offered, downloaded: true)),
        );
        expect(await settle(make(f)), isA<UpdateReadyToInstall>());
      });

      test('on resume → ready to install (offeredBuild: $offered)', () async {
        final f = FakeUpdate()..offer(107);
        final c = make(f);
        expect(await settle(c), isA<UpdateAvailableFlexible>());
        f.play = Ok(PlayUpdateCheck(offeredBuild: offered, downloaded: true));
        await c.read(updateControllerProvider.notifier).recheck();
        expect(
          c.read(updateControllerProvider).requireValue,
          isA<UpdateReadyToInstall>(),
        );
      });
    }

    test('ready on start → install completes the flexible update', () async {
      final f = FakeUpdate(
        play: const Ok(PlayUpdateCheck(offeredBuild: 107, downloaded: true)),
      );
      final c = make(f);
      await settle(c);
      await c.read(updateControllerProvider.notifier).install();
      expect(f.calls, ['complete']);
    });
  });

  group('below the minimum', () {
    test('recheck keeps required with no loading in between', () async {
      final f = FakeUpdate(min: const Ok(110));
      final c = make(f);
      expect(await settle(c), isA<UpdateRequired>());
      final seen = <AsyncValue<UpdateState>>[];
      c.listen(updateControllerProvider, (_, next) => seen.add(next));

      f.offer(111); // Play offering something must not unblock the app
      await c.read(updateControllerProvider.notifier).recheck();
      await Future<void>.delayed(Duration.zero);

      expect(
        c.read(updateControllerProvider).requireValue,
        isA<UpdateRequired>(),
      );
      for (final v in seen) {
        expect(v.isLoading, isFalse, reason: 'flicker: $v');
        expect(v.hasError, isFalse, reason: '$v');
        expect(v.value, isA<UpdateRequired>(), reason: 'flicker: $v');
      }
    });

    test('recheck and build never start an immediate update', () async {
      final f = FakeUpdate(min: const Ok(110));
      final c = make(f);
      await settle(c);
      await c.read(updateControllerProvider.notifier).recheck();
      await c.read(updateControllerProvider.notifier).recheck();
      expect(f.calls, isEmpty);

      await c.read(updateControllerProvider.notifier).updateNow();
      expect(f.calls, ['immediate']);
    });
  });

  test(
    'offered and downloaded paths never start an immediate update',
    () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      await c.read(updateControllerProvider.notifier).recheck();
      await c.read(updateControllerProvider.notifier).download();
      await c.read(updateControllerProvider.notifier).recheck();
      expect(f.calls, isNot(contains('immediate')));
    },
  );

  group('failures never block', () {
    test('Play check fails → idle, on start and on recheck', () async {
      final f = FakeUpdate(play: const Err(NetworkFailure('no Play')));
      final c = make(f);
      final seen = <AsyncValue<UpdateState>>[];
      c.listen(updateControllerProvider, (_, next) => seen.add(next));
      expect(await settle(c), isA<UpdateIdle>());

      await c.read(updateControllerProvider.notifier).recheck();
      expect(c.read(updateControllerProvider).requireValue, isA<UpdateIdle>());
      expect(seen.where((v) => v.hasError), isEmpty);
    });

    test('Play check starts failing after an offer → idle, no error', () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      f.play = const Err(NetworkFailure('no Play'));
      await c.read(updateControllerProvider.notifier).recheck();
      final v = c.read(updateControllerProvider);
      expect(v.hasError, isFalse);
      expect(v.requireValue, isA<UpdateIdle>());
    });

    test(
      'policy fails while allowed → minimum is 0, Play still offered',
      () async {
        final f = FakeUpdate(
          installed: 1,
          min: const Err(NetworkFailure('offline')),
        )..offer(107);
        final c = make(f);
        expect(await settle(c), isA<UpdateAvailableFlexible>());
        await c.read(updateControllerProvider.notifier).recheck();
        expect(
          c.read(updateControllerProvider).requireValue,
          isA<UpdateAvailableFlexible>(),
        );
      },
    );
  });

  test('a download in flight is left alone by recheck', () async {
    final f = FakeUpdate()..offer(107);
    final c = make(f);
    await settle(c);
    f.flexibleGate = Completer<void>();
    final download = c.read(updateControllerProvider.notifier).download();
    await Future<void>.delayed(Duration.zero);
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateDownloading>(),
    );

    f.offer(108); // Play still reports an offer while downloading
    await c.read(updateControllerProvider.notifier).recheck();
    await Future<void>.delayed(Duration.zero);
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateDownloading>(),
    );

    f.flexibleGate!.complete();
    await download;
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateReadyToInstall>(),
    );
  });

  test(
    'a download started while a recheck is in flight is left alone',
    () async {
      final f = FakeUpdate()..offer(107);
      final c = make(f);
      await settle(c);
      final n = c.read(updateControllerProvider.notifier);

      f.checkGate = Completer<void>(); // resume: Play has not answered yet
      final recheck = n.recheck();
      f.flexibleGate = Completer<void>();
      final download = n.download(); // the member taps Update meanwhile
      await Future<void>.delayed(Duration.zero);
      expect(
        c.read(updateControllerProvider).requireValue,
        isA<UpdateDownloading>(),
      );

      f.checkGate!.complete(); // Play answers: still offering 107
      await recheck;
      expect(
        c.read(updateControllerProvider).requireValue,
        isA<UpdateDownloading>(),
        reason: 'a stale re-check replaced the download in flight',
      );

      f.flexibleGate!.complete();
      await download;
      expect(
        c.read(updateControllerProvider).requireValue,
        isA<UpdateReadyToInstall>(),
      );
    },
  );
}
