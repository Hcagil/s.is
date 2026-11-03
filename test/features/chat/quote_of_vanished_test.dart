// MessageScreen: a reply whose quoted message is not in the list says what
// became of it. Tombstone for the id in THIS chat -> quoteDeleted (EN/TR); no
// tombstone -> quoteOriginal; quoted message present -> its text; a tombstone
// of another chat has no effect; a tombstone written while the screen is open
// updates the quote at once. Written from the QA interface (t_a90e191cb2),
// never from the implementation; the store fake is the QA lead's own.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/vanished_store.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/peer_key_fakes.dart' show MemoryMessageStore;
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// Keeps tombstones as (chat, id) pairs.
class _Tombs extends MemoryMessageStore implements VanishedStore {
  final tombs = <(String, String)>{};
  @override
  Future<void> markVanished(String messageId, String conversationId) async {
    tombs.add((conversationId, messageId));
    rows.remove(messageId);
  }

  @override
  Future<Set<String>> vanishedIds(String conversationId) async => {
    for (final (c, id) in tombs)
      if (c == conversationId) id,
  };
}

final t0 = DateTime.utc(2026, 10, 5, 9);

Message _m(String id, String body, {String from = 'u2', int minute = 0}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: body,
      createdAt: t0.add(Duration(minutes: minute)),
    );

Message get _reply => Message(
  id: 'b',
  conversationId: 'c1',
  senderId: 'u2',
  body: 'my answer',
  createdAt: t0.add(const Duration(minutes: 5)),
  replyTo: 'a',
);

Future<(ChatFake, _Tombs)> _pump(
  WidgetTester t,
  List<Message> history,
  _Tombs store, {
  Locale locale = const Locale('en'),
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
        messageStoreProvider.overrideWithValue(store),
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
  await _spin(t);
  return (chat, store);
}

Future<void> _spin(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('the strings', () {
    expect(l10nEn.quoteDeleted, 'This message was deleted');
    expect(l10nEn.quoteOriginal, 'Original message');
    expect(l10nTr.quoteDeleted, 'Bu mesaj silindi');
    expect(l10nTr.quoteOriginal, 'Asıl mesaj');
  });

  for (final (locale, deleted, original) in [
    (const Locale('en'), 'This message was deleted', 'Original message'),
    (const Locale('tr'), 'Bu mesaj silindi', 'Asıl mesaj'),
  ]) {
    group(locale.languageCode, () {
      testWidgets('tombstone for the quoted id in this chat -> deleted', (
        t,
      ) async {
        final store = _Tombs()..tombs.add(('c1', 'a'));
        await _pump(t, [_reply], store, locale: locale);
        expect(find.text('my answer', findRichText: true), findsOneWidget);
        expect(find.text(deleted, findRichText: true), findsOneWidget);
        expect(find.text(original, findRichText: true), findsNothing);
      });

      testWidgets('no tombstone, quoted message absent -> original', (t) async {
        await _pump(t, [_reply], _Tombs(), locale: locale);
        expect(find.text(original, findRichText: true), findsOneWidget);
        expect(find.text(deleted, findRichText: true), findsNothing);
      });
    });
  }

  testWidgets('quoted message present and live -> its text, no tombstone '
      'text', (t) async {
    await _pump(t, [_m('a', 'the first words'), _reply], _Tombs());
    expect(
      find.text('the first words', findRichText: true),
      findsAtLeastNWidgets(2), // the bubble and the quote
    );
    expect(find.text('This message was deleted'), findsNothing);
    expect(find.text('Original message'), findsNothing);
  });

  testWidgets('a tombstone of ANOTHER chat has no effect', (t) async {
    final store = _Tombs()..tombs.add(('c2', 'a'));
    await _pump(t, [_reply], store);
    expect(find.text('Original message', findRichText: true), findsOneWidget);
    expect(find.text('This message was deleted'), findsNothing);
  });

  testWidgets('a tombstone written while the screen is open updates the '
      'quote without reopening', (t) async {
    final (chat, store) = await _pump(t, [_reply], _Tombs());
    expect(find.text('Original message', findRichText: true), findsOneWidget);
    chat.deliver(
      Message(
        id: 'a',
        conversationId: 'c1',
        senderId: 'u2',
        body: '',
        createdAt: t0,
        deletion: MessageDeletion.vanished,
      ),
    );
    await _spin(t);
    expect(store.tombs, contains(('c1', 'a')));
    expect(find.text('This message was deleted'), findsOneWidget);
    expect(find.text('Original message'), findsNothing);
  });
}
