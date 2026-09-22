// ConversationListController against a fake repository: what it asks for,
// what it returns, and what it re-reads afterwards. The SDK is never here.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';

import '../../support/fakes.dart';

const bob = Member(userId: 'u2', displayName: 'Bob');
const withBob = Conversation(id: 'c1', other: bob);

ProviderContainer make(ChatFake fake) => ProviderContainer.test(
  overrides: [chatRepositoryProvider.overrideWithValue(fake)],
);

int count(ChatFake fake, String call) =>
    fake.calls.where((c) => c == call).length;

void main() {
  group('startGroup', () {
    test('passes the title and the members through unchanged', () async {
      final fake = ChatFake()..conversationsResult = const Ok([withBob]);
      final c = make(fake);
      await c.read(conversationListProvider.future);

      final result = await c
          .read(conversationListProvider.notifier)
          .startGroup(title: 'Weekend trip', memberIds: const ['u2', 'u3']);

      expect(result, isA<Ok<String>>());
      expect(fake.groups.single.title, 'Weekend trip');
      expect(fake.groups.single.memberIds, ['u2', 'u3']);
    });

    test('refreshes the list so the new group is in it', () async {
      final fake = ChatFake()..conversationsResult = const Ok([withBob]);
      final c = make(fake);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      expect(count(fake, 'conversations'), 1);

      final result = await c
          .read(conversationListProvider.notifier)
          .startGroup(title: 'Weekend trip', memberIds: const ['u2']);
      final id = (result as Ok<String>).value;

      expect(
        count(fake, 'conversations'),
        2,
        reason: 'the list was never re-read after creating a group',
      );
      expect(
        c.read(conversationListProvider).requireValue.map((x) => x.id),
        contains(id),
      );
    });

    test(
      'a second group with the same name is a second conversation',
      () async {
        final fake = ChatFake();
        final c = make(fake);
        await c.read(conversationListProvider.future);
        final notifier = c.read(conversationListProvider.notifier);

        final first = await notifier.startGroup(
          title: 'Weekend trip',
          memberIds: const ['u2'],
        );
        final second = await notifier.startGroup(
          title: 'Weekend trip',
          memberIds: const ['u2'],
        );

        expect(
          (second as Ok<String>).value,
          isNot((first as Ok<String>).value),
          reason: 'a group is never reused, unlike a 1:1',
        );
      },
    );

    test('a refusal comes back with its reason and keeps the list', () async {
      final fake = ChatFake()
        ..conversationsResult = const Ok([withBob])
        ..groupResult = const Err(DeniedFailure());
      final c = make(fake);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);

      final result = await c
          .read(conversationListProvider.notifier)
          .startGroup(title: 'Weekend trip', memberIds: const ['u2']);

      expect(result, isA<Err<String>>());
      expect((result as Err<String>).failure.message, isNotEmpty);
      final state = c.read(conversationListProvider);
      expect(state.hasError, isFalse, reason: 'a refusal emptied the list');
      expect(state.requireValue.map((x) => x.id), ['c1']);
    });
  });

  group('setDisplayName', () {
    test('sends the name, then re-reads the members and the list', () async {
      final fake = ChatFake()
        ..conversationsResult = const Ok([withBob])
        ..membersResult = const Ok([bob]);
      final c = make(fake);
      // Both are on screen at once on the home screen: the picker must not go
      // on showing the old name after a rename.
      c.listen(conversationListProvider, (_, _) {});
      c.listen(membersProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      await c.read(membersProvider.future);
      expect(count(fake, 'members'), 1);

      final result = await c
          .read(conversationListProvider.notifier)
          .setDisplayName('Maya R');

      expect(result, isA<Ok<void>>());
      expect(fake.renames, ['Maya R']);
      await c.read(membersProvider.future);
      expect(
        count(fake, 'members'),
        2,
        reason: 'the member picker was not invalidated after a rename',
      );
      expect(
        count(fake, 'conversations'),
        2,
        reason: 'the conversation list still shows the old name',
      );
    });

    test('a refusal comes back with its reason and keeps the list', () async {
      final fake = ChatFake()
        ..conversationsResult = const Ok([withBob])
        ..renameResult = const Err(
          ProviderFailure('a display name is 1 to 80 characters'),
        );
      final c = make(fake);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);

      final result = await c
          .read(conversationListProvider.notifier)
          .setDisplayName('');

      expect(result, isA<Err<void>>());
      expect(
        (result as Err<void>).failure.message,
        'a display name is 1 to 80 characters',
      );
      final state = c.read(conversationListProvider);
      expect(state.hasError, isFalse);
      expect(state.requireValue.map((x) => x.id), ['c1']);
    });
  });
}
