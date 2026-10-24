// The top card's rules, from the contract of MessageNoticeController:
// consider(Conversation, Message) while another chat is open. Written by QA
// from the interface only; settings and mutes come through the real
// providers over NotificationSettingsFake, which answers after a delay as
// the server does.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_notice_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cem = Member(userId: 'u3', displayName: 'Cem');

DateTime at(int minute) => DateTime.utc(2026, 9, 22, 12, minute);

Conversation conv(
  String id, {
  Member other = bob,
  String text = 'hello',
  int minute = 30,
  bool archived = false,
}) => Conversation(
  id: id,
  other: other,
  lastMessage: text,
  lastMessageAt: at(minute),
  lastSenderId: other.userId,
  archived: archived,
);

Message msg(
  String chat, {
  String from = 'u2',
  String body = 'hello',
  int minute = 30,
}) => Message(
  id: '$chat-$minute-$from',
  conversationId: chat,
  senderId: from,
  body: body,
  createdAt: at(minute),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Signed in, chat [open] open, settings and mutes loaded (unless told
/// otherwise) and kept alive the way a screen keeps them.
Future<ProviderContainer> scope({
  String? open = 'cA',
  NotificationSettings settings = const NotificationSettings(),
  List<Mute> mutes = const [],
  bool loadSettings = true,
  bool loadMutes = true,
  bool mutesFail = false,
}) async {
  final notif = NotificationSettingsFake(
    settings: settings,
    mutes: mutes,
    latency: const Duration(milliseconds: 30),
  );
  if (mutesFail) notif.mutesResult = const Err(NetworkFailure('offline'));
  final c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(_SignedIn.new),
      notificationSettingsRepositoryProvider.overrideWithValue(notif),
    ],
  );
  await c.read(sessionControllerProvider.future);
  c.listen(messageNoticeProvider, (_, _) {});
  if (loadMutes || mutesFail) {
    c.listen(mutesProvider, (_, _) {});
    if (mutesFail) {
      await expectLater(c.read(mutesProvider.future), throwsA(anything));
      expect(c.read(mutesProvider).hasError, isTrue);
    } else {
      await c.read(mutesProvider.future);
    }
  }
  if (loadSettings) {
    c.listen(notificationSettingsProvider, (_, _) {});
    await c.read(notificationSettingsProvider.future);
  }
  if (open != null) c.read(openConversationProvider.notifier).open(open);
  return c;
}

MessageNoticeData? card(ProviderContainer c) => c.read(messageNoticeProvider);

void consider(ProviderContainer c, Conversation conv, Message m) =>
    c.read(messageNoticeProvider.notifier).consider(conv, m);

void main() {
  group('when a card is due', () {
    test('chat A open, message from B: card for B, count 1', () async {
      final c = await scope();
      consider(c, conv('cB'), msg('cB'));
      final d = card(c);
      expect(d, isNotNull);
      expect(d!.conversationId, 'cB');
      expect(d.senderId, 'u2');
      expect(d.preview, 'hello');
      expect(d.count, 1);
      expect(d.locked, isFalse);
      expect(d.textHidden, isFalse, reason: 'preview full, loaded, not locked');
    });

    // Own messages and older or duplicate deliveries are filtered where the
    // list hands messages over (the list knows the order): see the seam test
    // test/features/chat/message_notice_seam_test.dart.

    test('no chat open (the chat list): no card', () async {
      final c = await scope(open: null);
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
    });

    test('a message in the open chat: no card', () async {
      final c = await scope();
      consider(c, conv('cA'), msg('cA'));
      expect(card(c), isNull);
    });

    test('archived chat: no card', () async {
      final c = await scope();
      consider(c, conv('cB', archived: true), msg('cB'));
      expect(card(c), isNull);
    });

    test('muted chat: no card; another chat still gets one', () async {
      final c = await scope(
        mutes: const [Mute(kind: MuteKind.conversation, target: 'cB')],
      );
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
      consider(c, conv('cC', other: cem), msg('cC', from: 'u3'));
      expect(card(c)?.conversationId, 'cC');
    });

    test('muted person: no card from them', () async {
      final c = await scope(
        mutes: const [Mute(kind: MuteKind.person, target: 'u2')],
      );
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
    });

    test('a mute that has ended does not hold the card back', () async {
      final c = await scope(
        mutes: [
          Mute(
            kind: MuteKind.conversation,
            target: 'cB',
            until: DateTime.now().subtract(const Duration(hours: 1)),
          ),
        ],
      );
      consider(c, conv('cB'), msg('cB'));
      expect(card(c)?.conversationId, 'cB');
    });
  });

  group('one card at a time', () {
    test('second message from B: same card, count 2', () async {
      final c = await scope();
      consider(c, conv('cB', text: 'one'), msg('cB', body: 'one'));
      consider(
        c,
        conv('cB', text: 'two', minute: 31),
        msg('cB', body: 'two', minute: 31),
      );
      expect(card(c)!.conversationId, 'cB');
      expect(card(c)!.count, 2);
      expect(card(c)!.preview, 'two', reason: 'the newest message shows');
    });

    test('message from C replaces B with count 1', () async {
      final c = await scope();
      consider(c, conv('cB'), msg('cB'));
      consider(c, conv('cB', minute: 31), msg('cB', minute: 31));
      consider(c, conv('cC', other: cem), msg('cC', from: 'u3', minute: 32));
      expect(card(c)!.conversationId, 'cC');
      expect(card(c)!.senderId, 'u3');
      expect(card(c)!.count, 1);
    });

    test('dismiss clears the card; the next one starts at 1', () async {
      final c = await scope();
      consider(c, conv('cB'), msg('cB'));
      c.read(messageNoticeProvider.notifier).dismiss();
      expect(card(c), isNull);
      consider(c, conv('cB', minute: 31), msg('cB', minute: 31));
      expect(card(c)!.count, 1);
    });
  });

  // Contract additions A7 and A8 (security gate, manager decision).
  group('no card at all', () {
    test('A7: notifications turned off (enabled false): no card', () async {
      final c = await scope(
        settings: const NotificationSettings(enabled: false),
      );
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
    });

    test('A8: mutes still loading: no card', () async {
      final c = await scope(loadMutes: false);
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
    });

    test('A8: mutes failed to load: no card', () async {
      final c = await scope(mutesFail: true);
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNull);
    });
  });

  group('text hidden', () {
    test('locked placeholder: locked and text hidden', () async {
      final c = await scope();
      consider(
        c,
        conv('cB', text: lockedBodyPlaceholder),
        msg('cB', body: lockedBodyPlaceholder),
      );
      expect(card(c)!.locked, isTrue);
      expect(card(c)!.textHidden, isTrue);
    });

    for (final p in [NotificationPreview.sender, NotificationPreview.none]) {
      test('preview setting ${p.name}: text hidden, not locked', () async {
        final c = await scope(settings: NotificationSettings(preview: p));
        consider(c, conv('cB'), msg('cB'));
        expect(card(c)!.textHidden, isTrue);
        expect(card(c)!.locked, isFalse);
      });
    }

    test('settings not loaded (mutes loaded): card, text hidden', () async {
      final c = await scope(loadSettings: false);
      consider(c, conv('cB'), msg('cB'));
      expect(card(c), isNotNull, reason: 'nothing waits on the network');
      expect(card(c)!.textHidden, isTrue);
      expect(card(c)!.locked, isFalse);
    });
  });
}
