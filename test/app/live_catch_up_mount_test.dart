// liveCatchUpProvider is watched by the app as main.dart mounts it (SisApp in
// a ProviderScope): a Realtime re-join or a foreground push reaches the store
// sync with no screen of its own listening (fix "new messages appear at
// once", t_50655c1325). Only storeSyncProvider is replaced by a counter;
// the re-join and push streams are fed as main.dart feeds them.
import 'dart:async';

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
import 'package:sis/features/notifications/application/push_controller.dart';
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
final _rejoined = StreamController<void>.broadcast();
final _pushed = StreamController<String>.broadcast();

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
  realtimeRejoinedProvider.overrideWithValue(_rejoined.stream),
  foregroundPushProvider.overrideWithValue(_pushed.stream),
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

  testWidgets('a re-join after the cold start runs one more store sync', (
    t,
  ) async {
    await _mount(t, const Allowed(_member));
    final after = _runs;
    _rejoined.add(null);
    await t.pump();
    await t.pump();
    expect(_runs, after + 1);
    await _end(t);
  });

  testWidgets('a foreground push for a chat not open runs a store sync', (
    t,
  ) async {
    await _mount(t, const Allowed(_member));
    final after = _runs;
    _pushed.add('c-other');
    await t.pump();
    await t.pump();
    expect(_runs, after + 1);
    await _end(t);
  });
}
