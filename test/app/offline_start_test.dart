// Offline cold start never shows raw plugin text (0.30.16), from the
// contract:
//
// - failureReason(error): a Failure's own message; anything else
//   (PlatformException, Exception, String, ...) is 'Something went wrong.
//   Try again.', never the raw text.
// - SessionGate's AsyncError, the own-profile AsyncError and the chat
//   list's error box all go through it.
// - An error on AuthRepository.signedInChanges leaves SessionController's
//   state as it was: no error state, nothing unhandled.
//
// The defect (owner, 0.30.14): a cold start in airplane mode showed "check
// that Google Play is enabled..." instead of the stored chats.
//
// Offline cold start with a valid marker (Allowed(confirmed: false), the
// stored list, sessionCheckFailedProvider true once activateSession fails)
// is covered already: cold_start_session_test.dart 'an unreachable server',
// chat_list_snapshot_controller_test.dart 'cold start, a retryable
// NetworkFailure: the stored list', and on the real stack
// cold_start_session_integration_test.dart 'revoked while the phone was
// offline'.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

const _generic = 'Something went wrong. Try again.';

/// What the Google Sign-In / Play Services plugin throws offline.
final _raw = PlatformException(
  code: 'network_error',
  message: 'Check that Google Play is enabled and the network is reachable',
);

final _play = find.textContaining('Google Play', findRichText: true);
final _genericText = find.textContaining(_generic, findRichText: true);

class _ThrowingSession extends SessionController {
  @override
  Future<SessionState> build() async => throw _raw;
}

class _ThrowingProfile extends ProfileFake {
  _ThrowingProfile()
    : super(
        profile: const OwnProfile(
          userId: 'u1',
          displayName: 'Maya',
          tag: 'maya',
          onboardingDone: false,
        ),
      );

  @override
  Future<Result<OwnProfile>> load() async => throw _raw;
}

class _FailingProfile extends ProfileFake {
  _FailingProfile()
    : super(
        profile: const OwnProfile(
          userId: 'u1',
          displayName: 'Maya',
          tag: 'maya',
          onboardingDone: false,
        ),
      );

  @override
  Future<Result<OwnProfile>> load() async =>
      const Err(NetworkFailure('No connection'));
}

class _ThrowingList extends ConversationListController {
  @override
  Future<List<Conversation>> build() async => throw _raw;
}

Widget _app(FakeAuth a, {ProfileFake? p, List<Override> more = const []}) =>
    ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(a),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(FakeChat()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        profileRepositoryProvider.overrideWithValue(p ?? ProfileFake()),
        ...more,
      ],
      child: const SisApp(),
    );

void main() {
  group('failureReason', () {
    test("a Failure: its own message", () {
      expect(
        failureReason(const NetworkFailure('No connection')),
        'No connection',
      );
      expect(failureReason(const DeniedFailure()), 'Not allowed');
    });

    for (final (name, error) in <(String, Object)>[
      ('a PlatformException', _raw),
      ('an Exception', Exception('Google Play services missing')),
      ('a String', 'Google Play raw text'),
      ('an Error', StateError('Google Play state')),
    ]) {
      test('$name: the generic words, never its text', () {
        final r = failureReason(error);
        expect(r, _generic);
        expect(r, isNot(contains('Google Play')));
      });
    }
  });

  group('no raw plugin text on screen', () {
    testWidgets('SessionGate: a session that throws a PlatformException', (
      t,
    ) async {
      await t.pumpWidget(
        _app(
          FakeAuth(session: true),
          more: [sessionControllerProvider.overrideWith(_ThrowingSession.new)],
        ),
      );
      await t.pumpAndSettle();
      expect(_play, findsNothing);
      expect(_genericText, findsOneWidget);
    });

    testWidgets('the own profile failing with a PlatformException', (t) async {
      await t.pumpWidget(_app(FakeAuth(session: true), p: _ThrowingProfile()));
      await t.pumpAndSettle();
      expect(_play, findsNothing);
      expect(_genericText, findsOneWidget);
    });

    for (final (name, profile, shown) in [
      ('a PlatformException', _ThrowingProfile(), _generic),
      ('a Failure', _FailingProfile(), 'No connection'),
    ]) {
      testWidgets('the settings screen, the profile failing with $name', (
        t,
      ) async {
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              runtimeConfigProvider.overrideWithValue(config),
              authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
              updateRepositoryProvider.overrideWithValue(FakeUpdate()),
              chatRepositoryProvider.overrideWithValue(FakeChat()),
              presenceRepositoryProvider.overrideWithValue(PresenceFake()),
              profileRepositoryProvider.overrideWithValue(profile),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );
        await t.pumpAndSettle();
        expect(_play, findsNothing);
        expect(find.text(shown), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
      });
    }

    testWidgets('the chat list failing with a PlatformException', (t) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            chatRepositoryProvider.overrideWithValue(FakeChat()),
            conversationListProvider.overrideWith(_ThrowingList.new),
          ],
          child: const MaterialApp(home: ConversationList()),
        ),
      );
      await t.pumpAndSettle();
      expect(_play, findsNothing);
      expect(_genericText, findsOneWidget);
      expect(failureReason(_raw), _generic);
    });
  });

  group('signedInChanges', () {
    test('an error on the stream leaves the session state as it was', () async {
      final a = FakeAuth(session: true);
      final c = ProviderContainer.test(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(a),
        ],
      );
      final states = <AsyncValue<SessionState>>[];
      c.listen(sessionControllerProvider, (_, next) => states.add(next));
      final before = await c.read(sessionControllerProvider.future);
      expect(before, isA<Allowed>(), reason: 'fixture');
      final seen = states.length;

      a.changes.addError(_raw);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final now = c.read(sessionControllerProvider);
      expect(now.hasError, isFalse);
      expect(now.value, before);
      expect(states.sublist(seen).where((s) => s.hasError), isEmpty);
      c.dispose();
    });
  });
}
