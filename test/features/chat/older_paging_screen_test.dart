// MessageScreen's older paging (0.30.14), from its contract: older pages load
// when the reversed list nears its top (extentAfter < 600); a top loader
// keyed `older-loading` shows only while a page is in flight; prepending
// must not move what is on screen. The whole screen as the controller
// drives it, against ChatFake's real-shaped messagesAround window.
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

import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final _t0 = DateTime.utc(2026, 9, 1, 8);

List<Message> _history(int n) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'c1-$i',
      conversationId: 'c1',
      senderId: i.isEven ? 'u1' : 'u2',
      body: 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

final _loader = find.byKey(const ValueKey('older-loading'));

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<String> arounds() =>
      chat.calls.where((x) => x.startsWith('around:')).toList();

  Future<void> frames(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester t) async {
    chat = ChatFake()..history['c1'] = _history(120);
    c = await settled(
      ProviderContainer.test(
        overrides: [
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
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MessageScreen(title: 'Bob'),
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

  /// Drags toward older messages until the list is near its top.
  Future<void> scrollUp(WidgetTester t) async {
    for (var i = 0; i < 20 && position(t).extentAfter >= 600; i++) {
      await t.drag(scrollable, const Offset(0, 400));
      await t.pump();
    }
  }

  testWidgets('at the bottom no older page is read and no loader shows', (
    t,
  ) async {
    await open(t);
    expect(find.text('hay 119', findRichText: true), findsOneWidget);
    expect(_loader, findsNothing);
    if (position(t).extentAfter >= 600) {
      expect(arounds(), isEmpty, reason: 'far from the top: nothing to page');
    }
  });

  testWidgets('nearing the top reads the older page; the loader shows only '
      'while it is in flight; prepending does not move what is on '
      'screen', (t) async {
    await open(t);
    final held = chat.holdAround();
    await scrollUp(t);
    await t.pump();
    expect(arounds(), ['around:c1:c1-70'], reason: 'the oldest shown anchor');
    // The loader sits at the very top of the list, above the oldest row.
    await t.drag(scrollable, const Offset(0, 2000));
    await t.pump();
    expect(position(t).extentAfter, 0, reason: 'fixture: at the top');
    expect(_loader, findsOneWidget, reason: 'a page is in flight');

    final anchor = find.text('hay 72', findRichText: true);
    expect(anchor, findsOneWidget, reason: 'fixture: near the top on screen');
    final before = t.getTopLeft(anchor);

    held.complete();
    await t.pump();
    await t.pump();
    expect(_loader, findsNothing, reason: 'the page has landed');
    expect(c.read(messagesProvider).requireValue, hasLength(100));
    expect(
      t.getTopLeft(anchor),
      before,
      reason: 'rows added above must not move the row being read',
    );
  });

  testWidgets('once the oldest is loaded, scrolling up reads nothing more '
      'and no loader shows', (t) async {
    await open(t);
    for (var page = 0; page < 4; page++) {
      await scrollUp(t);
      await frames(t, 3);
    }
    expect(c.read(messagesProvider).requireValue, hasLength(120));
    expect(c.read(messagesProvider.notifier).hasOlder, isFalse);
    final asked = arounds().length;
    await t.drag(scrollable, const Offset(0, 2000));
    await frames(t, 3);
    expect(position(t).extentAfter, 0, reason: 'fixture: at the top');
    expect(arounds(), hasLength(asked), reason: 'nothing older: no read');
    expect(_loader, findsNothing);
    expect(find.text('hay 0', findRichText: true), findsOneWidget);
  });
}
