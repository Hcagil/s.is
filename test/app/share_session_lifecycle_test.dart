// Share into SIS across sign-in changes. Written from the contract, not the code:
// - a pending share is finished (cleared, its files discarded) when the signed-in member
//   signs out, is Denied, or a different member signs in;
// - a share arriving before any sign-in is kept and shown after sign-in;
// - loading/refresh of the same member keeps it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/share_controller.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/shared_content.dart';
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

const _a = Member(userId: 'u1', displayName: 'Maya', tag: 'maya');
const _b = Member(userId: 'u2', displayName: 'Bo', tag: 'bo');

class _Session extends SessionController {
  _Session(this.first);
  final SessionState first;

  @override
  Future<SessionState> build() async => first;

  void put(SessionState s) => state = AsyncData(s);
  void loading() => state = const AsyncLoading<SessionState>();
}

/// The share door: one share waiting; every discard recorded.
class _Intake implements ShareIntake {
  _Intake(this.waiting);
  SharedContent? waiting;
  final discarded = <SharedContent>[];
  final arrived = StreamController<void>.broadcast();

  @override
  Future<SharedContent?> take() async {
    final c = waiting;
    waiting = null;
    return c;
  }

  @override
  Stream<void> get arrivals => arrived.stream;

  @override
  Future<PickedImage?> readPhoto(SharedItem item) async => null;

  @override
  Future<void> discard(SharedContent content) async => discarded.add(content);
}

void main() {
  late _Intake intake;
  late _Session session;

  Future<ProviderContainer> start(WidgetTester t, SessionState first) async {
    intake = _Intake(const SharedContent(text: 'shared hello'));
    session = _Session(first);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(_config),
          authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(FakeChat()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          profileRepositoryProvider.overrideWithValue(ProfileFake()),
          sessionControllerProvider.overrideWith(() => session),
          shareIntakeProvider.overrideWithValue(intake),
        ],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
    return ProviderScope.containerOf(t.element(find.byType(SisApp)));
  }

  final page = find.byKey(const ValueKey('forward-page'));

  for (final (name, next) in <(String, SessionState)>[
    ('signs out', const SignedOut()),
    ('is Denied', const Denied()),
    ('is replaced by another member', const Allowed(_b)),
  ]) {
    testWidgets('the share is finished when the member $name', (t) async {
      final c = await start(t, const Allowed(_a));
      expect(c.read(pendingShareProvider), isNotNull);
      expect(page, findsOneWidget);
      session.put(next);
      await t.pumpAndSettle();
      expect(c.read(pendingShareProvider), isNull);
      // Discarding is idempotent (files may already be gone); the contract does not say once.
      expect(intake.discarded, isNotEmpty);
      expect(intake.discarded.map((s) => s.text).toSet(), {'shared hello'});
    });
  }

  testWidgets('a share made while signed out is kept and shown after sign-in', (
    t,
  ) async {
    final c = await start(t, const SignedOut());
    expect(c.read(pendingShareProvider), isNotNull);
    expect(intake.discarded, isEmpty);
    session.put(const Allowed(_a));
    await t.pumpAndSettle();
    expect(intake.discarded, isEmpty);
    expect(c.read(pendingShareProvider)?.text, 'shared hello');
    expect(page, findsOneWidget);
  });

  testWidgets('loading and a refresh of the same member keep the share', (
    t,
  ) async {
    final c = await start(t, const Allowed(_a));
    session.loading();
    await t.pump();
    session.put(const SessionLoading());
    await t.pump();
    session.put(const Allowed(_a, confirmed: false));
    await t.pumpAndSettle();
    session.put(const Allowed(_a));
    await t.pumpAndSettle();
    expect(intake.discarded, isEmpty);
    expect(c.read(pendingShareProvider)?.text, 'shared hello');
    expect(page, findsOneWidget);
  });
}
