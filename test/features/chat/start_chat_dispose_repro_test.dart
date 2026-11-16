// Reproduces CI failure: "Cannot use the Ref of AsyncNotifierProvider<ConversationListController, ...> after it has been disposed"
// while ConversationListController.startWith() is awaiting a repository call.
// The test verifies that startWith completes quietly when the provider is
// disposed during its repository call.

import 'dart:async';

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

class _HeldChat extends ChatFake {
  _HeldChat({required super.self});
  Completer<void>? startGate;
  Completer<void>? groupGate;
  final entered = <String>[];

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    entered.add('start:$otherUserId');
    await startGate?.future;
    return super.startDirectConversation(otherUserId);
  }

  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    entered.add('group:$title');
    await groupGate?.future;
    return super.startGroupConversation(title: title, memberIds: memberIds);
  }
}

void main() {
  late _HeldChat chat;
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
    chat = _HeldChat(self: 'u1');
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

  group('repro: starting a chat after the list provider is disposed', () {
    test('startWith ends quietly when the provider is disposed while the repository call is in flight', () async {
      await loadList();
      chat.startGate = Completer<void>();
      final Future<Result<String>> done = c
          .read(conversationListProvider.notifier)
          .startWith('u2');
      await pumpEventQueue();
      expect(
        chat.entered,
        contains('start:u2'),
        reason: 'startWith must be parked in the repository call, or this proves nothing',
      );
      c.dispose();
      chat.startGate!.complete();
      await expectLater(done, completes);
      await pumpEventQueue();
      final result = await done;
      expect(result, isA<Ok<String>>());
    });

    test('startGroup ends quietly when the provider is disposed while the repository call is in flight', () async {
      await loadList();
      chat.groupGate = Completer<void>();
      final Future<Result<String>> done = c
          .read(conversationListProvider.notifier)
          .startGroup(title: 'Team', memberIds: ['u2', 'u3']);
      await pumpEventQueue();
      expect(
        chat.entered,
        contains('group:Team'),
        reason: 'startGroup must be parked in the repository call, or this proves nothing',
      );
      c.dispose();
      chat.groupGate!.complete();
      await expectLater(done, completes);
      await pumpEventQueue();
      final result = await done;
      expect(result, isA<Ok<String>>());
    });
  });
}
