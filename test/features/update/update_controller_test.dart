import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_state.dart';

import '../../support/fakes.dart';

ProviderContainer make(FakeUpdate f) => ProviderContainer.test(
  overrides: [updateRepositoryProvider.overrideWithValue(f)],
);

Future<UpdateState> settle(ProviderContainer c) =>
    c.read(updateControllerProvider.future);

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
