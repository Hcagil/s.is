// Unit tests for the reply/forward application layer: replyingToProvider and
// MessagesController.send/sendImage/forward, against a fake repository.
// Written from the contract in lib/features/chat/application/chat_controllers.dart
// and lib/features/chat/domain/chat_repository.dart -- never the
// implementation.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

Message msg(
  String id, {
  String body = 'hi',
  int minute = 0,
  String from = 'me',
  String conversation = 'c1',
}) => Message(
  id: id,
  conversationId: conversation,
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
);

ProviderContainer make(FakeChat fake) => ProviderContainer.test(
  overrides: [chatRepositoryProvider.overrideWithValue(fake)],
);

void main() {
  group('replyingToProvider', () {
    test('starts null with no conversation open', () {
      final c = make(FakeChat());
      expect(c.read(replyingToProvider), isNull);
    });

    test('start() sets the message being answered', () {
      final c = make(FakeChat());
      c.read(openConversationProvider.notifier).open('c1');
      final m = msg('m1');
      c.read(replyingToProvider.notifier).start(m);
      expect(c.read(replyingToProvider), m);
    });

    test('clear() sets it back to null', () {
      final c = make(FakeChat());
      c.read(openConversationProvider.notifier).open('c1');
      c.read(replyingToProvider.notifier).start(msg('m1'));
      c.read(replyingToProvider.notifier).clear();
      expect(c.read(replyingToProvider), isNull);
    });

    test('opening a different conversation resets it to null', () {
      final c = make(FakeChat());
      c.read(openConversationProvider.notifier).open('c1');
      c.read(replyingToProvider.notifier).start(msg('m1'));
      expect(c.read(replyingToProvider), isNotNull);

      c.read(openConversationProvider.notifier).open('c2');
      expect(
        c.read(replyingToProvider),
        isNull,
        reason: 'a reply belongs to the conversation it was started in',
      );
    });
  });

  group('send() carries the reply and clears it only on success', () {
    test('passes the replying message\'s id as replyTo', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(msg('quoted'));

      await c.read(messagesProvider.notifier).send('hello');
      expect(fake.sentReplyTo, ['quoted']);
    });

    test('no reply in progress sends replyTo null', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      await c.read(messagesProvider.notifier).send('hello');
      expect(fake.sentReplyTo, [null]);
    });

    test('a successful send clears replyingToProvider', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(msg('quoted'));

      final result = await c.read(messagesProvider.notifier).send('hello');
      expect(result, isA<Ok<Message>>());
      expect(
        c.read(replyingToProvider),
        isNull,
        reason: 'sent: the composer is done answering it',
      );
    });

    test('a refused send leaves replyingToProvider untouched', () async {
      final fake = FakeChat()..sendResult = const Err(DeniedFailure());
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      final quoted = msg('quoted');
      c.read(replyingToProvider.notifier).start(quoted);

      final result = await c.read(messagesProvider.notifier).send('hello');
      expect(result, isA<Err<Message>>());
      expect(
        c.read(replyingToProvider),
        quoted,
        reason: 'nothing was sent: whatever was typed, and the reply, stays',
      );
    });
  });

  group('sendImage() carries the reply and clears it only on success', () {
    test('passes the replying message\'s id as replyTo', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(msg('quoted'));

      await c.read(messagesProvider.notifier).sendImage(chosen: pickedPng());
      expect(fake.sentImages.single.replyTo, 'quoted');
    });

    test('a successful sendImage clears replyingToProvider', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      c.read(replyingToProvider.notifier).start(msg('quoted'));

      final result = await c
          .read(messagesProvider.notifier)
          .sendImage(chosen: pickedPng());
      expect(result, isA<Ok<Message>>());
      expect(c.read(replyingToProvider), isNull);
    });

    test('a refused sendImage leaves replyingToProvider untouched', () async {
      final fake = FakeChat()..sendImageResult = const Err(DeniedFailure());
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      final quoted = msg('quoted');
      c.read(replyingToProvider.notifier).start(quoted);

      final result = await c
          .read(messagesProvider.notifier)
          .sendImage(chosen: pickedPng());
      expect(result, isA<Err<Message>>());
      expect(c.read(replyingToProvider), quoted);
    });
  });

  group('forward()', () {
    test('calls the repository with the message and every target id', () async {
      final fake = FakeChat();
      final c = make(fake);
      final m = msg('m1', conversation: 'c1');

      final result = await c.read(messagesProvider.notifier).forward(m, [
        'c2',
        'c3',
      ]);
      expect(result, isA<Ok<void>>());
      expect(fake.forwarded.single.messageId, 'm1');
      expect(fake.forwarded.single.conversationIds, ['c2', 'c3']);
    });

    test('on Ok, the chat list is re-read', () async {
      final fake = FakeChat(
        list: [const Conversation(id: 'c2', title: 'Group')],
      );
      final c = make(fake);
      // Prime the list once, the way the app always has it loaded already.
      await c.read(conversationListProvider.future);
      final readsBefore = fake.listReads;

      final result = await c.read(messagesProvider.notifier).forward(
        msg('m1'),
        ['c2'],
      );
      expect(result, isA<Ok<void>>());
      // reloadQuietly is fire-and-forget (unawaited): give it a turn.
      await Future<void>.delayed(Duration.zero);
      expect(
        fake.listReads,
        greaterThan(readsBefore),
        reason: 'forwarding must make the list current for its new preview',
      );
    });

    test('a refusal is returned and the list is not re-read', () async {
      final fake = FakeChat(list: const [])
        ..forwardResult = const Err(DeniedFailure());
      final c = make(fake);
      await c.read(conversationListProvider.future);
      final readsBefore = fake.listReads;

      final result = await c.read(messagesProvider.notifier).forward(
        msg('m1'),
        ['not-mine'],
      );
      expect(result, isA<Err<void>>());
      await Future<void>.delayed(Duration.zero);
      expect(fake.listReads, readsBefore);
    });
  });
}
