// removed_tester_state_test.dart
// Test the controller's state transitions when the server answers
// NotAllowedFailure or a network failure while a marker is stored.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../support/last_session_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

final _rigs = <ProviderContainer>[];

Future<void> end(WidgetTester t) async {
  for (final c in _rigs) {
    c.dispose();
  }
  _rigs.clear();
  await flush(t);
}

class Rig {
  Rig(this.auth, this.store)
    : c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(auth),
          lastSessionStoreProvider.overrideWithValue(store),
        ],
      ) {
    _rigs.add(c);
    c.listen(sessionControllerProvider, (_, next) {
      states.add(next);
    }, fireImmediately: true);
  }

  final ColdAuth auth;
  final MemoryLastSessionStore store;
  final ProviderContainer c;
  final states = <AsyncValue<SessionState>>[];

  SessionState? get state => c.read(sessionControllerProvider).value;
}

Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(Duration.zero);
  }
}

void main() {
  group('removed tester state', () {
    testWidgets('marker + NotAllowedFailure -> Removed', (t) async {
      final auth = ColdAuth();
      final r = Rig(auth, MemoryLastSessionStore(marker()));
      await flush(t);

      r.auth.last.fail(const NotAllowedFailure());
      await flush(t);

      expect(r.state, isA<Removed>());
      expect(r.store.stored, isNull);
      await end(t);
    });

    testWidgets('no marker + NotAllowedFailure -> Denied (not Removed)', (
      t,
    ) async {
      final auth = ColdAuth();
      final r = Rig(auth, MemoryLastSessionStore());
      await flush(t);

      r.auth.last.fail(const NotAllowedFailure());
      await flush(t);

      expect(r.state, isA<Denied>());
      expect(r.state, isNot(isA<Removed>()));
      await end(t);
    });

    testWidgets('marker + deny() -> Replaced (not Removed, not Denied)', (
      t,
    ) async {
      final auth = ColdAuth();
      final r = Rig(auth, MemoryLastSessionStore(marker()));
      await flush(t);

      r.auth.last.deny();
      await flush(t);

      expect(r.state, isA<Replaced>());
      expect(r.state, isNot(isA<Removed>()));
      expect(r.state, isNot(isA<Denied>()));
      await end(t);
    });

    testWidgets('marker + NetworkFailure -> not Removed and not Denied', (
      t,
    ) async {
      final auth = ColdAuth();
      final r = Rig(auth, MemoryLastSessionStore(marker()));
      await flush(t);

      r.auth.last.fail();
      await flush(t);

      expect(r.state, isNot(isA<Removed>()));
      expect(r.state, isNot(isA<Denied>()));
      // The controller keeps the optimistic Allowed state in this case.
      expect(r.state, isA<Allowed>());
      await end(t);
    });

    // 5 'confirmed phone, later NotAllowedFailure on recheck -> Removed and marker wiped'
    testWidgets(
      'confirmed phone, later NotAllowedFailure on recheck -> Removed and marker wiped',
      (t) async {
        final auth = ColdAuth();
        final r = Rig(auth, MemoryLastSessionStore(marker()));
        await flush(t);

        r.auth.last.allow();
        await flush(t);
        expect(r.state, isA<Allowed>());

        // Trigger recheck
        r.c.read(sessionControllerProvider.notifier).recheck();
        await flush(t);

        r.auth.last.fail(const NotAllowedFailure());
        await flush(t);

        expect(r.state, isA<Removed>());
        expect(r.store.stored, isNull);
        await end(t);
      },
    );

    // 6 'marker of another session id of the same account -> gated path, NotAllowedFailure -> Removed'
    testWidgets(
      'marker of another session id of the same account -> gated path, NotAllowedFailure -> Removed',
      (t) async {
        final auth = ColdAuth(sid: 'sess-2');
        final r = Rig(auth, MemoryLastSessionStore(marker()));
        await flush(t);

        r.auth.last.fail(const NotAllowedFailure());
        await flush(t);

        expect(r.state, isA<Removed>());
        await end(t);
      },
    );

    // 7 'marker of ANOTHER account -> gated path, NotAllowedFailure -> Denied, not Removed'
    testWidgets(
      'marker of ANOTHER account -> gated path, NotAllowedFailure -> Denied, not Removed',
      (t) async {
        final auth = ColdAuth();
        final r = Rig(auth, MemoryLastSessionStore(marker(userId: 'u9')));
        await flush(t);

        r.auth.last.fail(const NotAllowedFailure());
        await flush(t);

        expect(r.state, isA<Denied>());
        expect(r.state, isNot(isA<Removed>()));
        await end(t);
      },
    );
  });
}
