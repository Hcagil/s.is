// ConversationListController tells the server what reached this device
// (Update 1 slice 5), against DeliveryChat. Contract: markDelivered is called
// fire-and-forget (a slow or failed call never holds up or breaks the list)
//  * for a live message from someone else -- not my own, not an edit, not a
//    deletion;
//  * on load, for each conversation with unread > 0.
// The server delivers every message created at or before upTo (null = all so
// far), so upTo must never be before the message that arrived.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/delivery_fakes.dart';
import '../../support/fakes.dart';

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

Message msg(
  String conversation,
  int minute, {
  String from = 'u2',
  DateTime? editedAt,
  MessageDeletion? deletion,
}) => Message(
  id: '$conversation-$minute',
  conversationId: conversation,
  senderId: from,
  body: deletion == null ? 'new' : '',
  createdAt: at(minute),
  editedAt: editedAt,
  deletion: deletion,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

Future<ProviderContainer> loaded(DeliveryChat chat) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
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

List<String> marked(DeliveryChat chat) => [
  for (final d in chat.delivered) d.$1,
];

void main() {
  test(
    'on load: each conversation with unread messages, and only those',
    () async {
      final chat = DeliveryChat(self: me.userId)
        ..conversationsResult = Ok([
          conv('c1', 30, unread: 2),
          conv('c2', 20),
          conv('c3', 10, unread: 1),
        ]);
      await loaded(chat);
      // Starting reads the list more than once (a catch-up read after the
      // live subscription): once per unread conversation per read.
      final reads = chat.calls.where((c) => c == 'conversations').length;
      expect(reads, greaterThan(0));
      expect(marked(chat)..sort(), [
        for (final id in ['c1', 'c3']) ...List.filled(reads, id),
      ], reason: 'exactly once per unread conversation per list read');
    },
  );

  test('a live message from someone else: its conversation, up to at least '
      'that message', () async {
    final chat = DeliveryChat(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30), conv('c2', 20)]);
    await loaded(chat);
    expect(chat.delivered, isEmpty, reason: 'fixture: nothing unread');

    final m = msg('c2', 40);
    chat.deliver(m);
    await settle();
    expect(marked(chat), ['c2']);
    final upTo = chat.delivered.single.$2;
    expect(
      upTo == null || !upTo.isBefore(m.createdAt),
      isTrue,
      reason: 'upTo $upTo stops short of the message at ${m.createdAt}',
    );
  });

  // No `self`: the fake then leaves the stored list (and its unread counts)
  // alone, so a reload a deletion triggers finds nothing unread.
  for (final (what, event) in [
    ('my own message', msg('c1', 41, from: me.userId)),
    ('an edit', msg('c1', 42, editedAt: at(43))),
    ('a deletion', msg('c1', 44, deletion: MessageDeletion.placeholder)),
  ]) {
    test('$what: no call', () async {
      final chat = DeliveryChat()..conversationsResult = Ok([conv('c1', 30)]);
      await loaded(chat);

      chat.deliver(event);
      await settle();
      expect(chat.delivered, isEmpty);

      chat.deliver(msg('c1', 45));
      await settle();
      expect(marked(chat), ['c1'], reason: 'control: a plain live message');
    });
  }

  test('fire-and-forget: a call that never answers holds up neither the load '
      'nor live messages', () async {
    final chat = DeliveryChat(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30, unread: 1)])
      ..holdMarkDelivered();
    final c = await loaded(chat).timeout(const Duration(seconds: 2));
    expect(
      marked(chat),
      List.filled(chat.calls.where((c) => c == 'conversations').length, 'c1'),
    );

    chat.deliver(msg('c1', 40));
    await settle();
    final row = c.read(conversationListProvider).requireValue.single;
    expect(row.lastMessageAt, at(40), reason: 'the live message waited');
    chat.releaseMarkDelivered();
  });

  test('a failed call leaves the list as it was', () async {
    final chat = DeliveryChat(self: me.userId)
      ..conversationsResult = Ok([conv('c1', 30, unread: 1)])
      ..markDeliveredResult = const Err(NetworkFailure('offline'));
    final c = await loaded(chat);
    chat.deliver(msg('c1', 40));
    await settle();
    final state = c.read(conversationListProvider);
    expect(state.hasError, isFalse);
    expect(state.requireValue.single.lastMessageAt, at(40));
  });
}
