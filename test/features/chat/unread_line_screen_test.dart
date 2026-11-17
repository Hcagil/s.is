// test/features/chat/unread_line_screen_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
final _t0 = DateTime.utc(2026, 9, 1, 8);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

late ChatFake chat;
late ProviderContainer c;

Future<void> frames(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> open(
  WidgetTester t, {
  required List<Message> history,
  Future<int?>? unread,
  Locale? locale,
}) async {
  chat = ChatFake()..history['c1'] = history;
  c = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
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
        home: MessageScreen(title: 'Bob', initialUnread: unread),
      ),
    ),
  );
  await frames(t);
}

final scrollable = find
    .descendant(
      of: find.byType(MessageScreen),
      matching: find.byType(Scrollable),
    )
    .first;

ScrollPosition position(WidgetTester t) => t
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(MessageScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

List<String> arounds() =>
    chat.calls.where((x) => x.startsWith('around:')).toList();

List<Message> msgs(int n, {Set<int> own = const {}}) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'c1-$i',
      conversationId: 'c1',
      senderId: own.contains(i) ? 'u1' : 'u2',
      body: 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

final divider = find.byKey(const ValueKey('unread-divider'));
double dy(WidgetTester t, Finder f) => t.getTopLeft(f).dy;
Finder row(int i) => find.text('hay $i', findRichText: true);

void main() {
  testWidgets(
    'N unread: exactly one line, between the last read and the first unread',
    (t) async {
      await open(t, history: msgs(30), unread: Future.value(5));
      expect(divider, findsOneWidget, reason: 'divider present');
      expect(
        find.text('Unread messages'),
        findsOneWidget,
        reason: 'divider text present',
      );
      expect(
        dy(t, row(24)) < dy(t, divider) && dy(t, divider) < dy(t, row(25)),
        isTrue,
        reason: 'divider between rows 24 and 25',
      );
      final rect = t.getRect(divider);
      final logicalHeight =
          t.view.physicalSize.height / t.view.devicePixelRatio;
      expect(
        rect.top >= 0 && rect.top <= logicalHeight,
        isTrue,
        reason: 'divider within view',
      );
    },
  );

  testWidgets('no unread: no line, bottom (0)', (t) async {
    await open(t, history: msgs(30), unread: Future.value(0));
    expect(divider, findsNothing, reason: 'no divider');
    expect(row(29), findsOneWidget, reason: 'last row visible');
  });

  testWidgets('no unread: no line, bottom (null)', (t) async {
    await open(t, history: msgs(30), unread: null);
    expect(divider, findsNothing, reason: 'no divider');
    expect(row(29), findsOneWidget, reason: 'last row visible');
  });

  testWidgets('no unread: no line, bottom (Future<int?>.value(null))', (
    t,
  ) async {
    await open(t, history: msgs(30), unread: Future<int?>.value(null));
    expect(divider, findsNothing, reason: 'no divider');
    expect(row(29), findsOneWidget, reason: 'last row visible');
  });

  testWidgets('the line stays while in the chat', (t) async {
    await open(t, history: msgs(30), unread: Future.value(5));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(seconds: 10));
    }
    await t.drag(scrollable, const Offset(0, 100));
    await t.pump();
    expect(divider, findsOneWidget, reason: 'divider still present');
  });

  testWidgets('own messages never count', (t) async {
    await open(
      t,
      history: msgs(30, own: {25, 27, 29}),
      unread: Future.value(3),
    );
    expect(divider, findsOneWidget, reason: 'divider present');
    expect(row(23), findsOneWidget, reason: 'row 23 visible');
    expect(row(24), findsOneWidget, reason: 'row 24 visible');
    expect(
      dy(t, row(23)) < dy(t, divider) && dy(t, divider) < dy(t, row(24)),
      isTrue,
      reason: 'divider between rows 23 and 24',
    );
  });

  testWidgets(
    'first unread older than the loaded rows: older pages load until found',
    (t) async {
      await open(t, history: msgs(120), unread: Future.value(100));
      expect(divider, findsOneWidget, reason: 'divider present');
      expect(arounds().isNotEmpty, isTrue, reason: 'around calls made');
      final row19 = find.text('hay 19', findRichText: true);
      if (row19.evaluate().isNotEmpty) {
        expect(
          dy(t, row19) < dy(t, divider) && dy(t, divider) < dy(t, row(20)),
          isTrue,
          reason: 'divider between rows 19 and 20',
        );
      } else {
        expect(
          dy(t, divider) < dy(t, row(20)),
          isTrue,
          reason: 'divider above row 20',
        );
      }
    },
  );

  testWidgets('cap bound: found exactly at 200 loaded rows', (t) async {
    await open(t, history: msgs(400), unread: Future.value(200));
    await frames(t, 100);
    expect(divider, findsOneWidget, reason: 'divider present');
    expect(
      dy(t, divider) < dy(t, row(200)),
      isTrue,
      reason: 'divider above row 200',
    );
    expect(arounds().length <= 4, isTrue, reason: 'at most 4 around calls');
  });

  testWidgets(
    'just past the cap: the line sits on the row loaded at the cap (row 200) and stays',
    (t) async {
      await open(t, history: msgs(400), unread: Future.value(300));
      await frames(t, 100);
      expect(divider, findsOneWidget, reason: 'divider present');
      final loaded = c.read(messagesProvider).requireValue;
      expect(
        loaded.length >= 200 && loaded.length <= 250,
        isTrue,
        reason: 'loaded rows between 200 and 250',
      );
      expect(
        dy(t, divider) < dy(t, row(200)),
        isTrue,
        reason: 'divider above row 200, the oldest row loaded at the cap',
      );
      final row199 = row(199);
      if (row199.evaluate().isNotEmpty) {
        expect(
          dy(t, row199) < dy(t, divider),
          isTrue,
          reason:
              'row 199 (loaded later by normal paging) stays above the line',
        );
      }
      expect(arounds().length <= 4, isTrue, reason: 'at most 4 around calls');
      expect(t.takeException(), isNull, reason: 'no exception thrown');
    },
  );

  testWidgets('chat start reached before the count is covered', (t) async {
    await open(t, history: msgs(60), unread: Future.value(100));
    expect(
      c.read(messagesProvider.notifier).hasOlder,
      isFalse,
      reason: 'no older messages',
    );
    expect(divider, findsOneWidget, reason: 'divider present');
    expect(
      dy(t, divider) < dy(t, row(0)),
      isTrue,
      reason: 'divider above first row',
    );
  });

  testWidgets('a list that never answers: no line, no crash', (t) async {
    final completer = Completer<int?>();
    await open(t, history: msgs(30), unread: completer.future);
    expect(divider, findsNothing, reason: 'no divider');
    expect(t.takeException(), isNull, reason: 'no exception thrown');
    expect(row(29), findsOneWidget, reason: 'last row visible');
  });

  testWidgets('Turkish text', (t) async {
    await open(
      t,
      history: msgs(30),
      unread: Future.value(5),
      locale: const Locale('tr'),
    );
    expect(
      find.text('Okunmamış mesajlar'),
      findsOneWidget,
      reason: 'Turkish divider text present',
    );
  });
}
