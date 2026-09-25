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
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';

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
    testWidgets('while signed in it registers the token without asking for '
        'permission -- only the explainer asks', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      expect(
        source.permissionRequests,
        0,
        reason:
            'registration must never prompt: the one prompt comes after '
            'SIS\'s own explainer screen',
      );
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

    testWidgets('registers whatever token exists whatever the permission '
        'status -- and never asks', (t) async {
      for (final status in PushPermissionStatus.values) {
        final source = PushSourceFake(status: status, permissionGranted: false);
        final registry = PushRegistryFake();
        final c = await signedIn(t, FakeAuth(session: true), source, registry);

        expect(source.permissionRequests, 0, reason: '$status');
        expect(registry.registered, ['device-token-1'], reason: '$status');
        expect(c.read(pushRegistrationProvider), 'device-token-1');
        c.dispose();
      }
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

  group('who is signed in reaches the push source', () {
    // PushSource.forUser: called on every change of member, null included,
    // so whatever a previous member left on the device is dropped before
    // the next one's pushes can arrive.

    testWidgets('a signed-in start tells it the member, before anything is '
        'registered for them', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      int? registeredAtForUser;
      source.onForUser = (_) => registeredAtForUser = registry.calls.length;

      await signedIn(t, FakeAuth(session: true), source, registry);

      expect(source.users, ['u1']);
      expect(
        registeredAtForUser,
        0,
        reason:
            'pushes for the member can arrive once the token is registered; '
            'what the previous member left must be gone before that',
      );
      expect(registry.registered, ['device-token-1']);
    });

    testWidgets('a signed-out start tells it nobody is signed in', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = make(FakeAuth(), source, registry);
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      expect(
        source.users,
        [null],
        reason:
            'signed out is a change of member too -- it must not be '
            'skipped along with registration',
      );
      expect(registry.calls, isEmpty);
    });

    testWidgets('a start on a session that is no longer approved (e.g. the '
        'phone was replaced) tells it nobody is signed in', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = make(FakeAuth(session: true, allowed: false), source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      expect(source.users, [null]);
      expect(registry.calls, isEmpty);
    });

    testWidgets('sign-out and the next member: nobody, then the next '
        'member, before their token is registered', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = FakeAuth(session: true);
      final c = await signedIn(t, auth, source, registry);
      expect(source.users, ['u1']);

      await run(t, c.read(sessionControllerProvider.notifier).signOut());
      expect(source.users, ['u1', null]);

      int? registeredAtForUser;
      source.onForUser = (_) => registeredAtForUser = registry.calls.length;
      auth.member = const Member(userId: 'u2', displayName: 'Noor');
      await run(t, c.read(sessionControllerProvider.notifier).signIn());

      expect(source.users, ['u1', null, 'u2']);
      expect(registeredAtForUser, 1, reason: 'only u1 was registered then');
      expect(registry.registered, ['device-token-1', 'device-token-1']);
    });

    testWidgets('a session the server ended (no sign-out call on this '
        'phone) tells it nobody is signed in', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = FakeAuth(session: true);
      final c = await signedIn(t, auth, source, registry);

      auth.session = false;
      auth.changes.add(false);
      await flush(t);

      expect(c.read(currentUserIdProvider), isNull, reason: 'precondition');
      expect(source.users, ['u1', null]);
      expect(auth.signOuts, 0);
    });
  });

  group('an unsettled session answer tells the push source nothing', () {
    // Only a settled answer says who owns the inbox. Loading, an error (an
    // offline start) and missing setup say nothing about who is signed in:
    // telling the source "nobody" then would wipe the member's own
    // notifications that arrived while the app was closed.

    testWidgets('an offline start (SessionError) calls forUser not at '
        'all', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = CheckingAuth(session: true)
        ..answer = const Err(NetworkFailure('offline'));
      final c = make(auth, source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      expect(
        c.read(sessionControllerProvider).value,
        isA<SessionError>(),
        reason: 'precondition',
      );
      expect(source.users, isEmpty);
      expect(registry.calls, isEmpty);
    });

    testWidgets('a signed-in member whose session check then fails keeps '
        'their inbox: no forUser(null)', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = CheckingAuth(session: true);
      final c = await signedIn(t, auth, source, registry);
      expect(source.users, ['u1']);

      auth.answer = const Err(NetworkFailure('offline'));
      c.read(sessionControllerProvider.notifier).retry().ignore();
      await flush(t);

      expect(
        c.read(sessionControllerProvider).value,
        isA<SessionError>(),
        reason: 'precondition',
      );
      expect(source.users, ['u1']);
    });

    testWidgets('while the session is still being checked: nothing; once '
        'it settles: the member', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = CheckingAuth(session: true)..hold();
      final c = make(auth, source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      final now = c.read(sessionControllerProvider);
      expect(
        now.isLoading || now.value is SessionLoading,
        isTrue,
        reason: 'precondition: still checking, got $now',
      );
      expect(source.users, isEmpty);

      auth.answerNow();
      await flush(t);

      expect(c.read(sessionControllerProvider).value, isA<Allowed>());
      expect(source.users, ['u1']);
    });

    testWidgets('signing in from signed out: nothing while it is checked, '
        'then the member', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final auth = CheckingAuth();
      final c = make(auth, source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);
      expect(source.users, [null]);

      auth.hold();
      final signIn = c.read(sessionControllerProvider.notifier).signIn();
      await flush(t);
      expect(source.users, [null], reason: 'nothing while being checked');

      auth.answerNow();
      await run(t, signIn);
      expect(source.users, [null, 'u1']);
    });

    testWidgets('missing setup (SetupRequired) calls forUser not at all', (
      t,
    ) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: '',
              supabasePublishableKey: '',
              googleWebClientId: '',
            ),
          ),
          authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
          pushSourceProvider.overrideWithValue(source),
          pushRegistryProvider.overrideWithValue(registry),
        ],
      );
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);

      expect(
        c.read(sessionControllerProvider).value,
        isA<SetupRequired>(),
        reason: 'precondition',
      );
      expect(source.users, isEmpty);
    });
  });

  group('the scope goes away mid-registration', () {
    testWidgets('while the token is being read: nothing is registered and '
        'nothing throws', (t) async {
      final source = PushSourceFake()..holdToken();
      final registry = PushRegistryFake();
      final c = make(FakeAuth(session: true), source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);
      expect(source.tokenReads, 1, reason: 'precondition: token in flight');

      c.dispose();
      source.releaseToken();
      await flush(t);

      expect(registry.calls, isEmpty);
      expect(t.takeException(), isNull);
    });

    testWidgets('while the server is registering the token: nothing '
        'throws', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake(latency: const Duration(seconds: 1));
      final c = make(FakeAuth(session: true), source, registry);
      c.listen(sessionControllerProvider, (_, _) {});
      await c.read(sessionControllerProvider.future);
      c.listen(pushRegistrationProvider, (_, _) {});
      await flush(t);
      expect(registry.calls, ['register:device-token-1'], reason: 'in flight');

      c.dispose();
      await t.pump(const Duration(seconds: 2));
      await flush(t);

      expect(t.takeException(), isNull);
    });
  });

  group('forget', () {
    testWidgets('forgets the last registered token', (t) async {
      final source = PushSourceFake();
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      registry.onForget = (_) => expect(
        source.clearAllCalls,
        0,
        reason: 'the shade must not be cleared before the token is forgotten',
      );

      await run(t, c.read(pushRegistrationProvider.notifier).forget());

      expect(registry.forgotten, ['device-token-1']);
      expect(source.clearAllCalls, 1);
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
      expect(source.clearAllCalls, 1);
    });

    testWidgets('nothing is forgotten when the platform has no token, but '
        'the shade is still cleared', (t) async {
      final source = PushSourceFake(token: null);
      final registry = PushRegistryFake();
      final c = await signedIn(t, FakeAuth(session: true), source, registry);

      await run(t, c.read(pushRegistrationProvider.notifier).forget());

      expect(registry.forgotten, isEmpty);
      expect(source.clearAllCalls, 1);
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
