import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
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
    final s = await settle(make(FakeUpdate(play: const Ok(107))));
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
    final f = FakeUpdate(play: const Ok(107))..failFlexible = true;
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
    final c = make(FakeUpdate(play: const Ok(107)));
    await settle(c);
    c.read(updateControllerProvider.notifier).dismiss();
    expect(c.read(updateControllerProvider).requireValue, isA<UpdateIdle>());
  });

  test('download → downloading then ready', () async {
    final f = FakeUpdate(play: const Ok(107));
    final c = make(f);
    await settle(c);
    await c.read(updateControllerProvider.notifier).download();
    expect(
      c.read(updateControllerProvider).requireValue,
      isA<UpdateReadyToInstall>(),
    );
    expect(f.calls, ['flexible']);
  });
}
