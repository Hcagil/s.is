// Editing a message, at the controller layer: MessagesController.editMessage
// and a live edit replace the message in place; the conversation list moves
// its preview only when the edited message is the newest one, and never
// re-orders or re-counts; editingProvider forgets the message when the
// conversation changes. Written from the contract against ChatFake, whose
// edit behaves like edit_message and whose Realtime delivers an UPDATE only
// to a live subscription.
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

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

/// Minutes before now: fresh enough to edit, ordered by age.
Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String conversation = 'c1',
  int minutesAgo = 10,
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ProviderContainer scope(ChatFake chat) => ProviderContainer.test(
  overrides: [
    chatRepositoryProvider.overrideWithValue(chat),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
    sessionControllerProvider.overrideWith(_SignedIn.new),
    pushSourceProvider.overrideWithValue(PushSourceFake()),
  ],
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

/// A container with c1 open and its messages loaded and kept alive.
Future<ProviderContainer> open(ChatFake chat) async {
  final c = await settled(scope(chat));
  c.read(openConversationProvider.notifier).open('c1');
  c.listen(messagesProvider, (_, _) {});
  await c.read(messagesProvider.future);
  await settle();
  return c;
}

List<Message> shown(ProviderContainer c) =>
    c.read(messagesProvider).requireValue;

void main() {
  group('MessagesController.editMessage', () {
    test(
      'Ok replaces the message in place, at once, from the answer',
      () async {
        // Forced, so no Realtime echo follows: the screen must change from the
        // repository's answer alone, not wait for the UPDATE to come around.
        final chat = ChatFake(self: me.userId)
          ..history['c1'] = [
            msg('m1', minutesAgo: 30),
            msg('m2', body: 'teh typo', minutesAgo: 20),
            msg('m3', from: bob.userId, minutesAgo: 10),
          ];
        final c = await open(chat);
        final target = shown(c)[1];
        chat.editMessageResult = Ok(editedCopy(target, 'the typo'));

        final result = await c
            .read(messagesProvider.notifier)
            .editMessage(target, 'the typo');

        expect(result, isA<Ok<Message>>());
        expect(chat.edits, [(messageId: 'm2', body: 'the typo')]);
        expect(shown(c).map((m) => m.id), ['m1', 'm2', 'm3']);
        expect(shown(c)[1].body, 'the typo');
        expect(shown(c)[1].isEdited, isTrue);
        expect(shown(c)[0].body, 'hi', reason: 'its neighbours are untouched');
      },
    );

    test('Err is returned and the message is left exactly as it was', () async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', body: 'original')]
        ..editMessageResult = const Err(DeniedFailure());
      final c = await open(chat);

      final result = await c
          .read(messagesProvider.notifier)
          .editMessage(shown(c).single, 'changed');

      expect(result, isA<Err<Message>>());
      expect((result as Err<Message>).failure, isA<DeniedFailure>());
      expect(shown(c).single.body, 'original');
      expect(shown(c).single.isEdited, isFalse);
    });

    test('the answer and its Realtime echo leave exactly one copy', () async {
      // Unforced: the fake answers Ok AND delivers the UPDATE, as the server
      // does -- the same row reaching the controller twice.
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1'), msg('m2', minutesAgo: 5)];
      final c = await open(chat);

      await c
          .read(messagesProvider.notifier)
          .editMessage(shown(c).first, 'fixed');
      await settle();

      expect(shown(c).map((m) => m.id), ['m1', 'm2']);
      expect(shown(c).first.body, 'fixed');
    });
  });

  group('an edit arriving live', () {
    test(
      'replaces the message in place: same position, new body, edited',
      () async {
        final chat = ChatFake(self: me.userId)
          ..history['c1'] = [
            msg('m1', from: bob.userId, minutesAgo: 30),
            msg('m2', from: bob.userId, body: 'see you at 5', minutesAgo: 20),
            msg('m3', minutesAgo: 10),
          ];
        final c = await open(chat);

        chat.serverEdit(chat.history['c1']![1], 'see you at 6');
        await settle();

        expect(shown(c).map((m) => m.id), ['m1', 'm2', 'm3']);
        expect(shown(c)[1].body, 'see you at 6');
        expect(shown(c)[1].isEdited, isTrue);
      },
    );

    test('an edit of a message not on screen is not appended as new', () async {
      // The history the screen loaded does not hold m0 (it was never read,
      // e.g. beyond the page); an UPDATE of it must not surface at the
      // bottom as if it had just been sent.
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1'), msg('m2', minutesAgo: 5)];
      final c = await open(chat);

      chat.serverEdit(
        msg('m0', from: bob.userId, minutesAgo: 60),
        'an old message, edited',
      );
      await settle();

      expect(shown(c).map((m) => m.id), ['m1', 'm2']);
    });
  });

  group('editingProvider', () {
    test('start holds the message; clear forgets it', () async {
      final chat = ChatFake(self: me.userId)..history['c1'] = [msg('m1')];
      final c = await open(chat);
      c.listen(editingProvider, (_, _) {});

      c.read(editingProvider.notifier).start(shown(c).single);
      expect(c.read(editingProvider)?.id, 'm1');

      c.read(editingProvider.notifier).clear();
      expect(c.read(editingProvider), isNull);
    });

    test('opening another conversation forgets the message', () async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1')]
        ..history['c2'] = [msg('m9', conversation: 'c2')];
      final c = await open(chat);
      c.listen(editingProvider, (_, _) {});
      c.read(editingProvider.notifier).start(shown(c).single);

      c.read(openConversationProvider.notifier).open('c2');
      await settle();

      expect(
        c.read(editingProvider),
        isNull,
        reason: 'an edit begun in c1 must never be saved from c2',
      );
    });
  });

  group('the conversation list', () {
    DateTime at(int minute) => DateTime.utc(2026, 9, 25, 5, minute);
    Message row(String id, String conversation, int minute, String body) =>
        Message(
          id: id,
          conversationId: conversation,
          senderId: bob.userId,
          body: body,
          createdAt: at(minute),
        );
    Conversation conv(String id, int minute, String text, {int unread = 0}) =>
        Conversation(
          id: id,
          other: bob,
          lastMessage: text,
          lastMessageAt: at(minute),
          lastSenderId: bob.userId,
          unread: unread,
        );

    Future<ProviderContainer> listed(ChatFake chat) async {
      final c = await settled(scope(chat));
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      await settle();
      return c;
    }

    Conversation tile(ProviderContainer c, String id) => c
        .read(conversationListProvider)
        .requireValue
        .firstWhere((x) => x.id == id);
    List<String> order(ProviderContainer c) =>
        c.read(conversationListProvider).requireValue.map((x) => x.id).toList();

    ChatFake twoChats() => ChatFake(self: me.userId)
      ..conversationsResult = Ok([
        conv('c1', 30, 'c1 newest'),
        conv('c2', 20, 'c2 newest', unread: 2),
      ])
      ..history['c1'] = [row('c1-a', 'c1', 30, 'c1 newest')]
      ..history['c2'] = [
        row('c2-a', 'c2', 10, 'c2 older'),
        row('c2-b', 'c2', 20, 'c2 newest'),
      ];

    test('editing the newest message updates the preview, and nothing '
        'else: not the order, not the time, not the unread count', () async {
      final chat = twoChats();
      final c = await listed(chat);

      chat.serverEdit(chat.history['c2']![1], 'c2 newest, edited');
      await settle();

      expect(tile(c, 'c2').lastMessage, 'c2 newest, edited');
      expect(order(c), ['c1', 'c2'], reason: 'an edit is not a new message');
      expect(tile(c, 'c2').lastMessageAt, at(20));
      expect(tile(c, 'c2').unread, 2);
    });

    test('the preview follows even when the list and Realtime disagree on '
        'the time zone of the same instant', () async {
      // Observed on the real stack (edit_message_repository_test's
      // accounts, TZ=JST-9): conversations() answers lastMessageAt in UTC,
      // while the same row's createdAt arrives over Realtime in local time.
      // Same instant, different DateTime -- and `==` on DateTime compares
      // the zone flag too.
      final chat = twoChats();
      chat.history['c2'] = [
        for (final m in chat.history['c2']!)
          Message(
            id: m.id,
            conversationId: m.conversationId,
            senderId: m.senderId,
            body: m.body,
            createdAt: m.createdAt.toLocal(),
          ),
      ];
      final c = await listed(chat);
      expect(tile(c, 'c2').lastMessageAt!.isUtc, isTrue);

      chat.serverEdit(chat.history['c2']![1], 'c2 newest, edited');
      await settle();

      expect(tile(c, 'c2').lastMessage, 'c2 newest, edited');
      expect(order(c), ['c1', 'c2']);
    });

    test(
      'editing an older message changes neither preview nor order',
      () async {
        final chat = twoChats();
        final c = await listed(chat);

        chat.serverEdit(chat.history['c2']![0], 'c2 older, edited');
        await settle();

        expect(tile(c, 'c2').lastMessage, 'c2 newest');
        expect(order(c), ['c1', 'c2']);
        expect(tile(c, 'c2').lastMessageAt, at(20));
        expect(tile(c, 'c2').unread, 2);
      },
    );
  });
}
