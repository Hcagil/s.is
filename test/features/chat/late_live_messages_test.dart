// test/features/chat/late_live_messages_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

// MessagesController and Realtime rows written before the reader joined:
// - a live row older than the oldest shown stored row is ignored (loadOlder
//   fetches it); one inside the shown range is sorted in by createdAt, before
//   any pending bubble; a known id is merged, never duplicated.
// - loadOlder ends paging only when the server page has <= messagePageSize
//   rows at or before the anchor, counted before dropping shown rows.
final _t0 = DateTime.utc(2026, 1, 1);

/// Helper to create a history list of [n] messages, oldest first.
List<Message> _history(String id, int n) => [
  for (var i = 0; i < n; i++)
    Message(
      id: '$id-$i',
      conversationId: id,
      senderId: 'u2',
      body: 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

/// Helper to create a late message at a fractional minute.
Message late(String id, double minutes) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: 'late $id',
  createdAt: _t0.add(Duration(seconds: (minutes * 60).round())),
);

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Polls [done] until it holds, or fails after [timeout].
Future<void> _until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 3),
  String reason = '',
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Asserts that the list is sorted by createdAt ascending.
void sortedByTime(List<Message> list) {
  for (var i = 0; i < list.length - 1; i++) {
    expect(
      list[i].createdAt.isBefore(list[i + 1].createdAt) ||
          list[i].createdAt.isAtSameMomentAs(list[i + 1].createdAt),
      isTrue,
      reason: 'messages not sorted by time',
    );
  }
}

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<Message> rows() => c.read(messagesProvider).requireValue;
  List<String> shown() => rows().map((m) => m.id).toList();
  Message row(String id) => rows().firstWhere((m) => m.id == id);
  MessagesController messages() => c.read(messagesProvider.notifier);

  Future<void> open(String id) async {
    c.read(openConversationProvider.notifier).open(id);
    await c.read(messagesProvider.future);
    chat.confirmSubscription();
    // Let the confirmed subscription go live before anything is delivered.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  setUp(() {
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    chat.history['c1'] = _history('c1', 120);
    c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    );
    c.listen(messagesProvider, (_, _) {});
    c.listen(olderLoadingProvider, (_, _) {});
  });

  tearDown(() => c.dispose());

  group('a live row from before the reader joined', () {
    test('late row older than shown is ignored', () async {
      await open('c1');
      final before = shown();
      chat.deliver(late('late-a', 40.5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shown(), before);
      expect(messages().hasOlder, isTrue);
    });

    test('in-range late row is inserted in order', () async {
      await open('c1');
      chat.deliver(late('mid', 100.5));
      await _until(() => shown().contains('mid'), reason: 'mid not shown');
      final idxMid = shown().indexOf('mid');
      final idx100 = shown().indexOf('c1-100');
      expect(idxMid, idx100 + 1, reason: 'mid after c1-100');
      expect(shown()[idxMid + 1], 'c1-101', reason: 'next after mid');
      expect(shown(), hasLength(51));
      sortedByTime(rows());
    });

    test('duplicate late row is ignored', () async {
      await open('c1');
      final duplicate = row('c1-110');
      chat.deliver(
        Message(
          id: duplicate.id,
          conversationId: duplicate.conversationId,
          senderId: duplicate.senderId,
          body: duplicate.body,
          createdAt: duplicate.createdAt,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shown(), hasLength(50));
      expect(shown().where((id) => id == 'c1-110').length, 1);
    });

    test('new late row far in future becomes last', () async {
      await open('c1');
      chat.deliver(late('new', 500));
      await _until(() => shown().last == 'new', reason: 'new not last');
    });

    test('pending image stays last and new rows inserted before it', () async {
      await open('c1');
      chat.holdSendImage();
      final f = messages().sendImage(chosen: pickedPng());
      await _until(() => rows().last.isPending, reason: 'pending not last');
      chat.deliver(late('mid', 100.5));
      await _until(() => shown().contains('mid'), reason: 'mid not shown');
      expect(rows().last.isPending, isTrue);
      final stored = rows().sublist(0, rows().length - 1);
      sortedByTime(stored);
      final idx100 = shown().indexOf('c1-100');
      expect(shown().indexOf('mid'), idx100 + 1);
      chat.releaseSendImage();
      await f;
    });
  });

  group('loadOlder after late rows', () {
    test('late rows older than shown are ignored until loadOlder', () async {
      await open('c1');
      for (var k = 0; k < 5; k++) {
        chat.deliver(late('late-$k', 65.5 + k));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        shown().where((id) => id.startsWith('late-')),
        isEmpty,
        reason: 'older than the oldest shown: left for loadOlder',
      );
      await messages().loadOlder();
      expect(
        messages().hasOlder,
        isTrue,
        reason: 'a full server page is not the start of the chat',
      );
      expect(
        shown().toSet().containsAll([
          'late-0',
          'late-1',
          'late-2',
          'late-3',
          'late-4',
        ]),
        isTrue,
      );
      sortedByTime(rows());
      var count = 0;
      while (messages().hasOlder && count < 10) {
        await messages().loadOlder();
        count++;
      }
      expect(count, lessThanOrEqualTo(10));
      expect(shown(), hasLength(125));
      expect(shown().toSet().length, 125);
      sortedByTime(rows());
      expect(shown().first, 'c1-0');
    });
  });

  group('full page with shown rows at the anchor\'s instant', () {
    test(
      'full page with anchor rows already shown still counts as full page',
      () async {
        chat.history['c1'] = [
          for (final m in _history('c1', 120))
            if (m.id == 'c1-71' || m.id == 'c1-72')
              Message(
                id: m.id,
                conversationId: m.conversationId,
                senderId: m.senderId,
                body: m.body,
                createdAt: _t0.add(const Duration(minutes: 70)),
              )
            else
              m,
        ];
        await open('c1');
        expect(shown().first, 'c1-70');
        // Prepare messagesAroundResult with 48 old rows + 3 anchor rows + rest
        final oldRows = [
          for (var i = 22; i <= 69; i++)
            Message(
              id: 'old-$i',
              conversationId: 'c1',
              senderId: 'u2',
              body: 'old $i',
              createdAt: _t0.add(Duration(minutes: i)),
            ),
        ];
        final around = [
          ...oldRows,
          row('c1-70'),
          row('c1-71'),
          row('c1-72'),
          ...chat.history['c1']!.sublist(73),
        ];
        chat.messagesAroundResult = Ok(around);
        await messages().loadOlder();
        expect(
          messages().hasOlder,
          isTrue,
          reason: '51 rows at or before the anchor is a full page even though 3 were already shown',
        );
        expect(shown().contains('old-22'), isTrue);
        expect(shown(), hasLength(98));
      },
    );
  });

  group('start of chat', () {
    test('paging stops at the oldest message', () async {
      await open('c1');
      await messages().loadOlder();
      expect(messages().hasOlder, isTrue);
      await messages().loadOlder();
      expect(messages().hasOlder, isFalse);
      expect(shown().first, 'c1-0');
      expect(shown(), hasLength(120));
    });

    test('history 100: first loadOlder full page, second empty', () async {
      chat.history['c1'] = _history('c1', 100);
      await open('c1');
      await messages().loadOlder();
      expect(messages().hasOlder, isTrue);
      expect(shown(), hasLength(100));
      await messages().loadOlder();
      expect(messages().hasOlder, isFalse);
    });

    test('history 99: first loadOlder empty', () async {
      chat.history['c1'] = _history('c1', 99);
      await open('c1');
      await messages().loadOlder();
      expect(messages().hasOlder, isFalse);
      expect(shown().first, 'c1-0');
      expect(shown(), hasLength(99));
    });
  });
}
