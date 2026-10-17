// The store catch-up hooks, from the Private Chats step 1 Group C contract:
// - cold start: SessionGate mounting with the session ALREADY Allowed runs
//   StoreSyncController.run once;
// - sign-in: the session becoming Allowed runs it once;
// - resume: coming back to the app (onShow) runs it through
//   resumeCatchUpProvider, and only for an Allowed session.
// The app is mounted as main.dart mounts it (SisApp in a ProviderScope); only
// storeSyncProvider is replaced by a counter.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/video_fakes.dart';

const _config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

var _runs = 0;

class _CountingSync extends StoreSyncController {
  _CountingSync(super.ref);
  @override
  Future<void> run() async => _runs++;
}

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void become(SessionState s) => state = AsyncData(s);
}

const _member = Member(userId: 'u1', displayName: 'Maya');

List<Override> _overrides(SessionState s) => [
  ...videoOverrides(),
  runtimeConfigProvider.overrideWithValue(_config),
  authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
  updateRepositoryProvider.overrideWithValue(FakeUpdate()),
  chatRepositoryProvider.overrideWithValue(FakeChat()),
  presenceRepositoryProvider.overrideWithValue(PresenceFake()),
  profileRepositoryProvider.overrideWithValue(ProfileFake()),
  sessionControllerProvider.overrideWith(() => _Session(s)),
  storeSyncProvider.overrideWith(_CountingSync.new),
];

/// The app over a container whose session has already settled to [s].
Future<ProviderContainer> _mount(WidgetTester t, SessionState s) async {
  final c = ProviderContainer(overrides: _overrides(s));
  addTearDown(c.dispose);
  await t.runAsync(() => c.read(sessionControllerProvider.future));
  expect(c.read(sessionControllerProvider).value, s, reason: 'fixture');
  await t.pumpWidget(
    UncontrolledProviderScope(container: c, child: const SisApp()),
  );
  await t.pump();
  await t.pump();
  return c;
}

/// Unmounts and lets the app's own timers (update check, presence, badge)
/// run out, so none is left pending.
Future<void> _end(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 5));
}

void main() {
  setUp(() => _runs = 0);

  testWidgets('cold start, already Allowed: one catch-up', (t) async {
    await _mount(t, const Allowed(_member));
    expect(_runs, 1);
    await t.pump(const Duration(seconds: 1));
    expect(_runs, 1, reason: 'once, not per frame');
    await _end(t);
  });

  testWidgets('cold start, signed out: no catch-up', (t) async {
    await _mount(t, const SignedOut());
    expect(_runs, 0);
    await _end(t);
  });

  testWidgets('sign-in: the session becoming Allowed runs one catch-up', (
    t,
  ) async {
    final c = await _mount(t, const SignedOut());
    (c.read(sessionControllerProvider.notifier) as _Session).become(
      const Allowed(_member),
    );
    await t.pump();
    await t.pump();
    expect(_runs, 1);
    await _end(t);
  });

  testWidgets('resume: coming back to the app runs a catch-up', (t) async {
    await _mount(t, const Allowed(_member));
    expect(_runs, 1, reason: 'cold start');
    final b = t.binding;
    b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    b.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(_runs, 1, reason: 'going away runs nothing');
    b.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    b.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    b.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(_runs, 2);
    await _end(t);
  });

  test('resumeCatchUpProvider: runs only for an Allowed session', () async {
    for (final (s, want) in <(SessionState, int)>[
      (const Allowed(_member), 1),
      (const SignedOut(), 0),
    ]) {
      _runs = 0;
      final c = ProviderContainer(overrides: _overrides(s));
      await c.read(sessionControllerProvider.future);
      c.read(resumeCatchUpProvider)();
      await Future<void>.delayed(Duration.zero);
      expect(_runs, want, reason: '$s');
      c.dispose();
    }
  });
}
