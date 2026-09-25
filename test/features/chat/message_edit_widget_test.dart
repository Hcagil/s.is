// Editing a message, as the member sees it: when the long-press sheet offers
// Edit, the edit bar and the prefilled composer, cancel, save, the empty
// caption rule, Edit vs Reply, a refused edit, and the bubble's time with its
// "edited" mark. Written from the contract -- what is on screen and what the
// repository is asked -- never from how the widgets are built.
//
// Run under TZ=JST-9 like every unit test: the times below are UTC instants
// and the bubble must show them in local time.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  DateTime? createdAt,
  String? attachmentPath,
  bool forwarded = false,
  MessageDeletion? deletion,
  DateTime? editedAt,
  bool pending = false,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: createdAt ?? DateTime.now().subtract(const Duration(minutes: 5)),
  attachmentPath: attachmentPath,
  forwarded: forwarded,
  deletion: deletion,
  editedAt: editedAt,
  localImage: pending ? pngBytes : null,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat, {
  bool settle = true,
}) async {
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}

/// A few bounded frames, for screens with an animation that never ends (a
/// pending photo's spinner), where pumpAndSettle would time out.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder bubble(String id) => find.byKey(ValueKey('message-$id'));
final editAction = find.byKey(const ValueKey('action-edit'));
final editBar = find.byKey(const ValueKey('edit-bar'));
final editCancel = find.byKey(const ValueKey('edit-cancel'));
final replyAction = find.byKey(const ValueKey('action-reply'));
final replyBar = find.byKey(const ValueKey('reply-bar'));
final field = find.byKey(const ValueKey('composer-field'));
final send = find.byKey(const ValueKey('composer-send'));

String composerText(WidgetTester tester) =>
    tester.widget<TextField>(field).controller!.text;

/// Every piece of text rendered under [of], in tree order, space-joined.
String textIn(WidgetTester tester, Finder of) => [
  for (final e
      in find.descendant(of: of, matching: find.byType(RichText)).evaluate())
    (e.widget as RichText).text.toPlainText(),
].join(' ');

Future<void> longPress(WidgetTester tester, String id) async {
  await tester.longPress(bubble(id));
  await tester.pumpAndSettle();
}

Future<void> startEdit(WidgetTester tester, String id) async {
  await longPress(tester, id);
  await tester.tap(editAction);
  await tester.pumpAndSettle();
}

void main() {
  group('what long-press offers', () {
    testWidgets('your own fresh text message offers Edit', (tester) async {
      final chat = ChatFake(self: me.userId)..history['c1'] = [msg('m1')];
      await pump(tester, chat);
      await longPress(tester, 'm1');
      expect(editAction, findsOneWidget);
    });

    testWidgets('your own fresh photo offers Edit (its caption)', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('p1', body: 'caption', attachmentPath: 'c1/1.png'),
        ]
        ..store('c1/1.png');
      await pump(tester, chat);
      await longPress(tester, 'p1');
      expect(editAction, findsOneWidget);
    });

    testWidgets('somebody else\'s message never offers Edit', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: bob.userId)];
      await pump(tester, chat);
      await longPress(tester, 'm1');
      expect(replyAction, findsOneWidget, reason: 'the sheet did open');
      expect(editAction, findsNothing);
    });

    testWidgets('your own forwarded message never offers Edit', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', forwarded: true)];
      await pump(tester, chat);
      await longPress(tester, 'm1');
      expect(replyAction, findsOneWidget, reason: 'the sheet did open');
      expect(editAction, findsNothing);
    });

    testWidgets('your own message 6 hours old no longer offers Edit', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg(
            'm1',
            createdAt: DateTime.now().subtract(
              const Duration(hours: 6, seconds: 1),
            ),
          ),
        ];
      await pump(tester, chat);
      await longPress(tester, 'm1');
      expect(replyAction, findsOneWidget, reason: 'the sheet did open');
      expect(editAction, findsNothing);
    });

    testWidgets('your own deleted message never offers Edit', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('m1', body: '', deletion: MessageDeletion.placeholder),
        ];
      await pump(tester, chat);
      await tester.longPress(find.byKey(const ValueKey('deleted-m1')));
      await tester.pumpAndSettle();
      expect(editAction, findsNothing);
    });

    testWidgets('your own photo still uploading never offers Edit', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', pending: true)];
      await pump(tester, chat, settle: false);
      await frames(tester);
      await tester.longPress(bubble('m1'));
      await frames(tester);
      expect(editAction, findsNothing);
    });
  });

  group('the edit bar', () {
    testWidgets('Edit shows the bar and prefills the composer with the body', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', body: 'see you at 5')];
      await pump(tester, chat);

      await startEdit(tester, 'm1');

      expect(editBar, findsOneWidget);
      expect(
        find.descendant(of: editBar, matching: find.text('Editing message')),
        findsOneWidget,
      );
      expect(composerText(tester), 'see you at 5');
    });

    testWidgets('Cancel closes the bar, empties the composer, saves nothing', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', body: 'see you at 5')];
      await pump(tester, chat);
      await startEdit(tester, 'm1');
      await tester.enterText(field, 'see you at 6');
      await tester.pump();

      await tester.tap(editCancel);
      await tester.pumpAndSettle();

      expect(editBar, findsNothing);
      expect(composerText(tester), isEmpty);
      expect(chat.edits, isEmpty);
      expect(chat.sent, isEmpty);
      expect(textIn(tester, bubble('m1')), contains('see you at 5'));
      expect(textIn(tester, bubble('m1')), isNot(contains('edited')));
    });

    testWidgets('saving edits the message in place: no new message is sent', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('m1', body: 'see you at 5'),
          msg('m2', from: bob.userId, body: 'ok'),
        ];
      await pump(tester, chat);
      await startEdit(tester, 'm1');

      await tester.enterText(field, 'see you at 6');
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(chat.edits, [(messageId: 'm1', body: 'see you at 6')]);
      expect(chat.sent, isEmpty, reason: 'an edit is never a new message');
      expect(editBar, findsNothing);
      expect(composerText(tester), isEmpty);
      expect(textIn(tester, bubble('m1')), contains('see you at 6'));
      expect(textIn(tester, bubble('m1')), contains('edited'));
      expect(find.text('see you at 5'), findsNothing);
      expect(
        tester.getTopLeft(bubble('m1')).dy,
        lessThan(tester.getTopLeft(bubble('m2')).dy),
        reason: 'the edited message stays where it was, above the reply',
      );
    });

    testWidgets('a photo\'s caption can be emptied', (tester) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('p1', body: 'a caption', attachmentPath: 'c1/1.png'),
        ]
        ..store('c1/1.png');
      await pump(tester, chat);
      await startEdit(tester, 'p1');
      expect(composerText(tester), 'a caption');

      await tester.enterText(field, '');
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(chat.edits, [(messageId: 'p1', body: '')]);
      expect(editBar, findsNothing);
      expect(find.text('a caption'), findsNothing);
    });

    testWidgets('a text message cannot be emptied: nothing is saved', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', body: 'keep me')];
      await pump(tester, chat);
      await startEdit(tester, 'm1');

      await tester.enterText(field, '   ');
      await tester.pump();
      await tester.tap(send, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(chat.edits, isEmpty, reason: 'refused before reaching the server');
      expect(chat.sent, isEmpty);
      expect(textIn(tester, bubble('m1')), contains('keep me'));
    });

    testWidgets('a refused edit shows why and keeps the message as it was', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', body: 'original')]
        ..editMessageResult = const Err(DeniedFailure());
      await pump(tester, chat);
      await startEdit(tester, 'm1');

      await tester.enterText(field, 'changed');
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(chat.edits, hasLength(1));
      expect(
        find.textContaining(const DeniedFailure().message),
        findsOneWidget,
      );
      expect(textIn(tester, bubble('m1')), contains('original'));
      expect(textIn(tester, bubble('m1')), isNot(contains('edited')));
    });
  });

  group('Edit and Reply are mutually exclusive', () {
    testWidgets('Edit after Reply replaces the reply bar', (tester) async {
      final chat = ChatFake(
        self: me.userId,
      )..history['c1'] = [msg('m1', from: bob.userId), msg('m2', body: 'mine')];
      await pump(tester, chat);
      await longPress(tester, 'm1');
      await tester.tap(replyAction);
      await tester.pumpAndSettle();
      expect(replyBar, findsOneWidget);

      await startEdit(tester, 'm2');

      expect(editBar, findsOneWidget);
      expect(replyBar, findsNothing);
    });

    testWidgets('Reply after Edit replaces the edit bar', (tester) async {
      final chat = ChatFake(
        self: me.userId,
      )..history['c1'] = [msg('m1', from: bob.userId), msg('m2', body: 'mine')];
      await pump(tester, chat);
      await startEdit(tester, 'm2');
      expect(editBar, findsOneWidget);

      await longPress(tester, 'm1');
      await tester.tap(replyAction);
      await tester.pumpAndSettle();

      expect(replyBar, findsOneWidget);
      expect(editBar, findsNothing);
    });
  });

  testWidgets('Reply, then Edit, then Cancel: the reply is gone too, so the '
      'next message is not a reply', (tester) async {
    final chat = ChatFake(self: me.userId)
      ..history['c1'] = [msg('m1', from: bob.userId), msg('m2', body: 'mine')];
    await pump(tester, chat);
    await longPress(tester, 'm1');
    await tester.tap(replyAction);
    await tester.pumpAndSettle();
    await startEdit(tester, 'm2');
    await tester.tap(editCancel);
    await tester.pumpAndSettle();

    expect(replyBar, findsNothing);
    await tester.enterText(field, 'a fresh message');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(chat.sent.single.replyTo, isNull);
  });

  group('the bubble\'s time and edited mark', () {
    // 00:05 local time today, handed over as a UTC instant the way the
    // repository could: under JST-9 that is 15:05 UTC the day before, so a
    // bubble that forgets to convert shows the wrong time. Today, so the
    // test does not depend on the date it runs.
    final today = DateTime.now();
    final sentAt = DateTime(today.year, today.month, today.day, 0, 5).toUtc();
    const shownAt = '00:05';
    final utcAt =
        '${sentAt.hour.toString().padLeft(2, '0')}:'
        '${sentAt.minute.toString().padLeft(2, '0')}';

    test('the zone is not UTC, or the time checks below prove nothing', () {
      expect(utcAt, isNot(shownAt), reason: 'run with TZ=JST-9');
    });

    testWidgets('an edited message shows "edited" next to its local time', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg(
            'm1',
            from: bob.userId,
            createdAt: sentAt,
            editedAt: sentAt.add(const Duration(minutes: 3)),
          ),
        ];
      await pump(tester, chat);

      final text = textIn(tester, bubble('m1'));
      expect(text, matches(RegExp(r'edited\s+' + shownAt)));
      expect(text, isNot(contains(utcAt)), reason: 'shown in local time');
    });

    testWidgets('an unedited message shows its time and no mark', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [msg('m1', from: bob.userId, createdAt: sentAt)];
      await pump(tester, chat);

      final text = textIn(tester, bubble('m1'));
      expect(text, contains(shownAt));
      expect(text, isNot(contains('edited')));
    });

    testWidgets('a message from an earlier day still shows its HH:MM time', (
      tester,
    ) async {
      final days = DateTime(today.year, today.month, today.day - 3, 9, 41);
      final chat = ChatFake(
        self: me.userId,
      )..history['c1'] = [msg('m1', from: bob.userId, createdAt: days.toUtc())];
      await pump(tester, chat);

      expect(textIn(tester, bubble('m1')), contains('09:41'));
    });

    testWidgets('a deleted message shows neither time nor "edited"', (
      tester,
    ) async {
      // Even a row that still carried an edit time: a deleted message keeps
      // only who sent it and when, and shows no time at all.
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg(
            'm1',
            from: bob.userId,
            body: '',
            createdAt: sentAt,
            deletion: MessageDeletion.placeholder,
            editedAt: sentAt.add(const Duration(minutes: 3)),
          ),
        ];
      await pump(tester, chat);

      expect(
        textIn(tester, find.byKey(const ValueKey('deleted-m1'))),
        contains('This message was deleted'),
      );
      // The whole list, not only the placeholder's own subtree: the one
      // message on screen is the deleted one, so no time and no mark at all.
      final list = find.byType(Scrollable).first;
      final text = textIn(tester, list);
      expect(text, isNot(contains(shownAt)));
      expect(text, isNot(contains('edited')));
    });

    testWidgets('an edit arriving live updates the open bubble', (
      tester,
    ) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = [
          msg('m1', from: bob.userId, body: 'see you at 5', createdAt: sentAt),
        ];
      await pump(tester, chat);

      chat.serverEdit(chat.history['c1']!.single, 'see you at 6');
      await tester.pumpAndSettle();

      final text = textIn(tester, bubble('m1'));
      expect(text, contains('see you at 6'));
      expect(text, matches(RegExp(r'edited\s+' + shownAt)));
    });
  });
}
