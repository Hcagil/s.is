// ReadMarksController (readMarksProvider) with a phone store of read marks,
// against the shared ChatFake and a ReadMarkStore fake written here from the
// ReadMarkStore contract -- never the SDK, never the implementation. The
// owner's bug: offline, the seen tick and the readers card vanished. The
// contract: stored marks show at once (< 100 ms, no wait on the server); the
// server answer replaces them and is saved; a server error keeps them.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/read_mark_store.dart';
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

/// The phone store as the contract describes it: a few ms per call (a real
/// SQLite read), save replaces all marks of the conversation, never throws.
class StoreFake implements ReadMarkStore {
  StoreFake({this.latency = const Duration(milliseconds: 3)});

  final Duration latency;
  final data = <String, List<ReadMark>>{};
  final saves = <String>[];

  @override
  Future<List<ReadMark>> load(String conversationId) async {
    await Future<void>.delayed(latency);
    return List.of(data[conversationId] ?? const []);
  }

  @override
  Future<void> save(String conversationId, List<ReadMark> marks) async {
    await Future<void>.delayed(latency);
    data[conversationId] = List.of(marks);
    saves.add(conversationId);
  }
}

/// [StoreFake] whose load of a conversation in [gates] waits for its gate:
/// a slow phone read that lands after the member moved on.
class GatedStore extends StoreFake {
  final gates = <String, Completer<void>>{};

  @override
  Future<List<ReadMark>> load(String conversationId) async {
    final gate = gates[conversationId];
    if (gate != null) await gate.future;
    return super.load(conversationId);
  }
}

/// [ChatFake] whose readMarks of a conversation in [gates] waits for its
/// gate, so one chat's answer can land while another chat is loading.
class GatedChat extends ChatFake {
  final gates = <String, Completer<void>>{};

  @override
  Future<Result<List<ReadMark>>> readMarks(String conversationId) async {
    final gate = gates[conversationId];
    if (gate != null) await gate.future;
    return super.readMarks(conversationId);
  }
}

final t0 = DateTime.utc(2026, 9, 25, 10);
final t1 = t0.add(const Duration(minutes: 1));
final t2 = t0.add(const Duration(minutes: 2));

Future<ProviderContainer> ready(
  ChatFake chat,
  StoreFake store, {
  ProfileFake? profiles,
}) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      profileRepositoryProvider.overrideWithValue(
        profiles ?? ProfileFake(profile: profile()),
      ),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      readMarkStoreProvider.overrideWithValue(store),
    ],
  );
  await settled(c);
  c.listen(ownProfileProvider, (_, _) {});
  await c.read(ownProfileProvider.future);
  return c;
}

void open(ProviderContainer c, String id) {
  c.read(openConversationProvider.notifier).open(id);
  c.listen(readMarksProvider, (_, _) {}, fireImmediately: true);
}

Future<void> settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Polls [ok] every millisecond for up to [within]; true once it holds.
Future<bool> within(Duration within, bool Function() ok) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < within) {
    if (ok()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return ok();
}

/// A mark as what it says; ReadMark promises no value equality.
List<(String, bool, DateTime?)> rows(List<ReadMark>? marks) => [
  for (final m in marks ?? const <ReadMark>[]) (m.userId, m.shares, m.readAt),
]..sort((a, b) => a.$1.compareTo(b.$1));

List<(String, bool, DateTime?)> shown(ProviderContainer c) =>
    rows(c.read(readMarksProvider).value);

/// Settled data (not a reload keeping the previous value) holding [userId].
bool settledWith(ProviderContainer c, String userId) {
  final s = c.read(readMarksProvider);
  return s is AsyncData<List<ReadMark>> &&
      !s.isLoading &&
      s.value.any((m) => m.userId == userId);
}

void main() {
  test(
    'stored marks show BEFORE the server answers, in under 100 ms',
    () async {
      final store = StoreFake()
        ..data['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
          ReadMark(userId: 'u3', shares: true, readAt: t1),
        ];
      final chat = ChatFake()
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t2),
        ]
        ..holdReadMarks(); // the server never answers in this test
      final c = await ready(chat, store);

      open(c, 'c1');
      final inTime = await within(
        const Duration(milliseconds: 100),
        () => c.read(readMarksProvider).value?.isNotEmpty ?? false,
      );

      expect(inTime, isTrue, reason: 'stored marks waited for the server');
      expect(shown(c), [('u2', true, t0), ('u3', true, t1)]);
      expect(
        readersOf(
          c.read(readMarksProvider).requireValue,
          t0,
        ).map((m) => m.userId),
        ['u2', 'u3'],
        reason: 'readers card would be empty offline',
      );
      chat.releaseReadMarks();
    },
  );

  test('the server answer REPLACES the stored marks and is saved', () async {
    final store = StoreFake()
      ..data['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0),
        ReadMark(userId: 'u9', shares: true, readAt: t0), // left the group
      ];
    final chat = ChatFake()
      ..readMarksData['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t1)]
      ..holdReadMarks();
    final c = await ready(chat, store);
    open(c, 'c1');
    await within(const Duration(seconds: 1), () => shown(c).length == 2);

    chat.releaseReadMarks();
    final replaced = await within(
      const Duration(seconds: 1),
      () => shown(c).length == 1,
    );
    await settle();

    expect(replaced, isTrue, reason: 'server answer merged, not replaced');
    expect(shown(c), [('u2', true, t1)]);
    expect(rows(store.data['c1']), [
      ('u2', true, t1),
    ], reason: 'server answer not saved');
  });

  test('a server error keeps the stored marks, as data', () async {
    final store = StoreFake()
      ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)];
    final chat = ChatFake()
      ..readMarksResult = const Err(NetworkFailure('offline'));
    final c = await ready(chat, store);

    open(c, 'c1');
    await settle(100);

    final s = c.read(readMarksProvider);
    expect(s.hasError, isFalse, reason: 'offline turned stored marks to error');
    expect(shown(c), [('u2', true, t0)]);
    expect(rows(store.data['c1']), [
      ('u2', true, t0),
    ], reason: 'the failure overwrote the store');
  });

  test('a server error with nothing stored is the error state', () async {
    final chat = ChatFake()
      ..readMarksResult = const Err(NetworkFailure('offline'));
    final c = await ready(chat, StoreFake());

    open(c, 'c1');
    await expectLater(
      c.read(readMarksProvider.future),
      throwsA(isA<NetworkFailure>()),
    );
  });

  test('a member who stopped sharing loses the stored read time', () async {
    final store = StoreFake()
      ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)];
    final chat = ChatFake()
      ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
    final c = await ready(chat, store);

    open(c, 'c1');
    await within(
      const Duration(seconds: 1),
      () => shown(c).firstOrNull?.$2 == false,
    );
    await settle();

    expect(shown(c), [('u2', false, null)]);
    expect(rows(store.data['c1']), [
      ('u2', false, null),
    ], reason: 'stored read time survived');
  });

  test('turning my own sharing off removes the stored read times', () async {
    final profiles = ProfileFake(profile: profile());
    final store = StoreFake();
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t0),
      ];
    final c = await ready(chat, store, profiles: profiles);
    open(c, 'c1');
    await within(const Duration(seconds: 1), () => store.data['c1'] != null);
    expect(rows(store.data['c1']), [('u2', true, t0)], reason: 'fixture');

    chat.readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
    await c.read(ownProfileProvider.notifier).setSharing(readStatus: false);
    await settle(100);

    expect(shown(c), [('u2', false, null)]);
    expect(rows(store.data['c1']), [('u2', false, null)]);
  });

  test('a live read while the server is pending shows at once, is saved, '
      'and survives the (older) server answer', () async {
    final store = StoreFake()
      ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)];
    final chat = ChatFake()
      ..readMarksData['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)]
      ..holdReadMarks();
    final c = await ready(chat, store);
    open(c, 'c1');
    await within(
      const Duration(seconds: 1),
      () => shown(c).isNotEmpty && chat.readSubscriptions > 0,
    );
    expect(chat.readSubscriptions, greaterThan(0), reason: 'fixture');

    chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
    await settle();
    expect(shown(c), [('u2', true, t1)], reason: 'live read waited');
    expect(rows(store.data['c1']), [
      ('u2', true, t1),
    ], reason: 'live read not saved');

    chat.releaseReadMarks();
    await settle(100);
    expect(shown(c), [('u2', true, t1)], reason: 'server answer undid it');
    expect(rows(store.data['c1']), [('u2', true, t1)]);
  });

  group('one build never leaks into the next', () {
    test("chat 1's slow stored marks, landing after the switch, are not "
        'shown on chat 2', () async {
      final store = GatedStore()
        ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)]
        ..gates['c1'] = Completer<void>();
      final chat = GatedChat()
        ..readMarksData['c2'] = [
          ReadMark(userId: 'u3', shares: true, readAt: t0),
        ]
        ..gates['c2'] = Completer<void>(); // chat 2's server is slow
      final c = await ready(chat, store);
      open(c, 'c1');
      await settle();

      c.read(openConversationProvider.notifier).open('c2');
      await settle();
      store.gates['c1']!.complete();
      await settle(100);

      // Riverpod keeps the previous chat's value while loading; settled
      // data holding chat 1's member is the leak.
      expect(
        settledWith(c, 'u2'),
        isFalse,
        reason:
            "chat 1's stored marks painted on chat 2: "
            '${c.read(readMarksProvider)}',
      );
      chat.gates['c2']!.complete();
      await settle(100);
      expect(shown(c), [('u3', true, t0)]);
    });

    test("chat 1's server answer, landing after the switch, does not let a "
        "chat 2 read paint chat 1's marks", () async {
      final store = StoreFake()
        ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)];
      final chat = GatedChat()
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
        ]
        ..readMarksData['c2'] = const [ReadMark(userId: 'u3', shares: true)]
        ..gates['c1'] = Completer<void>()
        ..gates['c2'] = Completer<void>();
      final c = await ready(chat, store);
      open(c, 'c1');
      await within(const Duration(seconds: 1), () => shown(c).isNotEmpty);

      c.read(openConversationProvider.notifier).open('c2'); // nothing stored
      await within(
        const Duration(seconds: 1),
        () => chat.readMarksCalls.contains('c2'),
      );
      await settle();
      chat.gates['c1']!.complete(); // chat 1's answer lands late
      await settle();
      chat.deliverRead('c2', ReadMark(userId: 'u3', shares: true, readAt: t1));
      await settle(100);

      expect(
        settledWith(c, 'u2'),
        isFalse,
        reason: "chat 1's marks shown on chat 2: ${c.read(readMarksProvider)}",
      );
      expect(
        store.data['c2']?.map((m) => m.userId) ?? const <String>[],
        isNot(contains('u2')),
        reason: "chat 1's marks saved as chat 2's",
      );
      chat.gates['c2']!.complete();
      await settle(100);
      expect(shown(c), [('u3', true, t1)]);
    });

    test('a read buffered for chat 1 is not in chat 2', () async {
      final store = StoreFake()
        ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)]
        // u2 is in both chats (a 1:1 and a group with the same person).
        ..data['c2'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
          ReadMark(userId: 'u3', shares: true, readAt: t0),
        ];
      final chat = ChatFake()
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
        ]
        ..readMarksData['c2'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
          ReadMark(userId: 'u3', shares: true, readAt: t0),
        ]
        ..holdReadMarks();
      final c = await ready(chat, store);
      open(c, 'c1');
      await within(
        const Duration(seconds: 1),
        () => shown(c).isNotEmpty && chat.readSubscriptions > 0,
      );
      chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
      await settle();

      c.read(openConversationProvider.notifier).open('c2');
      await within(const Duration(seconds: 1), () => shown(c).length == 2);
      // The old chat's channel may still speak after the switch.
      chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t2));
      chat.releaseReadMarks();
      await settle(100);

      final want = [('u2', true, t0), ('u3', true, t0)];
      expect(shown(c), want, reason: "chat 1's read moved u2 in chat 2");
      expect(rows(store.data['c2']), want);
      expect(
        store.data['c1']?.map((m) => m.userId),
        isNot(contains('u3')),
        reason: 'chat 2 saved into 1',
      );
    });

    test("a chat 2 read while chat 2 loads (nothing stored) does not "
        "paint chat 1's marks", () async {
      final store = StoreFake();
      final chat = GatedChat()
        ..readMarksData['c1'] = [
          ReadMark(userId: 'u2', shares: true, readAt: t0),
        ]
        ..readMarksData['c2'] = const [ReadMark(userId: 'u3', shares: true)]
        ..gates['c2'] = Completer<void>();
      final c = await ready(chat, store);
      open(c, 'c1');
      await within(const Duration(seconds: 1), () => settledWith(c, 'u2'));
      await settle();

      c.read(openConversationProvider.notifier).open('c2');
      await within(
        const Duration(seconds: 1),
        () => chat.readMarksCalls.contains('c2'),
      );
      await settle();
      chat.deliverRead('c2', ReadMark(userId: 'u3', shares: true, readAt: t1));
      await settle(100);

      expect(
        settledWith(c, 'u2'),
        isFalse,
        reason: "chat 1's marks shown on chat 2: ${c.read(readMarksProvider)}",
      );
      expect(
        store.data['c2']?.map((m) => m.userId) ?? const <String>[],
        isNot(contains('u2')),
        reason: "chat 1's marks saved as chat 2's",
      );
      chat.gates['c2']!.complete();
      await settle(100);
      expect(shown(c), [('u3', true, t1)], reason: 'buffered read lost');
    });

    test('a read buffered before a refresh is not in the refreshed '
        'marks', () async {
      // Turning my sharing off rebuilds the same chat; a read buffered by
      // the build before must not bring back a read time.
      final profiles = ProfileFake(profile: profile());
      final store = StoreFake();
      final chat = ChatFake()
        ..readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)]
        ..holdReadMarks();
      final c = await ready(chat, store, profiles: profiles);
      open(c, 'c1');
      await within(
        const Duration(seconds: 1),
        () => chat.readSubscriptions > 0,
      );
      chat.deliverRead('c1', ReadMark(userId: 'u2', shares: true, readAt: t1));
      await settle();

      chat.readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: false)];
      await c.read(ownProfileProvider.notifier).setSharing(readStatus: false);
      await settle();
      chat.releaseReadMarks();
      await settle(100);

      expect(shown(c), [('u2', false, null)], reason: 'buffered read leaked');
      expect(rows(store.data['c1']), [('u2', false, null)]);
    });
  });

  test('a slow store never blocks the server answer', () async {
    // Store slower than the server: the server answer still wins.
    final store = StoreFake(latency: const Duration(milliseconds: 60))
      ..data['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t0)];
    final chat = ChatFake()
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: t1),
      ];
    final c = await ready(chat, store);

    open(c, 'c1');
    await settle(300);

    expect(shown(c), [('u2', true, t1)], reason: 'stale stored marks won');
  });
}
