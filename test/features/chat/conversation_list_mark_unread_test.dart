// ConversationListController tells the server what reached this device
// (Update 1 slice 5), against ChatMarkRepository. Contract: markUnread is
// called optimistically (a slow or failed call never holds up or breaks the
// list).  The server marks the conversation as unread on the device and
// returns Ok unless told to refuse.  The list shows the conversation as
// unread immediately, and reverts if the call fails.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/mark_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

DateTime at(int minute) => DateTime.utc(2026, 9, 22, 12, minute);

Conversation conv(String id, int minute, {int unread = 0}) => Conversation(
  id: id,
  other: bob,
  lastMessage: 'old $id',
  lastMessageAt: at(minute),
  lastSenderId: bob.userId,
  unread: unread,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

Future<ProviderContainer> loaded(ChatFake chat, MarkFake mark) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      chatMarkRepositoryProvider.overrideWithValue(mark),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
    ],
  );
  c.listen(conversationListProvider, (_, _) {});
  await c.read(conversationListProvider.future);
  await settle();
  return c;
}

void main() {
  test(
    'markUnread on a read chat updates list immediately and reverts on failure',
    () async {
      final chat = ChatFake(self: me.userId)
        ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
      final mark = MarkFake();
      final c = await loaded(chat, mark);

      // Hold the server call so we can observe optimistic UI
      mark.hold();

      final future = c.read(conversationListProvider.notifier).markUnread('c1');
      // Do not await the future yet

      // Optimistic update: markedUnread true, isUnread true, unread stays 0
      final list = c.read(conversationListProvider).requireValue;
      final c1 = list.firstWhere((x) => x.id == 'c1');
      expect(c1.markedUnread, isTrue);
      expect(c1.isUnread, isTrue);
      expect(c1.unread, 0);

      // Only c1 changed
      final c2 = list.firstWhere((x) => x.id == 'c2');
      expect(c2.markedUnread, isFalse);
      expect(c2.isUnread, isFalse);

      // Server call recorded
      await settle(); // allow server tick
      expect(mark.calls, ['c1']);

      // Release and await result
      mark.release();
      final result = await future;
      expect(result, isA<Ok<void>>());
    },
  );

  test('markUnread on a read chat that already has unread messages', () async {
    final chat = ChatFake(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30, unread: 2), conv('c2', 20)]);
    final mark = MarkFake();
    final c = await loaded(chat, mark);

    final future = c.read(conversationListProvider.notifier).markUnread('c1');
    await settle(); // allow optimistic update

    final list = c.read(conversationListProvider).requireValue;
    final c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.unread, 2);
    expect(c1.isUnread, isTrue);
    expect(c1.markedUnread, isTrue);

    final result = await future;
    expect(result, isA<Ok<void>>());
  });

  test('markUnread fails: list reverts to original state', () async {
    final chat = ChatFake(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
    final mark = MarkFake()..result = const Err(DeniedFailure());
    final c = await loaded(chat, mark);
    mark.hold();

    final future = c.read(conversationListProvider.notifier).markUnread('c1');
    await settle(); // optimistic update

    var list = c.read(conversationListProvider).requireValue;
    var c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.markedUnread, isTrue);
    expect(c1.isUnread, isTrue);

    mark.release();
    final result = await future;
    expect(result, isA<Err<void>>());

    // After failure, revert
    list = c.read(conversationListProvider).requireValue;
    c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.markedUnread, isFalse);
    expect(c1.isUnread, isFalse);
  });

  test('markUnread fails on a chat with existing unread count', () async {
    final chat = ChatFake(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30, unread: 2), conv('c2', 20)]);
    final mark = MarkFake()..result = const Err(DeniedFailure());
    final c = await loaded(chat, mark);
    mark.hold();

    final future = c.read(conversationListProvider.notifier).markUnread('c1');
    await settle(); // optimistic update

    var list = c.read(conversationListProvider).requireValue;
    var c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.unread, 2);
    expect(c1.markedUnread, isTrue);
    expect(c1.isUnread, isTrue);

    mark.release();
    final result = await future;
    expect(result, isA<Err<void>>());

    // Revert to original unread count and flags
    list = c.read(conversationListProvider).requireValue;
    c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.unread, 2);
    expect(c1.markedUnread, isFalse);
    expect(c1.isUnread, isTrue, reason: 'still has 2 unread messages');
  });

  test('markRead clears markedUnread and unread count', () async {
    final chat = ChatFake(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
    final mark = MarkFake();
    final c = await loaded(chat, mark);

    // First mark as unread
    await c.read(conversationListProvider.notifier).markUnread('c1');
    await settle();

    // Now mark as read
    final future = c.read(conversationListProvider.notifier).markRead('c1');
    await settle();

    final list = c.read(conversationListProvider).requireValue;
    final c1 = list.firstWhere((x) => x.id == 'c1');
    expect(c1.markedUnread, isFalse);
    expect(c1.isUnread, isFalse);
    expect(c1.unread, 0);

    await future;
    // ChatFake records markedRead
    expect(chat.markedRead, ['c1']);
  });
}
