// releaseNotesProvider, written from the contract: it watches the signed-in
// member and asks ReleaseNotesDelivery for that member's notes once per
// build; Ok(true) makes the chat list reload quietly so the SIS chat shows
// up; Ok(false) and Err change nothing and surface nothing. The delivery
// fake is this file's own and is never instantly done: a real call takes a
// round trip, and one may still be in flight while the app moves on.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/release_notes_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/release_notes.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

class DeliveryFake implements ReleaseNotesDelivery {
  /// Who was asked for, in order.
  final calls = <String>[];

  /// The next answer. Left null, calls stay in flight until [answer].
  Result<bool>? next = const Ok(true);
  final _pending = <Completer<Result<bool>>>[];

  void answer(Result<bool> r) {
    for (final c in _pending) {
      c.complete(r);
    }
    _pending.clear();
  }

  @override
  Future<Result<bool>> deliver(String userId) async {
    calls.add(userId);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final n = next;
    if (n != null) return n;
    final c = Completer<Result<bool>>();
    _pending.add(c);
    return c.future;
  }
}

const maya = Member(userId: 'u1', displayName: 'Maya');
const kai = Member(userId: 'u2', displayName: 'Kai');

Future<void> pumpEvents() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

({ProviderContainer c, ChatFake chat}) world(
  DeliveryFake delivery,
  FakeAuth auth,
) {
  final chat = ChatFake(latency: const Duration(milliseconds: 1));
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      runtimeConfigProvider.overrideWithValue(
        const RuntimeConfig(
          supabaseUrl: 'https://x.supabase.co',
          supabasePublishableKey: 'k',
          googleWebClientId: 'c',
        ),
      ),
      authRepositoryProvider.overrideWithValue(auth),
      chatRepositoryProvider.overrideWithValue(chat),
      releaseNotesDeliveryProvider.overrideWithValue(delivery),
    ],
  );
  return (c: c, chat: chat);
}

int listReads(ChatFake chat) =>
    chat.calls.where((c) => c == 'conversations').length;

void main() {
  group('releaseNotesProvider', () {
    test('asks for the signed-in member\'s notes, once', () async {
      final delivery = DeliveryFake();
      final w = world(delivery, FakeAuth(session: true, member: maya));
      await settled(w.c);
      w.c.listen(releaseNotesProvider, (_, _) {});
      await pumpEvents();

      expect(delivery.calls, ['u1']);

      // Other rebuilds of unrelated providers do not ask again.
      w.c.read(conversationListProvider);
      await pumpEvents();
      expect(delivery.calls, ['u1']);
    });

    test(
      'asks for nobody while no one is signed in, then on first sign-in',
      () async {
        final delivery = DeliveryFake();
        final auth = FakeAuth(session: false, member: maya);
        final w = world(delivery, auth);
        await w.c.read(sessionControllerProvider.future);
        w.c.listen(releaseNotesProvider, (_, _) {});
        await pumpEvents();

        expect(delivery.calls, isEmpty, reason: 'no member yet');

        await w.c.read(sessionControllerProvider.notifier).signIn();
        await pumpEvents();

        expect(delivery.calls, ['u1']);
      },
    );

    test(
      'a different member signing in on the same phone is asked for too',
      () async {
        final delivery = DeliveryFake();
        final auth = FakeAuth(session: true, member: maya);
        final w = world(delivery, auth);
        await settled(w.c);
        w.c.listen(releaseNotesProvider, (_, _) {});
        await pumpEvents();

        await w.c.read(sessionControllerProvider.notifier).signOut();
        await pumpEvents();
        auth.member = kai;
        await w.c.read(sessionControllerProvider.notifier).signIn();
        await pumpEvents();

        expect(delivery.calls, ['u1', 'u2']);
      },
    );

    test('Ok(true) reloads the chat list so the SIS chat appears', () async {
      final delivery = DeliveryFake()..next = null;
      final w = world(delivery, FakeAuth(session: true, member: maya));
      await settled(w.c);
      w.c.listen(conversationListProvider, (_, _) {});
      w.c.listen(releaseNotesProvider, (_, _) {});
      await pumpEvents();
      final before = listReads(w.chat);
      expect(before, greaterThan(0), reason: 'the list loaded');

      w.chat.conversationsResult = const Ok([
        Conversation(id: 's1', isSystem: true, lastMessage: 'New: notes'),
      ]);
      delivery.answer(const Ok(true));
      await pumpEvents();

      expect(listReads(w.chat), before + 1);
      final list = w.c.read(conversationListProvider).value;
      expect(list?.map((c) => c.id), contains('s1'));
      expect(
        w.c.read(conversationListProvider).isLoading,
        isFalse,
        reason: 'quietly: the list never goes back to loading',
      );
    });

    for (final (name, r) in [
      ('Ok(false) (skipped)', const Ok(false) as Result<bool>),
      ('Err (failed)', const Err<bool>(NetworkFailure('offline'))),
    ]) {
      test('$name leaves the list alone and raises nothing', () async {
        final delivery = DeliveryFake()..next = null;
        final w = world(delivery, FakeAuth(session: true, member: maya));
        await settled(w.c);
        w.c.listen(conversationListProvider, (_, _) {});
        w.c.listen(releaseNotesProvider, (_, _) {});
        await pumpEvents();
        final before = listReads(w.chat);

        delivery.answer(r);
        await pumpEvents();

        expect(listReads(w.chat), before);
        expect(w.c.read(conversationListProvider).hasError, isFalse);
      });
    }

    test('after a failure, the next start asks again', () async {
      final delivery = DeliveryFake()
        ..next = const Err(NetworkFailure('offline'));
      final first = world(delivery, FakeAuth(session: true, member: maya));
      await settled(first.c);
      first.c.listen(releaseNotesProvider, (_, _) {});
      await pumpEvents();
      first.c.dispose();

      delivery.next = const Ok(true);
      final second = world(delivery, FakeAuth(session: true, member: maya));
      await settled(second.c);
      second.c.listen(releaseNotesProvider, (_, _) {});
      await pumpEvents();

      expect(delivery.calls, ['u1', 'u1']);
    });
  });

  group('mounted in SisApp', () {
    const config = RuntimeConfig(
      supabaseUrl: 'https://x.supabase.co',
      supabasePublishableKey: 'k',
      googleWebClientId: 'c',
    );

    Widget app(DeliveryFake delivery, {RuntimeConfig cfg = config}) =>
        ProviderScope(
          overrides: [
            ...videoOverrides(),
            runtimeConfigProvider.overrideWithValue(cfg),
            authRepositoryProvider.overrideWithValue(
              FakeAuth(session: true, member: maya),
            ),
            updateRepositoryProvider.overrideWithValue(FakeUpdate()),
            chatRepositoryProvider.overrideWithValue(ChatFake()),
            presenceRepositoryProvider.overrideWithValue(PresenceFake()),
            profileRepositoryProvider.overrideWithValue(
              ProfileFake(
                profile: const OwnProfile(
                  userId: 'u1',
                  displayName: 'Maya',
                  tag: 'maya',
                  onboardingDone: true,
                ),
              ),
            ),
            pushSourceProvider.overrideWithValue(PushSourceFake()),
            pushRegistryProvider.overrideWithValue(PushRegistryFake()),
            releaseNotesDeliveryProvider.overrideWithValue(delivery),
          ],
          child: const SisApp(),
        );

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('the app asks once at start and reaches home while the call '
        'is still in flight', (t) async {
      final delivery = DeliveryFake()..next = null;
      await t.pumpWidget(app(delivery));
      await settle(t);

      expect(find.text('New chat'), findsOneWidget, reason: 'home is open');
      expect(delivery.calls, ['u1']);
      delivery.answer(const Ok(false));
      await settle(t);
    });

    testWidgets('a failed delivery shows nothing to the member', (t) async {
      final delivery = DeliveryFake()
        ..next = const Err(NetworkFailure('No connection'));
      await t.pumpWidget(app(delivery));
      await settle(t);

      expect(find.text('New chat'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('No connection'), findsNothing);
    });

    testWidgets('SetupRequired never asks', (t) async {
      final delivery = DeliveryFake();
      await t.pumpWidget(
        app(
          delivery,
          cfg: const RuntimeConfig(
            supabaseUrl: '',
            supabasePublishableKey: '',
            googleWebClientId: '',
          ),
        ),
      );
      await settle(t);

      expect(delivery.calls, isEmpty);
    });
  });
}
