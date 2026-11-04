// A row whose stored body is the locked placeholder shows the app-language
// text chatLockedMessage, in the bubble and in the chat-list preview line;
// every other text is shown as it is. Written from the contract (t_8c161d4051),
// never from the implementation.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_opener.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_tile.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const enLocked = 'This message could not be opened.';
const trLocked = 'Bu mesaj açılamadı.';
const enOpening = 'Opening message…';
const trOpening = 'Mesaj açılıyor…';

class _Opening extends OpeningMessages {
  _Opening(this.rows);
  final List<Message> rows;
  @override
  List<Message> build() => rows;
}

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final t0 = DateTime.utc(2026, 10, 5, 9);

Message msg(String id, String body, {int minute = 0}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: body,
  createdAt: t0.add(Duration(minutes: minute)),
);

Future<void> pump(
  WidgetTester t,
  List<Message> history,
  Locale locale, {
  List<Message> opening = const [],
}) async {
  t.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final chat = ChatFake(self: me.userId)
    ..history['c1'] = history
    ..holdBytes();
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        openingMessagesProvider.overrideWith(() => _Opening(opening)),
      ],
    ),
  );
  addTearDown(c.dispose);
  c.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Finder inBubble(String id, String text) => find.descendant(
  of: find.byKey(ValueKey('message-$id')),
  matching: find.text(text, findRichText: true),
);

void main() {
  test('the strings', () {
    expect(l10nEn.chatLockedMessage, enLocked);
    expect(l10nTr.chatLockedMessage, trLocked);
    expect(l10nEn.chatOpeningMessage, enOpening);
    expect(l10nTr.chatOpeningMessage, trOpening);
  });

  group('chatPreviewLine', () {
    test('the placeholder becomes the app-language text', () {
      expect(chatPreviewLine(l10nEn, lockedBodyPlaceholder), enLocked);
      expect(chatPreviewLine(l10nTr, lockedBodyPlaceholder), trLocked);
    });

    test('other texts are unchanged, even ones that contain it', () {
      for (final s in [
        'merhaba',
        '$lockedBodyPlaceholder!',
        'a $lockedBodyPlaceholder',
        '🔒',
      ]) {
        expect(chatPreviewLine(l10nTr, s), s);
      }
    });
  });

  for (final (locale, text) in [
    (const Locale('en'), enLocked),
    (const Locale('tr'), trLocked),
  ]) {
    testWidgets('bubble of a locked row shows "$text"; a plain row its body', (
      t,
    ) async {
      await pump(t, [
        msg('m', lockedBodyPlaceholder),
        msg('p', 'merhaba', minute: 1),
      ], locale);
      expect(inBubble('m', text), findsOneWidget);
      expect(
        find.text(lockedBodyPlaceholder, findRichText: true),
        findsNothing,
      );
      expect(inBubble('p', 'merhaba'), findsOneWidget);
    });
  }

  for (final (locale, opening, failed) in [
    (const Locale('en'), enOpening, enLocked),
    (const Locale('tr'), trOpening, trLocked),
  ]) {
    testWidgets('bubble: a waiting locked row says "$opening", another locked '
        'row "$failed"', (t) async {
      final waiting = msg('w', lockedBodyPlaceholder);
      await pump(
        t,
        [waiting, msg('f', lockedBodyPlaceholder, minute: 1)],
        locale,
        opening: [waiting],
      );
      expect(inBubble('w', opening), findsOneWidget);
      expect(inBubble('w', failed), findsNothing);
      expect(inBubble('f', failed), findsOneWidget);
      expect(inBubble('f', opening), findsNothing);
    });
  }
}
