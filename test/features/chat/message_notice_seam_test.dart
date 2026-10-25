// The seam between the live chat list and the top card: a real
// ConversationListController over ChatFake's list-wide Realtime stream
// (delivers only to a live listener, after a hop) hands each live message to
// the real messageNoticeProvider. Written by QA from the contract only.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_notice_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

DateTime at(int minute) => DateTime.utc(2026, 9, 22, 12, minute);

Conversation conv(String id, int minute, {Member other = bob}) => Conversation(
  id: id,
  other: other,
  lastMessage: 'old $id',
  lastMessageAt: at(minute),
  lastSenderId: other.userId,
);

Message msg(String chat, int minute, {String from = 'u2', String? id}) =>
    Message(
      id: id ?? '$chat-$minute',
      conversationId: chat,
      senderId: from,
      body: 'new $minute',
      createdAt: at(minute),
    );

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

/// The list loaded and live, settings and mutes loaded (the host keeps them
/// in production), chat cA open.
Future<ProviderContainer> live(ChatFake chat) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsFake(),
      ),
    ],
  );
  c.listen(conversationListProvider, (_, _) {});
  c.listen(messageNoticeProvider, (_, _) {});
  c.listen(mutesProvider, (_, _) {});
  c.listen(notificationSettingsProvider, (_, _) {});
  await c.read(conversationListProvider.future);
  await c.read(mutesProvider.future);
  await c.read(notificationSettingsProvider.future);
  await settle();
  c.read(openConversationProvider.notifier).open('cA');
  return c;
}

ChatFake threeChats() => ChatFake()
  ..conversationsResult = Ok([
    conv('cA', 30),
    conv('cB', 20),
    conv('cC', 10, other: cem),
  ]);

MessageNoticeData? card(ProviderContainer c) => c.read(messageNoticeProvider);

void main() {
  test('a live message for chat B while A is open raises its card', () async {
    final chat = threeChats();
    final c = await live(chat);

    chat.deliver(msg('cB', 40));
    await settle();

    expect(card(c)?.conversationId, 'cB');
    expect(card(c)!.count, 1);
    expect(
      card(c)!.preview,
      'new 40',
      reason: 'the preview the list now holds',
    );
  });

  test('the next message of B counts up; one from C replaces it', () async {
    final chat = threeChats();
    final c = await live(chat);

    chat.deliver(msg('cB', 40));
    await settle();
    chat.deliver(msg('cB', 41));
    await settle();
    expect(card(c)!.count, 2);

    chat.deliver(msg('cC', 42, from: 'u3'));
    await settle();
    expect(card(c)!.conversationId, 'cC');
    expect(card(c)!.count, 1);
  });

  test('a message in the open chat raises no card', () async {
    final chat = threeChats();
    final c = await live(chat);
    chat.deliver(msg('cA', 40));
    await settle();
    expect(card(c), isNull);
  });

  test('no chat open: no card', () async {
    final chat = threeChats();
    final c = await live(chat);
    c.read(openConversationProvider.notifier).close();
    chat.deliver(msg('cB', 40));
    await settle();
    expect(card(c), isNull);
  });

  test('own message from another phone raises no card', () async {
    final chat = threeChats();
    final c = await live(chat);
    chat.deliver(msg('cB', 40, from: 'u1'));
    await settle();
    expect(card(c), isNull);
  });

  test('an older message raises no card', () async {
    final chat = threeChats();
    final c = await live(chat);
    chat.deliver(msg('cB', 5));
    await settle();
    expect(card(c), isNull);
  });

  test('a duplicate delivery does not count twice', () async {
    final chat = threeChats();
    final c = await live(chat);
    chat.deliver(msg('cB', 40));
    await settle();
    chat.deliver(msg('cB', 40));
    await settle();
    expect(card(c)!.count, 1);
  });

  test('a chat the list does not hold: no card (known limit)', () async {
    final chat = threeChats();
    final c = await live(chat);
    chat.deliver(msg('cZ', 40, from: 'u3'));
    await settle();
    expect(card(c), isNull);
  });
}
