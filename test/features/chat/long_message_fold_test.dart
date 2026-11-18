// test/features/chat/long_message_fold_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const hay = Member(userId: 'u3', displayName: 'Hayrullah Cagil');

Message msg(
  String id,
  String body, {
  String from = 'u1',
  DateTime? at,
  DateTime? editedAt,
  MessageDeletion? deletion,
  String? replyTo,
  bool forwarded = false,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: at ?? DateTime.now(),
  editedAt: editedAt,
  deletion: deletion,
  replyTo: replyTo,
  forwarded: forwarded,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> pump(
  WidgetTester tester,
  List<Message> history, {
  Size size = const Size(800, 9000),
  double textScale = 1,
  bool group = false,
  TextDirection? direction,
  bool reduceMotion = false,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final chat = ChatFake(self: me.userId)
    ..history['c1'] = history
    ..roster['c1'] = [me, bob, hay]
    ..membersResult = const Ok([me, bob, hay]);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
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
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(Brightness.light),
        builder: (context, child) {
          var c = child!;
          if (direction != null) {
            c = Directionality(textDirection: direction, child: c);
          }
          if (reduceMotion) {
            c = MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: c,
            );
          }
          return c;
        },
        home: MessageScreen(title: group ? 'Club' : 'Bob', group: group),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'something overflowed');
}

String sample(int n) => ('abcdefg hi' * (n ~/ 10 + 1)).substring(0, n);

String shown(WidgetTester t, String id) {
  final texts = t
      .widgetList<RichText>(
        find.descendant(
          of: find.byKey(ValueKey('message-$id')),
          matching: find.byType(RichText),
        ),
      )
      .map((r) => r.text.toPlainText());
  return texts.reduce((a, b) => a.length >= b.length ? a : b);
}

bool noLoneSurrogate(String s) {
  for (int i = 0; i < s.length; i++) {
    final code = s.codeUnitAt(i);
    if (0xD800 <= code && code <= 0xDBFF) {
      if (i + 1 >= s.length) return false;
      final next = s.codeUnitAt(i + 1);
      if (!(0xDC00 <= next && next <= 0xDFFF)) return false;
    } else if (0xDC00 <= code && code <= 0xDFFF) {
      if (i == 0) return false;
      final prev = s.codeUnitAt(i - 1);
      if (!(0xD800 <= prev && prev <= 0xDBFF)) return false;
    }
  }
  return true;
}

Rect bodyRect(WidgetTester t, String id) {
  final finder = find.descendant(
    of: find.byKey(ValueKey('message-$id')),
    matching: find.byType(RichText),
  );
  final best = t
      .widgetList<RichText>(finder)
      .reduce(
        (a, b) =>
            a.text.toPlainText().length >= b.text.toPlainText().length ? a : b,
      );
  return t.getRect(find.byWidget(best));
}

void main() {
  for (final (label, from) in [('own', 'u1'), ('other', 'u2')]) {
    group('$label: long message folding', () {
      testWidgets('$label: sample 1200 shows full text', (tester) async {
        final body = sample(1200);
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsNothing);
        expect(shown(tester, 'm1'), body);
      });

      testWidgets('$label: sample 1201 folds', (tester) async {
        final body = sample(1201);
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
        expect(shown(tester, 'm1'), body.substring(0, 1197));
      });

      testWidgets('$label: body a*1190 + 10 spaces + b*100', (tester) async {
        final body = '${'a' * 1190}${' ' * 10}${'b' * 100}';
        await pump(tester, [msg('m1', body, from: from)]);
        expect(shown(tester, 'm1'), 'a' * 1190);
      });

      testWidgets('$label: body a*1300', (tester) async {
        final body = 'a' * 1300;
        await pump(tester, [msg('m1', body, from: from)]);
        expect(shown(tester, 'm1'), 'a' * 1200);
      });

      testWidgets('$label: next grapheme is a space, cut exactly at 1200', (
        tester,
      ) async {
        final body = '${'a' * 100} ${'b' * 1099} ${'c' * 50}';
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
        expect(shown(tester, 'm1'), '${'a' * 100} ${'b' * 1099}');
      });

      testWidgets('$label: body a*100 + space + b*1300', (tester) async {
        final body = '${'a' * 100} ${'b' * 1300}';
        await pump(tester, [msg('m1', body, from: from)]);
        expect(shown(tester, 'm1'), 'a' * 100);
      });

      testWidgets('$label: emoji single surrogate', (tester) async {
        final body = '${'a' * 1199}\u{1F600}${'b' * 100}';
        await pump(tester, [msg('m1', body, from: from)]);
        expect(shown(tester, 'm1'), '${'a' * 1199}\u{1F600}');
        expect(noLoneSurrogate(shown(tester, 'm1')), isTrue);
      });

      testWidgets('$label: emoji complex surrogate', (tester) async {
        final body = '${'a' * 1198}\u{1F468}‍\u{1F469}‍\u{1F467}${'b' * 100}';
        await pump(tester, [msg('m1', body, from: from)]);
        expect(
          shown(tester, 'm1'),
          '${'a' * 1198}\u{1F468}‍\u{1F469}‍\u{1F467}b',
        );
      });

      testWidgets('$label: 601 emojis', (tester) async {
        final body = '\u{1F600}' * 601;
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsNothing);
        expect(shown(tester, 'm1'), body);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$label: 1201 emojis', (tester) async {
        final body = '\u{1F600}' * 1201;
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
        expect(shown(tester, 'm1'), '\u{1F600}' * 1200);
      });

      testWidgets('$label: sample 1500 fold/unfold', (tester) async {
        final body = sample(1500);
        await pump(tester, [msg('m1', body, from: from)]);
        final folded = shown(tester, 'm1');
        await tester.tap(find.byKey(const ValueKey('read-more')));
        await tester.pumpAndSettle();
        expect(shown(tester, 'm1'), body);
        expect(find.byKey(const ValueKey('read-less')), findsOneWidget);
        expect(find.byKey(const ValueKey('read-more')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('read-less')));
        await tester.pumpAndSettle();
        expect(shown(tester, 'm1'), folded);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
      });

      testWidgets('$label: sample 1500 fold/unfold with reduceMotion', (
        tester,
      ) async {
        final body = sample(1500);
        await pump(tester, [msg('m1', body, from: from)], reduceMotion: true);
        final folded = shown(tester, 'm1');
        await tester.tap(find.byKey(const ValueKey('read-more')));
        await tester.pumpAndSettle();
        expect(shown(tester, 'm1'), body);
        expect(find.byKey(const ValueKey('read-less')), findsOneWidget);
        expect(find.byKey(const ValueKey('read-more')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('read-less')));
        await tester.pumpAndSettle();
        expect(shown(tester, 'm1'), folded);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
      });

      testWidgets('$label: time on its own row when folded', (tester) async {
        final body = 'line\n' * 300;
        await pump(tester, [msg('m1', body, from: from)]);
        expect(find.byKey(const ValueKey('read-more')), findsOneWidget);
        expect(shown(tester, 'm1'), '${'line\n' * 239}line');
        final timeRect = tester.getRect(find.byKey(const ValueKey('time-m1')));
        expect(
          timeRect.top,
          greaterThanOrEqualTo(bodyRect(tester, 'm1').bottom - 0.5),
        );
        final buttonRect = tester.getRect(
          find.byKey(const ValueKey('read-more')),
        );
        expect(timeRect.top - buttonRect.bottom, inInclusiveRange(-0.5, 8));
      });

      testWidgets('$label: normal motion animates the size', (tester) async {
        await pump(tester, [msg('m1', sample(1500), from: from)]);
        final body = find.byKey(const ValueKey('body-m1'));
        expect(
          find.descendant(of: body, matching: find.byType(AnimatedSize)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: body, matching: find.byType(AnimatedSwitcher)),
          findsNothing,
        );
      });

      testWidgets('$label: reduced motion fades instead of resizing', (
        tester,
      ) async {
        await pump(tester, [
          msg('m1', sample(1500), from: from),
        ], reduceMotion: true);
        final body = find.byKey(const ValueKey('body-m1'));
        expect(
          find.descendant(of: body, matching: find.byType(AnimatedSwitcher)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: body, matching: find.byType(AnimatedSize)),
          findsNothing,
        );
      });
    });
  }

  group('limits', () {
    test('foldMessageAfter == 1200', () {
      expect(foldMessageAfter, 1200);
    });

    test('maxMessageLength == 4000', () {
      expect(maxMessageLength, 4000);
    });

    test('isSendableBody 4000 is true', () {
      expect(isSendableBody('a' * 4000), isTrue);
    });

    test('isSendableBody 4001 is false', () {
      expect(isSendableBody('a' * 4001), isFalse);
    });
  });
}
