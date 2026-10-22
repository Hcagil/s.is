// Private Chats 4b Group I: a Reply typed on an encrypted push reaches the
// send queue. Written from the contract, never from the code:
// - encryptedReplySenderProvider takes the waiting replies when built and on
//   every arrival, and queues each one under its tap-time id;
// - it drops a reply for another member, an id that is not a uuid, and text
//   over maxMessageLength; it takes nothing while nobody is signed in;
// - the queue keeps the chat's draft and reply target for it
//   (keepComposer: true); a plain enqueue still clears both;
// - an id already queued is returned, not queued twice.
// Seam: the sender mounted as SisApp mounts it, the real sender, the real SendQueueController and a chat repository
// that holds every send open, so what is queued stays observable.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/encrypted_reply_controller.dart';
import 'package:sis/features/chat/data/method_channel_encrypted_reply.dart';
import 'package:sis/features/chat/domain/encrypted_reply.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;

  @override
  Future<SessionState> build() async => initial;

  void set(SessionState s) => state = AsyncData(s);
}

/// The native side as the contract describes it: replies wait until taken,
/// a take empties them, `arrivals` fires when a new one lands.
class _Intake implements EncryptedReplyIntake {
  final waiting = <PendingReply>[];
  final _arrivals = StreamController<void>.broadcast();
  int takes = 0;

  void arrive(PendingReply r) {
    waiting.add(r);
    _arrivals.add(null);
  }

  @override
  Future<List<PendingReply>> take() async {
    takes++;
    final out = List.of(waiting);
    waiting.clear();
    return out;
  }

  @override
  Stream<void> get arrivals => _arrivals.stream;
}

const conv = 'c0000000-0000-4000-8000-000000000001';
const id1 = 'a0000000-0000-4000-8000-000000000001';
const id2 = 'a0000000-0000-4000-8000-000000000002';

PendingReply reply({
  String id = id1,
  String userId = 'u1',
  String text = 'on my way',
  String conversationId = conv,
}) => PendingReply(
  id: id,
  conversationId: conversationId,
  userId: userId,
  text: text,
);

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

final target = Message(
  id: 'b0000000-0000-4000-8000-000000000009',
  conversationId: conv,
  senderId: 'u2',
  body: 'the message being answered',
  createdAt: DateTime.utc(2026, 10, 20),
);

void main() {
  late HeldSendChat chat;
  late _Intake intake;
  late _Session session;

  /// Mounts the sender the way SisApp does: one build that watches the
  /// session and the sender (a sign-in rebuilds it, which re-reads the sender).
  Future<void> mount(WidgetTester t, ProviderContainer c) async {
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: Consumer(
          builder: (context, ref, _) {
            ref
              ..watch(sessionControllerProvider)
              ..watch(encryptedReplySenderProvider);
            return const SizedBox();
          },
        ),
      ),
    );
    await hop(t);
  }

  Future<ProviderContainer> start(
    WidgetTester t, {
    SessionState initial = const Allowed(me),
    bool sender = true,
  }) async {
    chat = HeldSendChat();
    intake = _Intake();
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(
          () => session = _Session(initial),
        ),
        encryptedReplyIntakeProvider.overrideWithValue(intake),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(sendQueueProvider, (_, _) {});
    await hop(t);
    await t.pump(const Duration(milliseconds: 1));
    if (sender) await mount(t, c);
    return c;
  }

  List<Message> queued(ProviderContainer c, [String chatId = conv]) =>
      c.read(sendQueueProvider)[chatId] ?? const <Message>[];

  group('encryptedReplySenderProvider', () {
    testWidgets('a waiting reply is queued at build under its tap-time id', (
      t,
    ) async {
      final c = await start(t, sender: false);
      intake.waiting.add(reply());
      await mount(t, c);
      expect(queued(c).map((m) => (m.id, m.body)), [(id1, 'on my way')]);
      expect(chat.asked.map((a) => (a.id, a.conversationId)), [(id1, conv)]);
    });

    testWidgets('an arrival is taken and queued', (t) async {
      final c = await start(t);
      expect(queued(c), isEmpty);
      intake.arrive(reply());
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
    });

    testWidgets('a reply for another member is dropped, the right one kept', (
      t,
    ) async {
      final c = await start(t);
      intake
        ..waiting.add(reply(id: id2, userId: 'u2'))
        ..arrive(reply());
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
      expect(chat.asked.map((a) => a.id), [id1]);
    });

    testWidgets('an id that is not a uuid is dropped', (t) async {
      final c = await start(t);
      for (final bad in ['', 'not-a-uuid', '${id1}x', id1.substring(1)]) {
        intake.arrive(reply(id: bad));
        await hop(t);
      }
      expect(queued(c), isEmpty);
      expect(chat.asked, isEmpty);
    });

    testWidgets('text over maxMessageLength is dropped; exactly at it is '
        'queued', (t) async {
      final c = await start(t);
      intake.arrive(reply(text: 'x' * (maxMessageLength + 1)));
      await hop(t);
      expect(queued(c), isEmpty);
      expect(chat.asked, isEmpty);
      // Not taken in as a failed send either: the chat's composer is untouched.
      expect(c.read(draftsProvider)[conv]?.text ?? '', '');
      expect(c.read(draftsProvider)[conv]?.failure, isNull);
      intake.arrive(reply(id: id2, text: 'y' * maxMessageLength));
      await hop(t);
      expect(queued(c).map((m) => m.id), [id2]);
    });

    testWidgets('nobody signed in: nothing is taken (replies wait natively); '
        'after sign-in they are queued', (t) async {
      final c = await start(t, initial: const SignedOut());
      intake.arrive(reply());
      await hop(t);
      expect(intake.takes, 0, reason: 'took replies while signed out');
      expect(intake.waiting, hasLength(1));
      session.set(const Allowed(me));
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
    });

    // Nothing in the tree watches the session: only the sender's own
    // dependencies can re-run it on sign-in. (The container sits in a scope,
    // as in production; an unmounted container never flushes the rebuild.)
    testWidgets('after sign-in the sender picks up by itself, mounted '
        "without SisApp's session watch", (t) async {
      final c = await start(t, initial: const SignedOut(), sender: false);
      await t.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()),
      );
      c.listen(encryptedReplySenderProvider, (_, _) {});
      await hop(t);
      intake.arrive(reply());
      await hop(t);
      expect(intake.takes, 0, reason: 'took replies while signed out');
      session.set(const Allowed(me));
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
    });

    // Group J: the sender's own dependency on the signed-in member is what
    // re-runs it; mounted without SisApp's session watch, as above.
    Future<ProviderContainer> bare(WidgetTester t, SessionState initial) async {
      final c = await start(t, initial: initial, sender: false);
      await t.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SizedBox()),
      );
      c.listen(encryptedReplySenderProvider, (_, _) {});
      await hop(t);
      return c;
    }

    testWidgets('after sign-out it stops taking replies, mounted without '
        "SisApp's session watch", (t) async {
      final c = await bare(t, const Allowed(me));
      intake.arrive(reply());
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1], reason: 'setup: signed in');
      session.set(const SignedOut());
      await hop(t);
      final before = intake.takes;
      intake.arrive(reply(id: id2));
      await hop(t);
      expect(intake.takes, before, reason: 'took a reply while signed out');
      expect(intake.waiting.map((r) => r.id), [id2], reason: 'left waiting');
    });

    testWidgets('another member signs in: a reply of the first member is '
        'dropped, the new member\'s is queued', (t) async {
      final c = await bare(t, const SignedOut());
      intake.arrive(reply(userId: 'u1'));
      await hop(t);
      session.set(const Allowed(Member(userId: 'u7', displayName: 'Zed')));
      await hop(t);
      intake.arrive(reply(id: id2, userId: 'u7'));
      await hop(t);
      expect(queued(c).map((m) => m.id), [id2]);
      expect(chat.asked.map((a) => a.id), [id2]);
    });

    testWidgets('the same reply delivered twice is queued once', (t) async {
      final c = await start(t);
      intake.arrive(reply());
      await hop(t);
      intake.arrive(reply());
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
      expect(chat.asked, hasLength(1));
    });

    testWidgets('a reply keeps the chat draft and the live reply target', (
      t,
    ) async {
      final c = await start(t);
      c.read(draftsProvider.notifier)
        ..setText(conv, 'half a sentence')
        ..setReply(conv, target);
      c.read(replyingToProvider.notifier).start(target);
      intake.arrive(reply());
      await hop(t);
      expect(queued(c).map((m) => m.id), [id1]);
      expect(c.read(draftsProvider)[conv]?.text, 'half a sentence');
      expect(c.read(draftsProvider)[conv]?.replyTo?.id, target.id);
      expect(c.read(replyingToProvider)?.id, target.id);
    });
  });

  group('SendQueueController.enqueue', () {
    testWidgets('default clears the chat draft and the live reply target', (
      t,
    ) async {
      final c = await start(t, sender: false);
      c.read(draftsProvider.notifier)
        ..setText(conv, 'typed')
        ..setReply(conv, target);
      c.read(replyingToProvider.notifier).start(target);
      c.read(sendQueueProvider.notifier).enqueue(conv, body: 'typed');
      await hop(t);
      expect(c.read(draftsProvider)[conv]?.text ?? '', '');
      expect(c.read(draftsProvider)[conv]?.replyTo, isNull);
      expect(c.read(replyingToProvider), isNull);
    });

    testWidgets('keepComposer: true keeps both', (t) async {
      final c = await start(t, sender: false);
      c.read(draftsProvider.notifier)
        ..setText(conv, 'typed')
        ..setReply(conv, target);
      c.read(replyingToProvider.notifier).start(target);
      c
          .read(sendQueueProvider.notifier)
          .enqueue(conv, body: 'other', id: id1, keepComposer: true);
      await hop(t);
      expect(c.read(draftsProvider)[conv]?.text, 'typed');
      expect(c.read(draftsProvider)[conv]?.replyTo?.id, target.id);
      expect(c.read(replyingToProvider)?.id, target.id);
    });

    testWidgets('a given id is used; the same id twice returns the first', (
      t,
    ) async {
      final c = await start(t, sender: false);
      final q = c.read(sendQueueProvider.notifier);
      final a = q.enqueue(conv, body: 'first', id: id1);
      final b = q.enqueue(conv, body: 'second', id: id1);
      await hop(t);
      expect(a.id, id1);
      expect(b.id, id1);
      expect(b.body, 'first');
      expect(queued(c).map((m) => m.body), ['first']);
      expect(chat.asked, hasLength(1));
    });
  });

  group('MethodChannelEncryptedReply', () {
    const channel = MethodChannel('test/encrypted_reply');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('take maps good entries and skips bad ones', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return [
          {'id': id1, 'conversation_id': conv, 'user_id': 'u1', 'text': 'hi'},
          {'id': id2, 'conversation_id': conv, 'user_id': 'u1'},
          {'id': 7, 'conversation_id': conv, 'user_id': 'u1', 'text': 'x'},
          'not a map',
          null,
        ];
      });
      final got = await MethodChannelEncryptedReply(channel: channel).take();
      expect(calls, ['take']);
      expect(got.map((r) => (r.id, r.conversationId, r.userId, r.text)), [
        (id1, conv, 'u1', 'hi'),
      ]);
    });

    test('a channel error is an empty list, not a throw', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'boom'),
      );
      expect(await MethodChannelEncryptedReply(channel: channel).take(), []);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await MethodChannelEncryptedReply(channel: channel).take(), []);
    });

    test('a native "arrived" call fires arrivals', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final intake = MethodChannelEncryptedReply(channel: channel);
      final fired = intake.arrivals.first;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('arrived')),
        (_) {},
      );
      await fired.timeout(const Duration(seconds: 1));
    });
  });
}
