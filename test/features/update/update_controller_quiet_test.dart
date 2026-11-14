import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_repository.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_entry_provider.dart';

import '../../support/fakes.dart';
import '../../features/admin_panels/application/admin_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<UpdateState> settle(ProviderContainer c) async {
  await c.read(sessionControllerProvider.future);
  await Future<void>.delayed(Duration.zero);
  return c.read(updateControllerProvider.future);
}

ProviderContainer makeWith(
  FakeUpdate f,
  FakeAdminRepository a, {
  bool signedIn = true,
}) => ProviderContainer.test(
  overrides: [
    runtimeConfigProvider.overrideWithValue(config),
    authRepositoryProvider.overrideWithValue(FakeAuth(session: signedIn)),
    updateRepositoryProvider.overrideWithValue(f),
    adminPanelsRepositoryProvider.overrideWithValue(a),
  ],
);

void main() {
  test('quiet offer (priority 0) + access → flexible available', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 0)),
    );
    final a = FakeAdminRepository();
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateAvailableFlexible>());
    expect((s as UpdateAvailableFlexible).versionCode, 107);
  });

  test('quiet offer (priority 1) + access → flexible available', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 1)),
    );
    final a = FakeAdminRepository();
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateAvailableFlexible>());
    expect((s as UpdateAvailableFlexible).versionCode, 107);
  });

  test('quiet offer + no access → idle', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 0)),
    );
    final a = FakeAdminRepository()..statusResult = const Ok(null);
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateIdle>());
  });

  test('quiet offer + admin error → idle', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 0)),
    );
    final a = FakeAdminRepository()
      ..statusResult = const Err(NetworkFailure('offline'));
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateIdle>());
  });

  test('normal offer (priority 2) + no access → flexible available, admin not read', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 2)),
    );
    final a = FakeAdminRepository()..statusResult = const Ok(null);
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateAvailableFlexible>());
    expect(a.statusCalls, 0);
  });

  test('default priority (no updatePriority) + admin error → flexible available, admin not read', () async {
    final f = FakeUpdate(play: const Ok(PlayUpdateCheck(offeredBuild: 107)));
    final a = FakeAdminRepository()
      ..statusResult = const Err(NetworkFailure('offline'));
    final c = makeWith(f, a);
    final s = await settle(c);
    expect(s, isA<UpdateAvailableFlexible>());
    expect(a.statusCalls, 0);
  });

  test(
    'high priority (5) + no access → flexible available, admin not read',
    () async {
      final f = FakeUpdate(
        play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 5)),
      );
      final a = FakeAdminRepository()..statusResult = const Ok(null);
      final c = makeWith(f, a);
      final s = await settle(c);
      expect(s, isA<UpdateAvailableFlexible>());
      expect(a.statusCalls, 0);
    },
  );

  test('quiet offer → admin status called once', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 0)),
    );
    final a = FakeAdminRepository();
    final c = makeWith(f, a);
    await settle(c);
    expect(a.statusCalls, 1);
  });

  test('quiet offer + admin check throws → idle', () async {
    final f = FakeUpdate(
      play: const Ok(PlayUpdateCheck(offeredBuild: 107, updatePriority: 0)),
    );
    final c = ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
        updateRepositoryProvider.overrideWithValue(f),
        adminEntryProvider.overrideWith(
          (ref) async => throw StateError('boom'),
        ),
      ],
    );
    expect(await settle(c), isA<UpdateIdle>());
  });
}
