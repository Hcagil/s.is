// An admin reply row that changes on the server (the confirm card answered:
// st=done; the progress line edited p1 -> p2 -> p3) arrives again on the
// conversation's Realtime stream with the same id. MessagesController must
// replace it in place -- one message, same position, the new admin_msg --
// never append a second copy. Written from the contract against ChatFake,
// whose Realtime delivers only to a live subscription.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bot = '00000000-0000-0000-0000-00000000ad41';

Message row(String id, {String from = bot, Map<String, dynamic>? admin, int minutesAgo = 5, String body = ''}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: body,
      createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      adminMsg: admin,
    );

/// The same row after a server UPDATE: same id and time, new admin_msg.
Message updated(Message m, Map<String, dynamic> admin) => Message(
  id: m.id,
  conversationId: m.conversationId,
  senderId: m.senderId,
  body: m.body,
  createdAt: m.createdAt,
  adminMsg: admin,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

Future<ProviderContainer> open(ChatFake chat) async {
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
      ],
    ),
  );
  c.read(openConversationProvider.notifier).open('c1');
  c.listen(messagesProvider, (_, _) {});
  await c.read(messagesProvider.future);
  await settle();
  return c;
}

/// A Realtime UPDATE: the row changes in the "database" and the new version
/// reaches the live subscription. [ChatFake.deliver] appends to history as an
/// insert would, so the stored row is put back to one copy afterwards.
void serverUpdate(ChatFake chat, Message next) {
  chat.deliver(next);
  final rows = chat.history['c1']!;
  rows.removeLast();
  rows[rows.indexWhere((m) => m.id == next.id)] = next;
}

List<Message> shown(ProviderContainer c) => c.read(messagesProvider).requireValue;

void main() {
  const conf = {'k': 'conf', 'e': 'r***@m***.test'};

  test('an answered confirm card replaces the card in place', () async {
    final card = row('card', admin: conf, minutesAgo: 3);
    final chat = ChatFake(self: me.userId)
      ..history['c1'] = [
        row('cmd', from: me.userId, body: '/removetester rob@mail.test', minutesAgo: 4),
        card,
        row('after', from: me.userId, body: 'ok', minutesAgo: 1),
      ];
    final c = await open(chat);

    serverUpdate(chat, updated(card, {...conf, 'st': 'done'}));
    await settle();

    expect(shown(c).map((m) => m.id), ['cmd', 'card', 'after']);
    expect(shown(c)[1].adminMsg, {...conf, 'st': 'done'});
  });

  test('a card that arrived live, then is answered, stays one message', () async {
    final chat = ChatFake(self: me.userId)
      ..history['c1'] = [row('cmd', from: me.userId, body: '/removetester rob@mail.test', minutesAgo: 4)];
    final c = await open(chat);
    final card = row('card', admin: conf, minutesAgo: 0);
    chat.deliver(card);
    await settle();
    expect(shown(c).map((m) => m.id), ['cmd', 'card']);

    serverUpdate(chat, updated(card, {...conf, 'st': 'cancelled'}));
    await settle();

    expect(shown(c).map((m) => m.id), ['cmd', 'card']);
    expect(shown(c).last.adminMsg?['st'], 'cancelled');
  });

  test('the progress line edited p1 -> p2 -> p3 is one message showing the last step', () async {
    final chat = ChatFake(self: me.userId)..history['c1'] = [row('p', admin: {'k': 'p1'})];
    final c = await open(chat);
    for (final k in ['p2', 'p3']) {
      serverUpdate(chat, updated(chat.history['c1']!.single, {'k': k}));
      await settle();
    }
    expect(shown(c), hasLength(1));
    expect(shown(c).single.adminMsg, {'k': 'p3'});
  });

  test('answered while the owner is scrolled back (a jumped window): still replaced in place', () async {
    // A jumped window has no live end, so a live INSERT is not appended there;
    // an UPDATE of a row on screen must still show.
    final t0 = DateTime.utc(2026, 10, 1);
    final rows = [
      for (var i = 0; i < 300; i++)
        Message(
          id: 'm$i',
          conversationId: 'c1',
          senderId: i == 30 ? bot : me.userId,
          body: i == 30 ? '' : 'cmd $i',
          createdAt: t0.add(Duration(minutes: i)),
          adminMsg: i == 30 ? conf : null,
        ),
    ];
    final chat = ChatFake(self: me.userId)..history['c1'] = rows;
    final c = await open(chat);
    final card = rows[30];
    expect(shown(c).map((m) => m.id), isNot(contains('m30')), reason: 'fixture: the card is beyond the first page');
    await c.read(messagesProvider.notifier).jumpToAround(card);
    await settle();
    expect(shown(c).map((m) => m.id), contains('m30'));

    serverUpdate(chat, updated(card, {...conf, 'st': 'done'}));
    await settle();

    final onScreen = shown(c).where((m) => m.id == 'm30');
    expect(onScreen, hasLength(1));
    expect(onScreen.single.adminMsg?['st'], 'done');
  });
}
