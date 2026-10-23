// Seam: SendQueueController's locked send -> ConversationListController, as
// production mounts them (same providers), with the REAL TextLocker and
// fakes for the server, key directory and Olm sessions. From the
// t_344c8711cf QA interface, never from the implementation:
// - the sender's own readable copy of a just-sent locked text becomes the
//   list preview, from us;
// - the server's placeholder echo (Realtime) may arrive BEFORE the send
//   answer (replaced in place) or AFTER it (never overwrites the text).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/text_locker.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/crypto/application/key_directory_controller.dart';
import 'package:sis/features/crypto/domain/key_directory.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/encrypted_send_fakes.dart';
import '../../support/fakes.dart';
import '../../support/key_directory_fakes.dart';
import '../../support/memory_send_queue_store.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

ClaimedKeys keysOf(String identity, {String otk = ''}) => ClaimedKeys(
  identityKey: identity,
  signingKey: 'sign-$identity',
  deviceSignature: 'sig-$identity',
  oneTimeKey: otk,
  isFallback: false,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// The server stores the locked row at once, but its answer to the phone is
/// held until [answer]: Realtime's echo can beat the answer.
class _HeldAnswer extends FakeEncryptedMessageRepository {
  _HeldAnswer() : super(self: me.userId);
  Completer<void>? gate;
  void answer() => gate!.complete();

  @override
  Future<Result<Message>> send({
    required String id,
    required String conversationId,
    required String ciphertext,
    required int olmType,
    String? replyTo,
    bool forwarded = false,
  }) async {
    final r = await super.send(
      id: id,
      conversationId: conversationId,
      ciphertext: ciphertext,
      olmType: olmType,
      replyTo: replyTo,
      forwarded: forwarded,
    );
    if (gate != null) await gate!.future;
    return r;
  }
}

class App {
  App() {
    final queue = MemorySendQueueStore();
    final engine = FakeSessionEngine(queue: queue)
      ..sessions['u2'] = {'idk-bob'};
    chat.conversationsResult = Ok([
      Conversation(
        id: 'c1',
        other: bob,
        lastMessage: 'earlier from bob',
        lastMessageAt: DateTime.utc(2026, 3, 1, 9),
        lastSenderId: bob.userId,
      ),
    ]);
    dir.identityAnswer = Ok(keysOf('idk-bob'));
    dir.claimAnswer = Ok(keysOf('idk-bob', otk: 'otk-1'));
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(store: queue),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        keyDirectoryProvider.overrideWithValue(dir),
        keyEngineProvider.overrideWithValue(keys),
        queuedCiphertextsProvider.overrideWithValue(queue),
        sessionEngineProvider.overrideWithValue(engine),
        encryptedMessageRepositoryProvider.overrideWithValue(enc),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(currentUserIdProvider, (_, _) {});
    c.listen(sendQueueProvider, (_, _) {});
    c.listen(conversationListProvider, (_, _) {});
  }

  final chat = ChatFake(self: me.userId);
  final log = <String>[];
  late final dir = FakeKeyDirectory(log);
  late final keys = FakeEngine(log);
  final enc = _HeldAnswer();
  late final ProviderContainer c;

  SendQueueController get q => c.read(sendQueueProvider.notifier);
  Conversation row() => c.read(conversationListProvider).value!.single;
}

/// Microtasks, zero timers and a little real time for the async fakes.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 10; j++) {
      await t.pump();
    }
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

/// An app whose list has loaded from the server.
Future<App> ready(WidgetTester t) async {
  final a = App();
  bool loaded() {
    final s = a.c.read(conversationListProvider);
    return s.hasValue && !s.isLoading && s.value!.isNotEmpty;
  }

  for (var i = 0; i < 50 && !loaded(); i++) {
    await hop(t);
  }
  expect(a.row().lastMessage, 'earlier from bob', reason: 'setup: loaded');
  return a;
}

void main() {
  testWidgets('no echo: the sent text is the preview, from us', (t) async {
    final a = await ready(t);
    a.q.enqueue('c1', body: 'meet at 6');
    await hop(t);
    expect(a.enc.sends, hasLength(1), reason: 'setup: sent locked');
    expect(a.row().lastMessage, 'meet at 6');
    expect(a.row().lastSenderId, me.userId);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('the placeholder echo arrives AFTER the send answer: the text '
      'stays', (t) async {
    final a = await ready(t);
    a.q.enqueue('c1', body: 'meet at 6');
    await hop(t);
    expect(a.row().lastMessage, 'meet at 6', reason: 'setup');
    final echo = a.enc.rows.values.single;
    expect(echo.body, lockedBodyPlaceholder, reason: 'setup: server row');
    a.chat.deliver(echo);
    await hop(t);
    expect(a.row().lastMessage, 'meet at 6');
    expect(a.row().lastSenderId, me.userId);
    expect(a.row().unread, 0, reason: 'our own message is never unread');
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('the placeholder echo arrives BEFORE the send answer: the text '
      'replaces it', (t) async {
    final a = await ready(t);
    a.enc.gate = Completer<void>();
    a.q.enqueue('c1', body: 'meet at 6');
    await hop(t);
    final echo = a.enc.rows.values.single;
    a.chat.deliver(echo);
    await hop(t);
    expect(
      a.row().lastMessage,
      lockedBodyPlaceholder,
      reason: 'setup: the echo came first',
    );
    a.enc.answer();
    await hop(t);
    expect(a.row().lastMessage, 'meet at 6');
    expect(a.row().lastSenderId, me.userId);
    expect(a.row().lastMessageAt, echo.createdAt);
    await t.pump(const Duration(seconds: 30));
  });
}
