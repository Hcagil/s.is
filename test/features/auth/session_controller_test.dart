import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
ProviderContainer make(FakeAuth fake, {RuntimeConfig cfg = config}) =>
    ProviderContainer.test(
      overrides: [
        authRepositoryProvider.overrideWithValue(fake),
        runtimeConfigProvider.overrideWithValue(cfg),
      ],
    );
Future<SessionState> settle(ProviderContainer c) async {
  await c.read(sessionControllerProvider.future);
  await Future<void>.delayed(Duration.zero);
  return c.read(sessionControllerProvider).requireValue;
}

void main() {
  test('incomplete config → SetupRequired', () async {
    final c = make(
      FakeAuth(),
      cfg: const RuntimeConfig(
        supabaseUrl: '',
        supabasePublishableKey: '',
        googleWebClientId: '',
      ),
    );
    expect(await settle(c), isA<SetupRequired>());
  });
  test('existing allowed session → Allowed with member', () async {
    final s = await settle(make(FakeAuth(session: true)));
    expect(s, isA<Allowed>());
    expect((s as Allowed).member.displayName, 'Maya');
  });
  test('existing session but not allowlisted → Denied', () async {
    expect(
      await settle(make(FakeAuth(session: true, allowed: false))),
      isA<Denied>(),
    );
  });
  test('sign-in canceled → SignedOut with reason', () async {
    final c = make(
      FakeAuth(
        signInResult: const Err(
          ProviderFailure(
            'Google sign-in canceled: developer console',
            userCanceled: true,
          ),
        ),
      ),
    );
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signIn();
    await Future<void>.delayed(Duration.zero);
    final s = c.read(sessionControllerProvider).requireValue;
    expect(s, isA<SignedOut>());
    expect((s as SignedOut).reason, contains('developer console'));
  });
  test('sign-in provider error → SessionError with reason', () async {
    final c = make(
      FakeAuth(
        signInResult: const Err(
          ProviderFailure('Supabase rejected the Google token: bad audience'),
        ),
      ),
    );
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signIn();
    await Future<void>.delayed(Duration.zero);
    expect(
      (c.read(sessionControllerProvider).requireValue as SessionError).reason,
      contains('bad audience'),
    );
  });
  test('successful sign-in → Allowed via auth change', () async {
    final fake = FakeAuth();
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signIn();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(sessionControllerProvider).requireValue, isA<Allowed>());
  });
  test('sign-out → SignedOut without reason', () async {
    final fake = FakeAuth(session: true);
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signOut();
    await Future<void>.delayed(Duration.zero);
    expect(
      (c.read(sessionControllerProvider).requireValue as SignedOut).reason,
      isNull,
    );
  });
}
