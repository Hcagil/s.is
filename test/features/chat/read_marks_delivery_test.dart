// ReadMarksController (readMarksProvider) with delivery marks (Update 1
// slice 5), against DeliveryChat -- never the SDK. Contract: read events and
// delivery events are merged into a member's mark FIELD BY FIELD (a delivery
// event carries only userId and deliveredAt, shares false), and each value
// only moves forward. A delivery that arrives while the read marks are still
// loading is not lost. Delivery does not depend on read-status sharing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/delivery_fakes.dart';
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

OwnProfile profile({bool shareReadStatus = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  shareReadStatus: shareReadStatus,
);

final t0 = DateTime.utc(2026, 9, 25, 10);
final t1 = t0.add(const Duration(minutes: 1));
final t2 = t0.add(const Duration(minutes: 2));

Future<ProviderContainer> ready(
  DeliveryChat chat, {
  bool sharing = true,
}) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      profileRepositoryProvider.overrideWithValue(
        ProfileFake(profile: profile(shareReadStatus: sharing)),
      ),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(ownProfileProvider, (_, _) {});
  await c.read(ownProfileProvider.future);
  return c;
}

Future<void> open(ProviderContainer c, String id) async {
  c.read(openConversationProvider.notifier).open(id);
  c.listen(readMarksProvider, (_, _) {});
  await c.read(readMarksProvider.future);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

/// (shares, readAt, deliveredAt) of [userId]'s mark, null when absent.
(bool, DateTime?, DateTime?)? of(ProviderContainer c, String userId) {
  final m = c
      .read(readMarksProvider)
      .value
      ?.where((m) => m.userId == userId)
      .firstOrNull;
  return m == null ? null : (m.shares, m.readAt, m.deliveredAt);
}

void main() {
  test('the load carries deliveredAt', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t1),
      ];
    final c = await ready(chat);
    await open(c, 'c1');
    expect(of(c, 'u2'), (true, t0, t1));
  });

  test('a delivery event moves only deliveredAt: shares and readAt kept, '
      'other members untouched', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t0),
        ReadMark(userId: 'u3', shares: true, readAt: t0, deliveredAt: t0),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverDelivery('c1', 'u2', t2);
    await settle();
    expect(of(c, 'u2'), (
      true,
      t0,
      t2,
    ), reason: 'the event (shares false, no readAt) replaced the whole mark');
    expect(of(c, 'u3'), (true, t0, t0));
  });

  test('a read event moves only readAt: deliveredAt kept', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t2),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    await settle();
    expect(of(c, 'u2'), (true, t1, t2), reason: 'the read dropped delivery');
  });

  test('an older delivery never moves deliveredAt back', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t2),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverDelivery('c1', 'u2', t1);
    await settle();
    expect(of(c, 'u2')?.$3, t2);
  });

  test('an older read never moves readAt back, and keeps delivery', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t2, deliveredAt: t2),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    await settle();
    expect(of(c, 'u2'), (true, t2, t2));
  });

  test('a delivery that arrives before the read marks load is kept', () async {
    final chat = DeliveryChat(latency: const Duration(milliseconds: 5))
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t0),
      ]
      ..holdReadMarks();
    final c = await ready(chat);
    c.read(openConversationProvider.notifier).open('c1');
    c.listen(readMarksProvider, (_, _) {});
    for (var i = 0; i < 100 && chat.deliveredSubscriptions == 0; i++) {
      await settle();
    }
    expect(
      chat.deliveredSubscriptions,
      1,
      reason: 'not subscribed to deliveries while the marks load',
    );

    chat.deliverDelivery('c1', 'u2', t2);
    await settle();
    chat.releaseReadMarks();
    await c.read(readMarksProvider.future);
    await settle();

    expect(of(c, 'u2'), (
      true,
      t0,
      t2,
    ), reason: 'the delivery made during the load was dropped or overwritten');
  });

  test(
    'a delivery subscription that cannot be made: the marks still load',
    () async {
      final chat = DeliveryChat()
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t1),
        ]
        ..deliveredUpdatesResult = const Err(NetworkFailure('no realtime'));
      final c = await ready(chat);
      await open(c, 'c1');
      expect(c.read(readMarksProvider).hasError, isFalse);
      expect(of(c, 'u2'), (true, t0, t1));

      chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
      await settle();
      expect(of(c, 'u2')?.$2, t1, reason: 'reads stopped with deliveries');
    },
  );

  test('with my read status off, deliveries still arrive', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: false, deliveredAt: t0),
      ];
    final c = await ready(chat, sharing: false);
    await open(c, 'c1');
    chat.deliverDelivery('c1', 'u2', t1);
    await settle();
    expect(of(c, 'u2'), (false, null, t1));
  });

  test('closing the conversation leaves the delivery channel', () async {
    final chat = DeliveryChat()..readMarksData['c1'] = const [];
    final c = await ready(chat);
    await open(c, 'c1');
    expect(chat.deliveredSubscriptions, 1);
    c.read(openConversationProvider.notifier).close();
    await settle();
    expect(chat.canceledDeliveredSubscriptions, 1);
  });

  test('a delivery join that hangs does not hold up the marks; once it '
      'answers, deliveries arrive', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t0),
      ]
      ..holdDeliveredSubscription();
    final c = await ready(chat);
    await open(c, 'c1').timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('the marks waited for the delivery join'),
    );
    expect(of(c, 'u2'), (true, t0, t0));

    chat.confirmDeliveredSubscription();
    await settle();
    chat.deliverDelivery('c1', 'u2', t1);
    await settle();
    expect(of(c, 'u2')?.$3, t1, reason: 'the late join was never listened to');
  });

  test('closed before the delivery join answers: the channel is left once '
      'it does, nothing stays joined', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = const []
      ..holdDeliveredSubscription();
    final c = await ready(chat);
    await open(c, 'c1').timeout(const Duration(seconds: 2));
    c.read(openConversationProvider.notifier).close();
    await settle();

    chat.confirmDeliveredSubscription();
    await settle();
    expect(
      chat.deliveredSubscriptions,
      1,
      reason: 'fixture: the join answered',
    );
    expect(
      chat.joinedDeliveryChannels,
      0,
      reason:
          'a join that answered after the close was never left '
          '(cancelled: ${chat.canceledDeliveredSubscriptions}, marks state: '
          '${c.read(readMarksProvider)})',
    );
  });

  test('switched to another chat before the delivery join answers: the first '
      "chat's deliveries never land in the second", () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t0),
      ]
      ..readMarksData['c2'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0, deliveredAt: t0),
      ]
      ..holdDeliveredSubscription();
    final c = await ready(chat);
    await open(c, 'c1').timeout(const Duration(seconds: 2));
    await open(c, 'c2').timeout(const Duration(seconds: 2));
    chat.confirmDeliveredSubscription();
    await settle();

    chat.deliverDelivery('c1', 'u2', t2);
    await settle();
    expect(
      of(c, 'u2')?.$3,
      t0,
      reason: "u2's delivery in c1 moved his tick in c2",
    );
  });

  test('the whole container disposed before the delivery join answers: '
      'nothing stays joined', () async {
    final chat = DeliveryChat()
      ..readMarksData['c1'] = const []
      ..holdDeliveredSubscription();
    final c = await ready(chat);
    await open(c, 'c1').timeout(const Duration(seconds: 2));
    c.dispose();
    chat.confirmDeliveredSubscription();
    await settle();
    expect(
      chat.deliveredSubscriptions,
      1,
      reason: 'fixture: the join answered',
    );
    expect(chat.joinedDeliveryChannels, 0);
  });
}
