// MessageNoticeController.onReactionPush and reactionCardText, written by QA
// from the contract only. The opener is a fake that answers after a delay.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_notice_controller.dart';
import 'package:sis/features/chat/presentation/message_notice.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/reaction_push.dart';

import '../../support/l10n.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

/// A session the test can change while an opener is still running.
class _Switchable extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
  void become(SessionState s) => state = AsyncData(s);
}

ReactionPush push({
  String user = 'u1',
  String chat = 'cB',
  String reactor = 'u2',
  String? e = '👍',
  String? q,
  String? qk,
  String? ct,
}) => (
  userId: user,
  conversationId: chat,
  messageId: 'm1',
  reactorId: reactor,
  emoji: e,
  quote: q,
  quoteKind: qk,
  ciphertext: ct,
  olmType: ct == null ? null : 0,
);

Future<ProviderContainer> scope({
  String? open = 'cA',
  Future<OpenedReaction?> Function(ReactionPush)? opener,
}) async {
  final c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(_Switchable.new),
      if (opener != null) reactionPushOpenerProvider.overrideWithValue(opener),
    ],
  );
  await c.read(sessionControllerProvider.future);
  c.listen(messageNoticeProvider, (_, _) {});
  if (open != null) c.read(openConversationProvider.notifier).open(open);
  return c;
}

Future<void> react(ProviderContainer c, ReactionPush p) =>
    c.read(messageNoticeProvider.notifier).onReactionPush(p);

MessageNoticeData? card(ProviderContainer c) => c.read(messageNoticeProvider);

void main() {
  group('when the card shows', () {
    test('another chat open: card with the push fields, count 1', () async {
      final c = await scope();
      await react(c, push(e: '❤️', q: 'hi', qk: 'photo'));
      final d = card(c)!;
      expect(d.conversationId, 'cB');
      expect(d.senderId, 'u2');
      expect(d.count, 1);
      expect(d.locked, isFalse);
      expect(d.reaction, (emoji: '❤️', quote: 'hi', kind: 'photo'));
    });

    test('chat list (nothing open): no card', () async {
      final c = await scope(open: null);
      await react(c, push());
      expect(card(c), isNull);
    });

    test('same chat open: no card', () async {
      final c = await scope();
      await react(c, push(chat: 'cA'));
      expect(card(c), isNull);
    });

    test('push for another member: no card', () async {
      final c = await scope();
      await react(c, push(user: 'u9'));
      expect(card(c), isNull);
    });

    test('newer reaction replaces the older card', () async {
      final c = await scope();
      await react(c, push(chat: 'cB', e: '👍'));
      await react(c, push(chat: 'cC', reactor: 'u3', e: '😂'));
      final d = card(c)!;
      expect(d.conversationId, 'cC');
      expect(d.senderId, 'u3');
      expect(d.reaction!.emoji, '😂');
      expect(d.count, 1);
    });
  });

  group('private chat (ct)', () {
    test('emoji and quote come from the opener, not the push', () async {
      final c = await scope(
        opener: (p) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return (emoji: '🔥', quote: 'secret');
        },
      );
      await react(c, push(ct: 'x', e: 'plain', q: 'plainq', qk: 'photo'));
      expect(card(c)!.reaction, (emoji: '🔥', quote: 'secret', kind: null));
    });

    test('opener returns null: generic card', () async {
      final c = await scope(opener: (_) async => null);
      await react(c, push(ct: 'x', e: 'plain'));
      expect(card(c)!.reaction, (emoji: null, quote: null, kind: null));
    });

    test('opener throws: generic card, no error escapes', () async {
      final c = await scope(opener: (_) async => throw StateError('no key'));
      await react(c, push(ct: 'x'));
      expect(card(c)!.reaction!.emoji, isNull);
    });

    test('member moves into the pushed chat while opening: no card', () async {
      final gate = Completer<OpenedReaction?>();
      final c = await scope(opener: (_) => gate.future);
      final f = react(c, push(ct: 'x', chat: 'cB'));
      c.read(openConversationProvider.notifier).open('cB');
      gate.complete((emoji: '👍', quote: null));
      await f;
      expect(card(c), isNull);
    });

    test('member goes back to the chat list while opening: no card', () async {
      final gate = Completer<OpenedReaction?>();
      final c = await scope(opener: (_) => gate.future);
      final f = react(c, push(ct: 'x'));
      c.read(openConversationProvider.notifier).close();
      gate.complete((emoji: '👍', quote: null));
      await f;
      expect(card(c), isNull);
    });

    test('plain push never calls the opener', () async {
      var calls = 0;
      final c = await scope(
        opener: (_) async {
          calls++;
          return null;
        },
      );
      await react(c, push());
      expect(calls, 0);
      expect(card(c), isNotNull);
    });
  });

  group('own reaction and the user re-check', () {
    test('own reaction (reactor is the addressee): no card', () async {
      final c = await scope();
      await react(c, push(reactor: 'u1'));
      expect(card(c), isNull);
    });

    test(
      'own private reaction: no card and the opener is not called',
      () async {
        var calls = 0;
        final c = await scope(
          opener: (_) async {
            calls++;
            return (emoji: '👍', quote: null);
          },
        );
        await react(c, push(reactor: 'u1', ct: 'x'));
        expect(calls, 0);
        expect(card(c), isNull);
      },
    );

    for (final (name, next) in <(String, SessionState)>[
      ('signs out', const SignedOut()),
      ('is denied', const Denied()),
      (
        'is another member',
        const Allowed(Member(userId: 'u9', displayName: 'Zed')),
      ),
    ]) {
      test('session $name during a slow opener: no card', () async {
        final gate = Completer<OpenedReaction?>();
        final c = await scope(opener: (_) => gate.future);
        final f = react(c, push(ct: 'x'));
        (c.read(sessionControllerProvider.notifier) as _Switchable).become(
          next,
        );
        gate.complete((emoji: '👍', quote: null));
        await f;
        expect(card(c), isNull);
      });
    }

    test(
      'before the opener: wrong chat or wrong user never calls it',
      () async {
        var calls = 0;
        final c = await scope(
          opener: (_) async {
            calls++;
            return null;
          },
        );
        await react(c, push(ct: 'x', chat: 'cA')); // already in that chat
        await react(c, push(ct: 'x', user: 'u9')); // not this member's push
        c.read(openConversationProvider.notifier).close();
        await react(c, push(ct: 'x')); // chat list
        (c.read(sessionControllerProvider.notifier) as _Switchable).become(
          const SignedOut(),
        );
        c.read(openConversationProvider.notifier).open('cA');
        await react(c, push(ct: 'x')); // signed out
        expect(calls, 0);
        expect(card(c), isNull);
      },
    );

    testWidgets('opener never completes: generic card after 3 s', (t) async {
      final c = await scope(opener: (_) => Completer<OpenedReaction?>().future);
      final f = react(c, push(ct: 'x', e: 'plain'));
      await t.pump(const Duration(milliseconds: 2900));
      expect(card(c), isNull, reason: 'still waiting before 3 s');
      await t.pump(const Duration(milliseconds: 200));
      await f;
      expect(card(c)!.reaction, (emoji: null, quote: null, kind: null));
    });
  });

  group('reactionCardText', () {
    ReactionLine line(String? e, {String? q, String? k}) =>
        (emoji: e, quote: q, kind: k);

    test('English, every branch', () {
      final l = l10nEn;
      expect(reactionCardText(l, line(null)), 'New reaction to your message');
      expect(reactionCardText(l, line('')), 'New reaction to your message');
      expect(reactionCardText(l, line('👍', q: 'hi')), 'Reacted 👍 to: "hi"');
      expect(
        reactionCardText(l, line('👍', q: 'hi', k: 'photo')),
        'Reacted 👍 to: "hi"',
        reason: 'a quote wins over the media kind',
      );
      expect(
        reactionCardText(l, line('👍', q: '', k: 'photo')),
        'Reacted 👍 to your photo',
      );
      expect(
        reactionCardText(l, line('👍', k: 'video')),
        'Reacted 👍 to your video',
      );
      expect(
        reactionCardText(l, line('👍', k: 'sticker')),
        'Reacted 👍 to your sticker',
      );
      expect(
        reactionCardText(l, line('👍', k: 'voice')),
        'Reacted 👍 to your voice message',
      );
      expect(
        reactionCardText(l, line('👍', k: 'file')),
        'Reacted 👍 to your file',
      );
      expect(reactionCardText(l, line('👍')), 'Reacted 👍 to your message');
      expect(
        reactionCardText(l, line('👍', k: 'zzz')),
        'Reacted 👍 to your message',
      );
    });

    test('Turkish, every branch', () {
      final l = l10nTr;
      expect(reactionCardText(l, line(null)), 'Mesajınıza yeni tepki');
      expect(reactionCardText(l, line('')), 'Mesajınıza yeni tepki');
      expect(
        reactionCardText(l, line('👍', q: 'hi')),
        '"hi" mesajınıza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', q: 'hi', k: 'video')),
        '"hi" mesajınıza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', k: 'photo')),
        'Fotoğrafınıza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', k: 'video')),
        'Videonuza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', k: 'sticker')),
        'Çıkartmanıza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', k: 'voice')),
        'Sesli mesajınıza 👍 tepkisini verdi',
      );
      expect(
        reactionCardText(l, line('👍', k: 'file')),
        'Dosyanıza 👍 tepkisini verdi',
      );
      expect(reactionCardText(l, line('👍')), 'Mesajınıza 👍 tepkisini verdi');
    });
  });
}
