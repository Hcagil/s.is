// Closing the chat while "delete for everyone" or an edit is still in flight:
// the finished write must not touch a disposed controller (Riverpod throws on
// a Ref used after dispose). Contract: nothing is thrown; the local store
// update is skipped (the next open reloads).
import 'dart:async';

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
import '../../support/peer_key_fakes.dart' show MemoryMessageStore;
import '../../support/video_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async =>
      const Allowed(Member(userId: 'u1', displayName: 'Maya'));
}

Message _m(String id) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u1',
  body: 'text',
  createdAt: DateTime.now(), // inside the edit window
);

Future<void> _closedMidWrite(
  Future<Object?> Function(ProviderContainer c, ChatFake chat) start,
  void Function(ChatFake chat) hold,
  void Function(ChatFake chat) release,
) async {
  final chat = ChatFake()..history['c1'] = [_m('m1')];
  final c = ProviderContainer(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      messageStoreProvider.overrideWithValue(MemoryMessageStore()),
    ],
  );
  c.listen(currentUserIdProvider, (_, _) {});
  await c.read(sessionControllerProvider.future);
  c.listen(openConversationProvider, (_, _) {});
  c.listen(messagesProvider, (_, _) {});
  c.read(openConversationProvider.notifier).open('c1');
  await c.read(messagesProvider.future);
  chat.confirmSubscription();
  await Future<void>.delayed(const Duration(milliseconds: 30));

  hold(chat);
  final zoneErrors = <Object>[];
  Object? thrown;
  await runZonedGuarded(() async {
    final pending = start(c, chat);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    c.dispose(); // the member left the chat
    release(chat);
    try {
      await pending;
    } catch (e) {
      thrown = e;
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }, (e, _) => zoneErrors.add(e));

  expect(thrown, isNull, reason: 'the write threw after the chat closed');
  expect(zoneErrors, isEmpty);
}

void main() {
  test(
    'chat closed while delete-for-everyone is in flight: nothing throws',
    () => _closedMidWrite(
      (c, _) => c.read(messagesProvider.notifier).deleteForEveryone(_m('m1')),
      (chat) => chat.holdWrite(),
      (chat) => chat.releaseWrite(),
    ),
  );

  test(
    'chat closed while an edit is in flight: nothing throws',
    () => _closedMidWrite(
      (c, _) =>
          c.read(messagesProvider.notifier).editMessage(_m('m1'), 'new text'),
      (chat) => chat.holdEdit(),
      (chat) => chat.releaseEdit(),
    ),
  );
}
