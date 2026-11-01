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
  test('successful Apple sign‑in → Allowed via auth change', () async {
    final fake = FakeAuth();
    fake.appleResult = const Ok(null);
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signInWithApple();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<Allowed>());
    final allowed = state as Allowed;
    expect(allowed.member.displayName, 'Maya');
    expect(fake.appleCalls, 1);
  });

  test('Apple sign‑in denied → Denied', () async {
    final fake = FakeAuth();
    fake.appleResult = Err(DeniedFailure());
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signInWithApple();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<Denied>());
    expect(fake.appleCalls, 1);
  });

  test(
    'Apple sign‑in hidden email → SignedOut with hiddenEmail true',
    () async {
      final fake = FakeAuth();
      fake.appleResult = Err(HiddenEmailFailure());
      final c = make(fake);
      await settle(c);
      await c.read(sessionControllerProvider.notifier).signInWithApple();
      await Future<void>.delayed(Duration.zero);
      final state = c.read(sessionControllerProvider).requireValue;
      expect(state, isA<SignedOut>());
      final signedOut = state as SignedOut;
      expect(signedOut.hiddenEmail, true);
      expect(fake.appleCalls, 1);
    },
  );

  test('Apple sign‑in cancelled → SignedOut with hiddenEmail false', () async {
    final fake = FakeAuth();
    fake.appleResult = Err(
      ProviderFailure('Sign-in canceled.', userCanceled: true),
    );
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signInWithApple();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<SignedOut>());
    final signedOut = state as SignedOut;
    expect(signedOut.hiddenEmail, false);
    expect(fake.appleCalls, 1);
  });

  test('Apple sign‑in generic failure → SessionError', () async {
    final fake = FakeAuth();
    fake.appleResult = Err(ProviderFailure('Could not sign in. Try again.'));
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signInWithApple();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<SessionError>());
    final err = state as SessionError;
    expect(err.reason, 'Could not sign in. Try again.');
    expect(fake.appleCalls, 1);
  });

  test('Apple sign‑in does not trigger Google sign‑in', () async {
    final fake = FakeAuth();
    fake.signInResult = Err(ProviderFailure('google-should-not-run'));
    fake.appleResult = const Ok(null);
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signInWithApple();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<Allowed>());
    expect(fake.appleCalls, 1);
  });

  test('Google sign‑in unaffected by Apple result', () async {
    final fake = FakeAuth();
    fake.appleResult = Err(DeniedFailure());
    fake.signInResult = const Ok(null);
    final c = make(fake);
    await settle(c);
    await c.read(sessionControllerProvider.notifier).signIn();
    await Future<void>.delayed(Duration.zero);
    final state = c.read(sessionControllerProvider).requireValue;
    expect(state, isA<Allowed>());
    expect(fake.appleCalls, 0);
  });
}
