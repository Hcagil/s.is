// PushRegistration and openedFromNotificationProvider against fakes written
// from the PushSource/PushRegistry contract (lib/features/notifications/domain
// /push.dart). The SDK (Firebase Messaging, the Supabase RPCs) is never here:
// the seam to the RPCs is test/integration/push_registry_integration_test.dart,
// and FirebasePushSource is a thin platform wrapper verified on a device
// (ARCHITECTURE rule 4).
//
// Time is the test binding's fake clock; flush() drains the fakes' async hops
// deterministically, the way the rest of this suite does.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/notifications/application/push_controller.dart';

import '../../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

ProviderContainer make(
  FakeAuth auth,
  PushSourceFake source,
  PushRegistryFake registry,
) => ProviderContainer.test(
  overrides: [
    runtimeConfigProvider.overrideWithValue(config),
    authRepositoryProvider.overrideWithValue(auth),
    pushSourceProvider.overrideWithValue(source),
    pushRegistryProvider.overrideWithValue(registry),
  ],
);

/// Lets the fakes' async hops and the controller's reactions run, the way the
/// presence controller tests drain theirs.
Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(Duration.zero);
  }
}

/// Awaits [call] while pumping the test's fake clock: FakeAuth's sign-in and
/// sign-out both cross a real `Future.delayed`, which never fires under
/// AutomatedTestWidgetsFlutterBinding without an explicit pump.
Future<void> run(WidgetTester t, Future<void> call) async {
  var done = false;
  call.whenComplete(() => done = true).ignore();
  for (var i = 0; i < 200 && !done; i++) {
    await t.pump(Duration.zero);
  }
  expect(done, isTrue, reason: 'the call never completed');
  await call;
  await flush(t);
}

/// Signs [auth] in, waits for the session to settle, and keeps
/// [pushRegistrationProvider] alive the way HomeScreen does.
Future<ProviderContainer> signedIn(
  WidgetTester t,
  FakeAuth auth,
  PushSourceFake source,
  PushRegistryFake registry,
) async {
  final c = make(auth, source, registry);
  c.listen(sessionControllerProvider, (_, _) {});
  await c.read(sessionControllerProvider.future);
  c.listen(pushRegistrationProvider, (_, _) {});
  await flush(t);
  return c;
}

void main() {
  group('build', () {
    testWidgets('while signed in it asks permission, gets the token and '
        'registers it', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      expect(source.permissionRequests, 1);
      expect(registry.registered, ['device-token-1']);
      expect(c.read(pushRegistrationProvider), 'device-token-1');
    });

    testWidgets('nothing is asked while signed out', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = make(FakeAuth(), source, registry);
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      expect(source.permissionRequests, 0);
      expect(registry.registered, isEmpty);
      expect(c.read(pushRegistrationProvider), isNull);
    });

    testWidgets('registers even when permission is refused -- asking again '
        'must not nag', (t) async {
      final source = PushSourceFake(permissionGranted: false);
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      expect(source.permissionRequests, 1);
      expect(registry.registered, ['device-token-1']);
      expect(c.read(pushRegistrationProvider), 'device-token-1');
    });

    testWidgets('nothing is registered when the platform has no token yet', (
      t,
    ) async {
      final source = PushSourceFake(token: null);
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      expect(registry.registered, isEmpty);
      expect(c.read(pushRegistrationProvider), isNull);
    });

    testWidgets('a failed registration leaves state unchanged and shows '
        'nothing', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake()
        ..registerResult = const Err(NetworkFailure('offline'));
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      expect(registry.calls, ['register:device-token-1']);
      expect(registry.registered, isEmpty, reason: 'the server refused it');
      expect(
        c.read(pushRegistrationProvider),
        isNull,
        reason: 'a failed registration must not be shown as registered',
      );
    });

    testWidgets('registers every token refresh', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);
      expect(registry.registered, ['device-token-1']);

      source.refreshToken('device-token-2');
      await flush(t);

      expect(registry.registered, ['device-token-1', 'device-token-2']);
      expect(c.read(pushRegistrationProvider), 'device-token-2');
    });

    testWidgets('a token refresh that the server refuses leaves the previous '
        'token as the registered state', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);
      expect(c.read(pushRegistrationProvider), 'device-token-1');

      registry.registerResult = const Err(NetworkFailure('offline'));
      source.refreshToken('device-token-2');
      await flush(t);

      expect(
        c.read(pushRegistrationProvider),
        'device-token-1',
        reason: 'a failed refresh registration must not overwrite the state',
      );
    });

    testWidgets('switching account registers again for the next one', (
      t,
    ) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = FakeAuth(
        session: true,
        member: const Member(userId: 'u1', displayName: 'Maya'),
      );
      final c = await signedIn(t, auth, source, registry);
      expect(registry.registered, ['device-token-1']);
      expect(c.read(pushRegistrationProvider), 'device-token-1');

      await run(t, c.read(sessionControllerProvider.notifier).signOut());
      expect(
        c.read(pushRegistrationProvider),
        isNull,
        reason: 'not shown as registered while signed out',
      );

      auth.member = const Member(userId: 'u2', displayName: 'Noor');
      await run(t, c.read(sessionControllerProvider.notifier).signIn());

      expect(registry.registered, [
        'device-token-1',
        'device-token-1',
      ], reason: 'must register again for the new account');
      expect(c.read(pushRegistrationProvider), 'device-token-1');
    });
  });

  group('forget', () {
    testWidgets('forgets the last registered token', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      await run(t, c.read(pushRegistrationProvider.notifier).forget());

      expect(registry.forgotten, ['device-token-1']);
    });

    testWidgets("forgets the source's current token when nothing was "
        'registered yet', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake()
        ..registerResult = const Err(NetworkFailure('offline'));
      final c = await signedIn(t, FakeAuth(session: true), source, registry);
      expect(
        c.read(pushRegistrationProvider),
        isNull,
        reason: 'setup: registration must have failed',
      );

      await run(t, c.read(pushRegistrationProvider.notifier).forget());

      expect(registry.forgotten, ['device-token-1']);
    });

    testWidgets('nothing is forgotten when the platform has no token', (
      t,
    ) async {
      final source = PushSourceFake(token: null);
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      await run(t, c.read(pushRegistrationProvider.notifier).forget());

      expect(registry.forgotten, isEmpty);
    });
  });

  group('openedFromNotificationProvider', () {
    testWidgets('emits the launch conversation first, then each tapped one', (
      t,
    ) async {
      final source = PushSourceFake(launchConversationId: 'c-launch');
      final c = ProviderContainer.test(
        overrides: [pushSourceProvider.overrideWithValue(source)],
      );
      final seen = <String>[];
      c.listen(openedFromNotificationProvider, (_, next) {
        if (next case AsyncData(:final value)) seen.add(value);
      });
      await flush(t);
      expect(seen, ['c-launch']);

      source.openConversation('c-tapped-1');
      await flush(t);
      source.openConversation('c-tapped-2');
      await flush(t);

      expect(seen, ['c-launch', 'c-tapped-1', 'c-tapped-2']);
    });

    testWidgets('emits nothing for a cold start no notification opened', (
      t,
    ) async {
      final source = PushSourceFake();
      final c = ProviderContainer.test(
        overrides: [pushSourceProvider.overrideWithValue(source)],
      );
      final seen = <String>[];
      c.listen(openedFromNotificationProvider, (_, next) {
        if (next case AsyncData(:final value)) seen.add(value);
      });
      await flush(t);
      expect(seen, isEmpty);

      source.openConversation('c-tapped');
      await flush(t);
      expect(seen, ['c-tapped']);
    });
  });
}
