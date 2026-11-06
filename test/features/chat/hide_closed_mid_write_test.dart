// Closing the chat while "delete for me" is still in flight: when the server
// answers Ok afterwards, the finished write must not touch a disposed
// controller (Riverpod throws on a Ref used after dispose). Contract: the
// returned future still gives the server's answer and nothing is thrown.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
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
  senderId: 'u2',
  body: 'text',
  createdAt: DateTime(2020),
);

void main() {
  test('chat closed while hide-for-me is in flight: nothing throws', () async {
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

    chat
      ..hideForMeResult = const Ok(null)
      ..holdWrite();
    final zoneErrors = <Object>[];
    Object? thrown;
    await runZonedGuarded(() async {
      final pending = c.read(messagesProvider.notifier).hideForMe(_m('m1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      c.dispose(); // the member left the chat
      chat.releaseWrite();
      try {
        await pending;
      } catch (e) {
        thrown = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }, (e, _) => zoneErrors.add(e));

    expect(thrown, isNull, reason: 'hideForMe threw after the chat closed');
    expect(zoneErrors, isEmpty);
  });
}
