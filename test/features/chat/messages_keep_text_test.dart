// MessagesController, receive path case 12: a locked echo (placeholder body)
// of a message already shown readable keeps the shown text, both as a live
// insert and as a live edit. Written from the contract against ChatFake,
// whose Realtime delivers only to a live subscription.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

final _t0 = DateTime.now().subtract(const Duration(minutes: 30));

Message msg(String id, String body, {String from = 'u2', int m = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: _t0.add(Duration(minutes: m)),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  Message shown(String id) =>
      c.read(messagesProvider).requireValue.firstWhere((x) => x.id == id);

  setUp(() async {
    chat = ChatFake(self: me.userId)
      ..history['c1'] = [
        msg('m1', 'readable text', from: me.userId),
        msg('m2', 'from bob', m: 1),
      ];
    c = await settled(
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
    chat.confirmSubscription();
    await settle();
  });

  test(
    'a locked echo (insert) of a shown readable message keeps its text',
    () async {
      chat.deliver(msg('m1', lockedBodyPlaceholder, from: me.userId));
      chat.deliver(msg('m2', lockedBodyPlaceholder, m: 1));
      await settle();
      expect(shown('m1').body, 'readable text');
      expect(shown('m2').body, 'from bob');
    },
  );

  test('a locked echo of an edit keeps the shown text', () async {
    final echo = Message(
      id: 'm2',
      conversationId: 'c1',
      senderId: 'u2',
      body: lockedBodyPlaceholder,
      createdAt: _t0.add(const Duration(minutes: 1)),
      editedAt: DateTime.now(),
    );
    chat.deliver(echo);
    await settle();
    expect(shown('m2').body, 'from bob');
  });

  test('controls: a readable edit replaces the text; a locked row never '
      'shown readable shows the placeholder', () async {
    chat.deliver(
      Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u2',
        body: 'edited by bob',
        createdAt: _t0.add(const Duration(minutes: 1)),
        editedAt: DateTime.now(),
      ),
    );
    chat.deliver(msg('m3', lockedBodyPlaceholder, m: 2));
    await settle();
    expect(shown('m2').body, 'edited by bob');
    expect(shown('m3').body, lockedBodyPlaceholder);
  });
}
