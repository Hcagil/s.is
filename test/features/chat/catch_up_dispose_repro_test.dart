// Reproduces CI failure: "Cannot use the Ref of AsyncNotifierProvider<ConversationListController, ...> after it has been disposed"
// while ConversationListController.catchUp() is awaiting a repository read.
// The test verifies that catchUp completes quietly when the provider is
// disposed during its first re-read or while re-joining.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/application/push_controller.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
final _t0 = DateTime.utc(2026, 9, 29, 12);

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(maya);
}

void main() {
  late ChatFake chat;
  late PushSourceFake push;
  late ProviderContainer c;

  ProviderContainer make() => ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      pushSourceProvider.overrideWithValue(push),
      sessionControllerProvider.overrideWith(_In.new),
    ],
  );

  Future<void> loadList() async {
    c.listen(conversationListProvider, (_, _) {});
    await c.read(conversationListProvider.future);
    chat.confirmAllSubscription();
    await pumpEventQueue();
  }

  setUp(() async {
    chat = ChatFake(self: 'u1');
    push = PushSourceFake();
    chat.conversationsResult = Ok([
      Conversation(
        id: 'c1',
        title: 'Bob',
        lastMessage: 'hi',
        lastMessageAt: _t0.add(const Duration(minutes: 1)),
        lastSenderId: 'u2',
      ),
    ]);
    c = make();
    await c.read(sessionControllerProvider.future);
  });

  group('repro: catchUp after the list provider is disposed', () {
    test('catchUp ends quietly when the provider is disposed during its first re-read', () async {
      await loadList();
      final before = chat.calls.where((x) => x == 'conversations').length;
      chat.holdList();
      final done = c.read(conversationListProvider.notifier).catchUp();
      await pumpEventQueue();
      expect(
        chat.calls.where((x) => x == 'conversations').length,
        before + 1,
        reason: 'catchUp must be parked in its re-read, or this proves nothing',
      );
      c.dispose();
      chat.releaseList();
      await expectLater(done, completes);
      await pumpEventQueue();
    });

    test(
      'catchUp ends quietly when the provider is disposed while it re-joins',
      () async {
        await loadList();
        final joinsBefore = chat.calls.where((x) => x == 'incomingAll').length;
        chat.holdAllSubscription();
        final done = c.read(conversationListProvider.notifier).catchUp();
        await pumpEventQueue();
        expect(
          chat.calls.where((x) => x == 'incomingAll').length,
          joinsBefore + 1,
          reason: 'catchUp must be parked in its join, or this proves nothing',
        );
        c.dispose();
        chat.confirmAllSubscription();
        await expectLater(done, completes);
        await pumpEventQueue();
      },
    );
  });
}
