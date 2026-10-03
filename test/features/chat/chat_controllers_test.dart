import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

Message msg(
  String id, {
  String body = 'hi',
  int minute = 0,
  String from = 'me',
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
);

ProviderContainer make(FakeChat fake) => ProviderContainer.test(
  overrides: [chatRepositoryProvider.overrideWithValue(fake)],
);

void main() {
  group('conversation list', () {
    test('loads conversations', () async {
      final fake = FakeChat(
        list: [
          const Conversation(
            id: 'c1',
            other: Member(userId: 'u2', displayName: 'Bob'),
          ),
        ],
      );
      final c = make(fake);
      final list = await c.read(conversationListProvider.future);
      expect(list.single.other!.displayName, 'Bob');
    });

    test('a failure surfaces its reason, not a silent empty list', () async {
      final fake = FakeChat()
        ..conversationsResult = const Err(NetworkFailure('offline'));
      final c = make(fake);
      // Read through listen: `.future` never completes when build fails.
      // Read through listen: `.future` never completes on a failed build.
      c.listen(conversationListProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final state = c.read(conversationListProvider);
      expect(state, isA<AsyncError<List<Conversation>>>());
      expect(state.isLoading, isFalse, reason: 'must not spin forever');
      expect((state.error! as Failure).message, 'offline');
    });

    test('startWith calls the RPC and refreshes the list', () async {
      final fake = FakeChat();
      final c = make(fake);
      await c.read(conversationListProvider.future);
      final result = await c
          .read(conversationListProvider.notifier)
          .startWith('u2');
      expect(result, isA<Ok<String>>());
      expect(fake.started, ['u2']);
    });
  });

  group('messages', () {
    test('no open conversation means no subscription', () async {
      final fake = FakeChat();
      final c = make(fake);
      expect(await c.read(messagesProvider.future), isEmpty);
      expect(fake.subscriptions, 0);
    });

    test('opening a conversation loads its messages oldest first', () async {
      final fake = FakeChat(
        initial: [msg('m2', minute: 2), msg('m1', minute: 1)],
      );
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      final list = await c.read(messagesProvider.future);
      expect(list.map((m) => m.id), ['m1', 'm2']);
      expect(fake.subscriptions, 1);
    });

    test('a realtime message is appended', () async {
      final fake = FakeChat(initial: [msg('m1', minute: 1)]);
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      fake.deliver(msg('m2', minute: 2));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(messagesProvider).requireValue.map((m) => m.id), [
        'm1',
        'm2',
      ]);
    });

    test('a message already in the initial read is not duplicated', () async {
      final fake = FakeChat(initial: [msg('m1', minute: 1)]);
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      // The sender's own insert echoes back through Realtime.
      fake.deliver(msg('m1', minute: 1));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(messagesProvider).requireValue, hasLength(1));
    });

    test('messages arriving during the initial read are kept', () async {
      // The race the buffer exists for: subscribed, but the read has not
      // returned yet. Without the buffer this message is lost.
      final fake = FakeChat(initial: [msg('m1', minute: 1)])
        ..gate = Completer<void>();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      final pending = c.read(messagesProvider.future);
      await Future<void>.delayed(Duration.zero); // subscription registers
      fake.deliver(msg('m2', minute: 2));
      fake.gate!.complete();
      expect((await pending).map((m) => m.id), ['m1', 'm2']);
    });

    test('a queued send passes the body through; a refusal goes back to '
        'the draft', () async {
      final fake = FakeChat();
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      final queue = c.read(sendQueueProvider.notifier);

      final sent = queue.enqueue('c1', body: 'hello');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(fake.sent, ['hello']);
      expect(fake.sentIds, [sent.id]);

      fake.sendResult = const Err(DeniedFailure());
      queue.enqueue('c1', body: 'again');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final drafts = c.read(draftsProvider.notifier);
      expect(drafts.draftFor('c1').text, 'again');
      expect(drafts.consumeFailure('c1'), isA<DeniedFailure>());
    });

    test('a load failure surfaces its reason', () async {
      final fake = FakeChat()
        ..messagesResult = const Err(NetworkFailure('unreachable'));
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      c.listen(messagesProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final state = c.read(messagesProvider);
      expect(state, isA<AsyncError<List<Message>>>());
      expect(state.isLoading, isFalse, reason: 'must not spin forever');
      expect((state.error! as Failure).message, 'unreachable');
    });

    test('a message already vanished when the screen loads is not shown', () async {
      final vanished = Message(
        id: 'gone',
        conversationId: 'c1',
        senderId: 'u2',
        body: '',
        createdAt: DateTime.utc(2026, 9, 22, 12, 0),
        deletion: MessageDeletion.vanished,
      );
      final placeholder = Message(
        id: 'ph',
        conversationId: 'c1',
        senderId: 'u2',
        body: '',
        createdAt: DateTime.utc(2026, 9, 22, 12, 1),
        deletion: MessageDeletion.placeholder,
      );
      final fake = FakeChat(
        initial: [msg('m1', minute: 0), vanished, placeholder],
      );
      final c = make(fake);
      c.read(openConversationProvider.notifier).open('c1');
      final list = await c.read(messagesProvider.future);
      expect(
        list.map((m) => m.id),
        ['m1', 'ph'],
        reason:
            'a vanished message is as if never sent; a placeholder still shows',
      );
    });
  });

  group('optimistic delete and hide (0.30.8)', () {
    // ChatFake holds the write in flight: what the screen shows meanwhile is
    // the optimistic state, before any server answer.
    Future<(ProviderContainer, ChatFake)> open(List<Message> rows) async {
      final chat = ChatFake(
        self: 'me',
        latency: const Duration(milliseconds: 2),
      )..history['c1'] = [...rows];
      final c = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      );
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);
      return (c, chat);
    }

    List<Message> shown(ProviderContainer c) =>
        c.read(messagesProvider).requireValue;

    test(
      'delete for everyone: the placeholder shows before the server answers',
      () async {
        final (c, chat) = await open([msg('m1', body: 'oops')]);
        chat.holdWrite();
        final pending = c
            .read(messagesProvider.notifier)
            .deleteForEveryone(shown(c).single);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(chat.deleted, ['m1'], reason: 'the call is in flight');
        expect(shown(c).single.deletion, MessageDeletion.placeholder);
        expect(shown(c).single.body, '');

        chat.releaseWrite();
        expect(await pending, isA<Ok<void>>());
        expect(shown(c).single.deletion, MessageDeletion.placeholder);
      },
    );

    test('delete for everyone: an Err rolls the placeholder back', () async {
      final (c, chat) = await open([msg('m1', body: 'oops')]);
      chat
        ..deleteForEveryoneResult = const Err(DeniedFailure())
        ..holdWrite();
      final pending = c
          .read(messagesProvider.notifier)
          .deleteForEveryone(shown(c).single);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shown(c).single.deletion, MessageDeletion.placeholder);

      chat.releaseWrite();
      expect(await pending, isA<Err<void>>());
      final back = shown(c).single;
      expect(
        back.deletion,
        isNull,
        reason: 'the refusal undoes the placeholder',
      );
      expect(back.body, 'oops');
    });

    test('hide for me: gone at once, before the server answers', () async {
      final (c, chat) = await open([
        msg('m1', minute: 1, from: 'u2'),
        msg('m2', minute: 2, from: 'u2'),
      ]);
      chat.holdWrite();
      final pending = c
          .read(messagesProvider.notifier)
          .hideForMe(shown(c).first);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(chat.hidden, ['m1']);
      expect(shown(c).map((m) => m.id), ['m2']);

      chat.releaseWrite();
      expect(await pending, isA<Ok<void>>());
      expect(shown(c).map((m) => m.id), ['m2']);
    });

    test('hide for me: an Err puts it back in createdAt order', () async {
      final (c, chat) = await open([
        msg('m1', minute: 1, from: 'u2'),
        msg('m2', minute: 2, from: 'u2'),
        msg('m3', minute: 3, from: 'u2'),
      ]);
      chat
        ..hideForMeResult = const Err(NetworkFailure('offline'))
        ..holdWrite();
      final middle = shown(c).firstWhere((m) => m.id == 'm2');
      final pending = c.read(messagesProvider.notifier).hideForMe(middle);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(shown(c).map((m) => m.id), isNot(contains('m2')));

      chat.releaseWrite();
      expect(await pending, isA<Err<void>>());
      final ids = shown(c).map((m) => m.id).toList();
      expect(ids.toSet(), {'m1', 'm2', 'm3'});
      final times = shown(c).map((m) => m.createdAt).toList();
      final sorted = [...times]..sort();
      final reversed = sorted.reversed.toList();
      expect(
        times.toString() == sorted.toString() ||
            times.toString() == reversed.toString(),
        isTrue,
        reason: 're-inserted where it was, by createdAt; got $ids',
      );
      expect(ids.indexOf('m2'), 1, reason: 'between m1 and m3: $ids');
    });
  });

  group('delete for everyone', () {
    ProviderContainer makeWithCache(FakeChat fake, AttachmentCacheFake cache) =>
        ProviderContainer.test(
          overrides: [
            chatRepositoryProvider.overrideWithValue(fake),
            attachmentCacheProvider.overrideWithValue(cache),
          ],
        );

    test(
      'Ok leaves a placeholder at any age: no vanishing since 0.30.8',
      () async {
        // A forced Ok, with no window logic of its own: this isolates the
        // controller's own local update from the fake's simulated echo.
        final recent = Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'me',
          body: 'hi',
          createdAt: DateTime.now(),
        );
        final fake = FakeChat(initial: [recent])
          ..deleteForEveryoneResult = const Ok(null);
        final cache = AttachmentCacheFake();
        final c = makeWithCache(fake, cache);
        c.read(openConversationProvider.notifier).open('c1');
        await c.read(messagesProvider.future);

        final result = await c
            .read(messagesProvider.notifier)
            .deleteForEveryone(recent);
        expect(result, isA<Ok<void>>());
        final after = c.read(messagesProvider).requireValue.single;
        expect(after.deletion, MessageDeletion.placeholder);
        expect(after.body, '', reason: 'a placeholder carries no text');
      },
    );

    test('Err is returned and leaves state unchanged', () async {
      final live = msg('m1', minute: 0);
      final fake = FakeChat(initial: [live])
        ..deleteForEveryoneResult = const Err(DeniedFailure());
      final cache = AttachmentCacheFake();
      final c = makeWithCache(fake, cache);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c
          .read(messagesProvider.notifier)
          .deleteForEveryone(live);
      expect(result, isA<Err<void>>());
      final after = c.read(messagesProvider).requireValue.single;
      expect(
        after.deletion,
        isNull,
        reason: 'a refusal must not touch local state',
      );
      expect(after.body, live.body);
    });

    test('a live deletion replaces the message and removes its photo from the cache', () async {
      final withPhoto = Message(
        id: 'p1',
        conversationId: 'c1',
        senderId: 'u2',
        body: 'look',
        createdAt: DateTime.now(),
        attachmentPath: 'c1/1.png',
      );
      final fake = FakeChat(initial: [withPhoto]);
      final cache = AttachmentCacheFake();
      await cache.write('c1/1.png', Uint8List(0));
      final c = makeWithCache(fake, cache);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      // Delivered the way Realtime would: the wiped row, vanished (recent).
      fake.deliver(
        Message(
          id: 'p1',
          conversationId: 'c1',
          senderId: 'u2',
          body: '',
          createdAt: withPhoto.createdAt,
          deletion: MessageDeletion.vanished,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final after = c.read(messagesProvider).requireValue.single;
      expect(after.deletion, MessageDeletion.vanished);
      expect(
        after.body,
        'look',
        reason: 'a vanishing message keeps its text briefly, for the animation',
      );
      expect(cache.removed, contains('c1/1.png'));
    });

    test(
      'a live deletion delivered as a placeholder shows empty at once',
      () async {
        final live = msg('m1', minute: 0, body: 'old text');
        final fake = FakeChat(initial: [live]);
        final cache = AttachmentCacheFake();
        final c = makeWithCache(fake, cache);
        c.read(openConversationProvider.notifier).open('c1');
        await c.read(messagesProvider.future);

        fake.deliver(
          Message(
            id: 'm1',
            conversationId: 'c1',
            senderId: 'me',
            body: '',
            createdAt: live.createdAt,
            deletion: MessageDeletion.placeholder,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final after = c.read(messagesProvider).requireValue.single;
        expect(after.deletion, MessageDeletion.placeholder);
        expect(
          after.body,
          '',
          reason: 'a placeholder carries nothing, unlike a vanishing message',
        );
      },
    );
  });
}
