// DraftsController: one conversation's unsent text, reply target and a
// failed send's notice, kept in memory per chat ("Unsent text stays in each
// chat", 2026-09-28). First drafted by a different model family from the
// contract alone, then judged and completed; never from the implementation.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  final testDate = DateTime.utc(2026, 9, 28);
  final testMessage = Message(
    id: 'm1',
    conversationId: 'c1',
    senderId: 'u2',
    body: 'hi',
    createdAt: testDate,
  );

  group('DraftsController', () {
    test(
      'draftFor on unknown conversation returns empty Draft and state is empty',
      () {
        final container = ProviderContainer.test();
        final controller = container.read(draftsProvider.notifier);

        final draft = controller.draftFor('c1');
        expect(draft.text, isEmpty);
        expect(draft.replyTo, isNull);
        expect(draft.failure, isNull);

        final state = container.read(draftsProvider);
        expect(state, isEmpty);
      },
    );

    test(
      'setText stores text per conversation; other conversation is independent',
      () {
        final container = ProviderContainer.test();
        final controller = container.read(draftsProvider.notifier);

        controller.setText('c1', 'hello');
        controller.setText('c2', 'world');

        final state = container.read(draftsProvider);
        expect(state['c1']!.text, 'hello');
        expect(state['c2']!.text, 'world');
      },
    );

    test(
      'empty draft is never stored: setText with empty string removes key',
      () {
        final container = ProviderContainer.test();
        final controller = container.read(draftsProvider.notifier);

        controller.setText('c1', '');
        expect(container.read(draftsProvider).containsKey('c1'), isFalse);

        // setText empty then setReply(null) should still leave no key
        controller.setText('c1', '');
        controller.setReply('c1', null);
        expect(container.read(draftsProvider).containsKey('c1'), isFalse);
      },
    );

    test('draft with empty text but a reply target is stored', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);

      controller.setReply('c1', testMessage);
      expect(container.read(draftsProvider).containsKey('c1'), isTrue);
      expect(controller.draftFor('c1').replyTo, testMessage);
    });

    test('setText keeps reply target; setReply keeps text', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);

      controller.setReply('c1', testMessage);
      controller.setText('c1', 'hello');
      expect(controller.draftFor('c1').replyTo, testMessage);
      expect(controller.draftFor('c1').text, 'hello');

      controller.setReply('c1', null);
      expect(controller.draftFor('c1').replyTo, isNull);
      expect(controller.draftFor('c1').text, 'hello');
    });

    test('clear removes the key; clearing one conversation leaves others', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);

      controller.setText('c1', 'hello');
      controller.setText('c2', 'world');
      controller.clear('c1');

      final state = container.read(draftsProvider);
      expect(state.containsKey('c1'), isFalse);
      expect(state.containsKey('c2'), isTrue);
      expect(state['c2']!.text, 'world');
    });

    test('restoreFailure on no draft: text is bodies joined, replyTo restored, consumeFailure returns same instance', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure = const NetworkFailure('x');

      controller.restoreFailure('c1', ['a', 'b'], testMessage, failure);

      final draft = controller.draftFor('c1');
      expect(draft.text, 'a\nb');
      expect(draft.replyTo, testMessage);
      expect(draft.failure, same(failure));

      final consumed = controller.consumeFailure('c1');
      expect(consumed, same(failure));
      expect(controller.draftFor('c1').failure, isNull);
    });

    test('restoreFailure with existing text: bodies are prepended', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure = const DeniedFailure();

      controller.setText('c1', 'typed since');
      controller.restoreFailure('c1', ['a', 'b'], testMessage, failure);

      final draft = controller.draftFor('c1');
      expect(draft.text, 'a\nb\ntyped since');
      expect(draft.replyTo, testMessage);
      expect(draft.failure, same(failure));
    });

    test('restoreFailure when draft already has its own reply target keeps the draft\'s own one', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure = const NetworkFailure('x');
      final otherMessage = Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u3',
        body: 'hey',
        createdAt: testDate,
      );

      controller.setReply('c1', otherMessage);
      controller.restoreFailure('c1', ['a', 'b'], testMessage, failure);

      final draft = controller.draftFor('c1');
      expect(draft.replyTo, otherMessage); // original reply target preserved
      expect(draft.text, 'a\nb');
      expect(draft.failure, same(failure));
    });

    test('restoreFailure with replyTo null keeps an existing reply target', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure = const DeniedFailure();

      controller.setReply('c1', testMessage);
      controller.restoreFailure('c1', ['a', 'b'], null, failure);

      final draft = controller.draftFor('c1');
      expect(draft.replyTo, testMessage); // original reply target preserved
      expect(draft.text, 'a\nb');
      expect(draft.failure, same(failure));
    });

    test('consumeFailure is read-once and keeps text and replyTo', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure = const NetworkFailure('x');

      controller.setText('c1', 'hello');
      controller.setReply('c1', testMessage);
      controller.restoreFailure('c1', ['a'], testMessage, failure);

      final first = controller.consumeFailure('c1');
      expect(first, same(failure));
      expect(controller.draftFor('c1').failure, isNull);
      expect(controller.draftFor('c1').text, 'a\nhello');
      expect(controller.draftFor('c1').replyTo, testMessage);

      final second = controller.consumeFailure('c1');
      expect(second, isNull);
    });

    test('restoreFailure twice before consumption: later bodies go in front of earlier', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);
      final failure1 = const NetworkFailure('first');
      final failure2 = const DeniedFailure();

      controller.restoreFailure('c1', ['a', 'b'], testMessage, failure1);
      controller.restoreFailure('c1', ['c', 'd'], testMessage, failure2);

      final draft = controller.draftFor('c1');
      expect(draft.text, 'c\nd\na\nb');
      expect(draft.replyTo, testMessage);
      expect(draft.failure, same(failure2));

      final consumed = controller.consumeFailure('c1');
      expect(consumed, same(failure2));
    });

    test('consumeFailure with nothing pending returns null and stores '
        'nothing', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);

      expect(controller.consumeFailure('c1'), isNull);
      expect(container.read(draftsProvider), isEmpty);
    });

    test('once the notice is shown and the text is emptied, nothing is '
        'left behind', () {
      final container = ProviderContainer.test();
      final controller = container.read(draftsProvider.notifier);

      controller.restoreFailure('c1', ['a'], null, const DeniedFailure());
      controller.consumeFailure('c1');
      controller.setText('c1', '');
      expect(container.read(draftsProvider).containsKey('c1'), isFalse);
    });
  });
}
