// ReadMarksController (readMarksProvider) against the shared fakes -- never
// the SDK. Written from the provider's contract: how far the OTHER members of
// the open conversation have read, live; empty when nothing is open; rebuilt
// when the member turns their own read status on or off.
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

/// The session and the own profile settled first, the order the app reaches
/// a conversation in.
Future<ProviderContainer> ready(ChatFake chat, {ProfileFake? profiles}) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      profileRepositoryProvider.overrideWithValue(
        profiles ?? ProfileFake(profile: profile()),
      ),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(ownProfileProvider, (_, _) {});
  await c.read(ownProfileProvider.future);
  return c;
}

Future<List<ReadMark>> open(ProviderContainer c, String id) async {
  c.read(openConversationProvider.notifier).open(id);
  c.listen(readMarksProvider, (_, _) {});
  return c.read(readMarksProvider.future);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

/// A mark as what it says; ReadMark promises no value equality.
List<(String, bool, DateTime?)> rows(List<ReadMark> marks) => [
  for (final m in marks) (m.userId, m.shares, m.readAt),
];

ReadMark? markOf(ProviderContainer c, String userId) => c
    .read(readMarksProvider)
    .value
    ?.where((m) => m.userId == userId)
    .firstOrNull;

void main() {
  test('no conversation open: empty, and the server is not asked', () async {
    final chat = ChatFake();
    final c = await ready(chat);
    c.listen(readMarksProvider, (_, _) {});

    expect(await c.read(readMarksProvider.future), isEmpty);
    expect(chat.readMarksCalls, isEmpty);
    expect(chat.readSubscriptions, 0);
  });

  test('opening a conversation loads its marks', () async {
    final chat = ChatFake()
      ..readMarksData['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)]
      ..readMarksData['c2'] = const [ReadMark(userId: 'u3', shares: false)];
    final c = await ready(chat);

    expect(rows(await open(c, 'c1')), [('u2', true, t0)]);
  });

  test('a read made while the first load is in flight is not lost', () async {
    // Realtime and the RPC race: the other member reads after the server
    // answered the load but before that answer arrives here.
    final chat = ChatFake(latency: const Duration(milliseconds: 5))
      ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)]
      ..holdReadMarks();
    final c = await ready(chat);
    c.read(openConversationProvider.notifier).open('c1');
    c.listen(readMarksProvider, (_, _) {});
    while (chat.readMarksCalls.isEmpty) {
      await settle();
    }

    final t1 = t0.add(const Duration(minutes: 1));
    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    chat.releaseReadMarks();
    await c.read(readMarksProvider.future);
    await settle();

    expect(
      markOf(c, 'u2')?.readAt,
      t1,
      reason: 'the read arrived during the load and was dropped',
    );
  });

  test("a live read replaces only that member's mark", () async {
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        const ReadMark(userId: 'u2', shares: true),
        ReadMark(userId: 'u3', shares: true, readAt: t0),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    final t1 = t0.add(const Duration(minutes: 5));
    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    await settle();

    expect(markOf(c, 'u2')?.readAt, t1);
    expect(markOf(c, 'u3')?.readAt, t0, reason: 'another mark moved');
    expect(c.read(readMarksProvider).requireValue, hasLength(2));
  });

  test('a late, older read never moves a mark backwards', () async {
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverRead(
      'c1',
      ReadMark(
        userId: 'u2',
        shares: true,
        readAt: t0.subtract(const Duration(minutes: 5)),
      ),
    );
    await settle();

    expect(markOf(c, 'u2')?.readAt, t0);
  });

  test('my own read, echoed back by the channel, is not a mark', () async {
    // mark_read broadcasts to every member of the topic, the reader
    // included. Counted as a mark, my own place would hold my own messages
    // grey in a group.
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0),
      ];
    final c = await ready(chat);
    await open(c, 'c1');

    chat.deliverRead(
      'c1',
      ReadMark(userId: me.userId, shares: true, readAt: t0),
    );
    await settle();

    expect(c.read(readMarksProvider).requireValue.map((m) => m.userId), ['u2']);
  });

  test(
    'a subscription that cannot be made still shows the loaded marks',
    () async {
      final chat = ChatFake()
        ..readUpdatesResult = const Err(NetworkFailure('offline'))
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
        ];
      final c = await ready(chat);

      expect(rows(await open(c, 'c1')), [('u2', true, t0)]);
    },
  );

  test('a load that fails is an error state, not invented marks', () async {
    final chat = ChatFake()
      ..readMarksResult = const Err(NetworkFailure('offline'));
    final c = await ready(chat);
    c.read(openConversationProvider.notifier).open('c1');
    c.listen(readMarksProvider, (_, _) {});

    await expectLater(
      c.read(readMarksProvider.future),
      throwsA(isA<NetworkFailure>()),
    );
    expect(c.read(readMarksProvider).hasError, isTrue);
  });

  test('a load that fails leaves no subscription behind', () async {
    final chat = ChatFake()
      ..readMarksResult = const Err(NetworkFailure('offline'));
    final c = await ready(chat);
    c.read(openConversationProvider.notifier).open('c1');
    c.listen(readMarksProvider, (_, _) {});
    await expectLater(c.read(readMarksProvider.future), throwsA(anything));
    c.read(openConversationProvider.notifier).close();
    await settle();

    expect(
      chat.canceledReadSubscriptions,
      chat.readSubscriptions,
      reason: 'a joined reads channel was never left',
    );
  });

  test('turning my read status off drops what was shown and stops '
      'listening; turning it on loads and listens again', () async {
    final profiles = ProfileFake(profile: profile());
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0),
      ];
    final c = await ready(chat, profiles: profiles);
    await open(c, 'c1');
    expect(markOf(c, 'u2')?.shares, isTrue, reason: 'fixture');

    // Mutual: once I stop sharing the server shares nothing with me.
    chat.readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
    await c.read(ownProfileProvider.notifier).setSharing(readStatus: false);
    await settle();
    await c.read(readMarksProvider.future);

    expect(
      c.read(readMarksProvider).requireValue.where((m) => m.shares),
      isEmpty,
      reason: 'still showing reads after turning my own off',
    );
    expect(
      chat.canceledReadSubscriptions,
      greaterThanOrEqualTo(1),
      reason: 'still listening to reads after turning my own off',
    );

    chat.readMarksData['c1'] = [
      ReadMark(userId: 'u2', shares: true, readAt: t0),
    ];
    await c.read(ownProfileProvider.notifier).setSharing(readStatus: true);
    await settle();
    await c.read(readMarksProvider.future);
    expect(markOf(c, 'u2')?.readAt, t0, reason: 'not reloaded when turned on');

    final t1 = t0.add(const Duration(minutes: 1));
    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    await settle();
    expect(markOf(c, 'u2')?.readAt, t1, reason: 'not listening after on');
  });

  test('switching conversation shows the new one and leaves the old', () async {
    final chat = ChatFake()
      ..readMarksData['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)]
      ..readMarksData['c2'] = const [ReadMark(userId: 'u3', shares: true)];
    final c = await ready(chat);
    await open(c, 'c1');

    c.read(openConversationProvider.notifier).open('c2');
    await settle();
    await c.read(readMarksProvider.future);

    expect(rows(c.read(readMarksProvider).requireValue), [('u3', true, null)]);
    expect(chat.canceledReadSubscriptions, 1, reason: 'c1 still listened to');

    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t0));
    await settle();
    expect(markOf(c, 'u2'), isNull, reason: 'a read from c1 leaked into c2');
  });

  test('closing the conversation stops listening', () async {
    final chat = ChatFake()..readMarksData['c1'] = const [];
    final c = await ready(chat);
    await open(c, 'c1');
    expect(chat.canceledReadSubscriptions, 0);

    c.read(openConversationProvider.notifier).close();
    await settle();

    expect(chat.canceledReadSubscriptions, 1);
    expect(await c.read(readMarksProvider.future), isEmpty);
  });
}
