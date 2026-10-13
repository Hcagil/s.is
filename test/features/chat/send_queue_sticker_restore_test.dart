// Stickers and album cards go through the offline send queue (step 10a): the
// queue is saved by the real SharedPrefsSendQueueStore, so a sticker and an
// album card waiting when the app is killed come back on the next start, as
// the same messages (same client ids, so the server's retry is harmless),
// and are sent then. A retryable failure keeps them queued.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/data/shared_prefs_send_queue_store.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/sticker.dart';

import '../../support/held_send_chat.dart';
import '../../support/sticker_fakes.dart';
import '../../support/video_fakes.dart';

class _Session extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> hop(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 5; j++) {
        await t.pump(const Duration(milliseconds: 5));
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  /// One run of the app, with its own server fakes.
  Future<({ProviderContainer c, StickerRepoFake stickers, HeldSendChat chat})>
  run(WidgetTester t) async {
    final stickers = StickerRepoFake();
    final chat = HeldSendChat();
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(store: const SharedPrefsSendQueueStore()),
        chatRepositoryProvider.overrideWithValue(chat),
        stickerRepositoryProvider.overrideWithValue(stickers),
        recentStickerStoreProvider.overrideWithValue(RecentStickerStoreFake()),
        sessionControllerProvider.overrideWith(_Session.new),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(sendQueueProvider, (_, _) {});
    await hop(t);
    return (c: c, stickers: stickers, chat: chat);
  }

  List<Message> pending(ProviderContainer c) =>
      c.read(sendQueueProvider)['c1'] ?? const <Message>[];

  Future<Set<String>> keys() async =>
      (await SharedPreferences.getInstance()).getKeys();

  final s1 = starterStickerId(1);
  final answered = Message(
    id: 'm-text',
    conversationId: 'c1',
    senderId: 'u2',
    body: 'hi',
    createdAt: DateTime.utc(2026, 10, 10),
  );

  testWidgets('control: a text waiting when killed comes back (the harness '
      'restores at all)', (t) async {
    final a = await run(t);
    final m = a.c.read(sendQueueProvider.notifier).enqueue('c1', body: 'hey');
    await hop(t);
    a.c.dispose();
    final b = await run(t);
    expect([for (final x in pending(b.c)) x.id], [m.id]);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('a pending sticker shows at once as a sticker; sending it '
      'leaves the queue', (t) async {
    final a = await run(t);
    final m = a.c
        .read(sendQueueProvider.notifier)
        .enqueueSticker('c1', s1, replyTo: answered);
    await t.pump();
    expect(pending(a.c).single.id, m.id);
    expect(pending(a.c).single.stickerId, s1);
    expect(pending(a.c).single.body, '');
    expect(pending(a.c).single.sending, isTrue);
    await hop(t);
    final s = a.stickers.sends.single;
    expect(
      (s.conversationId, s.messageId, s.stickerId, s.replyTo, s.forwarded),
      ('c1', m.id, s1, 'm-text', false),
    );
    a.stickers.ok(0);
    await hop(t);
    expect(pending(a.c), isEmpty);
    expect(a.chat.asked, isEmpty, reason: 'a sticker is not a text send');
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('killed with a sticker and an album card waiting: the next start '
      'shows both, in order, and sends each with its own id', (t) async {
    final a = await run(t);
    final q = a.c.read(sendQueueProvider.notifier);
    final st = q.enqueueSticker('c1', s1, replyTo: answered);
    final card = q.enqueueStickerAlbum('c1', 'alb-1', 'Trip');
    await hop(t);
    expect(await keys(), contains('sis.sendqueue.u1'));
    a.c.dispose(); // killed; nothing was answered

    final b = await run(t);
    final back = pending(b.c);
    expect([for (final m in back) m.id], [st.id, card.id]);
    expect(back.first.stickerId, s1);
    expect(back.first.replyTo, 'm-text');
    expect(back.last.albumCard, isTrue);
    expect(back.last.body, 'Trip');
    expect(back.last.albumId, 'alb-1');
    expect(back.every((m) => m.sending), isTrue);

    // the restored queue sends them; answer each as it arrives
    for (var i = 0; i < 2; i++) {
      await hop(t);
      if (b.stickers.sends.length > i) b.stickers.ok(i);
    }
    await hop(t);
    expect(b.stickers.sends.length, 2);
    final bySticker = b.stickers.sends.firstWhere((s) => s.stickerId != null);
    final byCard = b.stickers.sends.firstWhere((s) => s.albumId != null);
    expect(
      (bySticker.messageId, bySticker.stickerId, bySticker.replyTo),
      (st.id, s1, 'm-text'),
    );
    expect(
      (byCard.messageId, byCard.albumId, byCard.conversationId),
      (card.id, 'alb-1', 'c1'),
    );
    expect(pending(b.c), isEmpty);
    expect(await keys(), isNot(contains('sis.sendqueue.u1')));
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('a retryable failure keeps the sticker queued and saved', (
    t,
  ) async {
    final a = await run(t);
    final m = a.c.read(sendQueueProvider.notifier).enqueueSticker('c1', s1);
    await hop(t);
    a.stickers.fail(0, const NetworkFailure('offline', retryable: true));
    await hop(t);
    expect([for (final x in pending(a.c)) x.id], [m.id]);
    expect(await keys(), contains('sis.sendqueue.u1'));
    a.c.dispose();

    final b = await run(t);
    expect(pending(b.c).single.id, m.id);
    expect(pending(b.c).single.stickerId, s1);
    await t.pump(const Duration(seconds: 30));
  });
}
