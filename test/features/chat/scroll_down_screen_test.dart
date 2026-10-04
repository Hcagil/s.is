// MessageScreen's way back to the newest message (0.30.16), from its
// contract:
//
// - The jump-to-latest button (ValueKey('jump-to-latest')) shows when the
//   newest message is more than a viewport away (extentBefore >
//   viewportDimension) or while the list is a jumped window; hidden means
//   opacity 0 and pointer events ignored.
// - Its tap, not jumped: the list starts moving within one pump() and ends
//   at extentBefore == 0. Jumped: live again and the newest message on
//   screen after one pump(), with no network read on the way.
// - Scrolling from far to near the newest triggers exactly one
//   verifyNewest; near the bottom while jumped (extentBefore < 600) it pages
//   newer (loadNewer).
// - Regressions (owner, 0.30.14: scrolling back down got stuck): plain
//   scrolling up several pages then down reaches the newest; an incoming
//   message while scrolled up is at the bottom; a jump to an old search hit
//   then scrolling down reaches the newest without closing search.
//
// The older-loading key and olderLoadingProvider are covered unchanged by
// older_paging_screen_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final _t0 = DateTime.utc(2026, 9, 1, 8);

/// [n] messages, one a minute; every tenth body says "needle".
List<Message> _history(int n) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'c1-$i',
      conversationId: 'c1',
      senderId: i.isEven ? 'u1' : 'u2',
      body: i % 10 == 0 ? 'needle $i' : 'hay $i',
      createdAt: _t0.add(Duration(minutes: i)),
    ),
];

final _button = find.byKey(const ValueKey('jump-to-latest'));
Finder _text(String s) => find.text(s, findRichText: true);

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  MessagesController messages() => c.read(messagesProvider.notifier);
  int reads() => chat.calls.where((x) => x == 'messages:c1').length;
  List<String> arounds() =>
      chat.calls.where((x) => x.startsWith('around:')).toList();

  Future<void> frames(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester t, {
    int n = 120,
    String? query,
    String? hit,
  }) async {
    chat = ChatFake()..history['c1'] = _history(n);
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
        child: MaterialApp(
          home: MessageScreen(
            title: 'Bob',
            initialSearchQuery: query,
            initialSearchHitId: hit,
          ),
        ),
      ),
    );
    await frames(t);
  }

  Finder list() => find
      .descendant(
        of: find.byType(MessageScreen),
        matching: find.byType(Scrollable),
      )
      .first;

  ScrollPosition position(WidgetTester t) =>
      t.state<ScrollableState>(list()).position;

  /// Opacity of the button as painted: the product of every opacity on its
  /// way to the root.
  double opacity(WidgetTester t) {
    var o = 1.0;
    RenderObject? r = t.renderObject(_button);
    while (r != null) {
      if (r is RenderOpacity) o *= r.opacity;
      if (r is RenderAnimatedOpacity) o *= r.opacity.value;
      if (r is RenderSliverOpacity) o *= r.opacity;
      r = r.parent;
    }
    return o;
  }

  bool shown(WidgetTester t) =>
      opacity(t) > 0 && _button.hitTestable().evaluate().isNotEmpty;
  bool hidden(WidgetTester t) =>
      _button.evaluate().isEmpty ||
      (opacity(t) == 0 && _button.hitTestable().evaluate().isEmpty);

  /// Drags toward older messages until the newest is [far] away.
  Future<void> scrollUpBy(WidgetTester t, double far) async {
    for (var i = 0; i < 40 && position(t).extentBefore < far; i++) {
      await t.drag(list(), const Offset(0, 300));
      await t.pump();
    }
  }

  /// Drags toward newer messages until the very bottom of a live list.
  Future<void> scrollDownToEnd(WidgetTester t) async {
    for (
      var i = 0;
      i < 80 && (position(t).extentBefore > 0 || messages().isJumped);
      i++
    ) {
      await t.drag(list(), const Offset(0, -300));
      await frames(t, 2);
    }
    await frames(t, 3);
  }

  testWidgets('at the bottom the button is hidden: opacity 0, no taps', (
    t,
  ) async {
    await open(t);
    expect(position(t).extentBefore, 0, reason: 'fixture: at the bottom');
    expect(hidden(t), isTrue);
  });

  testWidgets('scrolled up a little (within a viewport) it stays hidden; '
      'more than a viewport away it shows', (t) async {
    await open(t);
    final viewport = position(t).viewportDimension;
    await t.drag(list(), Offset(0, viewport / 3));
    await frames(t, 5);
    expect(position(t).extentBefore, lessThan(viewport), reason: 'fixture');
    expect(hidden(t), isTrue);
    await scrollUpBy(t, viewport * 1.5);
    await frames(t, 5);
    expect(position(t).extentBefore, greaterThan(viewport));
    expect(shown(t), isTrue);
  });

  testWidgets('tap, not jumped: the list moves within one pump and ends at '
      'the newest message', (t) async {
    await open(t);
    await scrollUpBy(t, position(t).viewportDimension * 3);
    await frames(t, 5);
    expect(messages().isJumped, isFalse, reason: 'fixture');
    final before = position(t).pixels;
    await t.tap(_button);
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(position(t).pixels, isNot(before), reason: 'moving at once');
    await frames(t);
    expect(position(t).extentBefore, 0);
    expect(_text('hay 119'), findsOneWidget);
    expect(hidden(t), isTrue, reason: 'at the bottom again');
  });

  testWidgets('jumped: the button shows; its tap is live with the newest on '
      'screen after one pump, with no read in the way', (t) async {
    // Jumped the way the member gets there: an old search hit, scrolled to.
    await open(t, n: 300, query: 'needle', hit: 'c1-30');
    expect(messages().isJumped, isTrue, reason: 'fixture');
    expect(shown(t), isTrue, reason: 'shown while jumped');
    // Any read would now hang: the tap must not wait for one.
    chat.holdMessages();
    chat.holdAround();
    await t.tap(_button);
    await t.pump();
    expect(messages().isJumped, isFalse);
    expect(_text('hay 299'), findsOneWidget);
    chat.releaseMessages();
    await frames(t);
  });

  testWidgets('jumped and at the bottom of the window (newest less than a '
      'viewport away): still shown', (t) async {
    await open(t, n: 300, query: 'needle', hit: 'c1-30');
    // The next newer page stays in flight, so the window stays jumped
    // while its bottom is on screen.
    final held = chat.holdAround();
    for (var i = 0; i < 30 && position(t).extentBefore > 0; i++) {
      await t.drag(list(), const Offset(0, -300));
      await t.pump();
    }
    await frames(t, 3);
    expect(messages().isJumped, isTrue, reason: 'fixture: page held');
    expect(
      position(t).extentBefore,
      lessThan(position(t).viewportDimension),
      reason: 'fixture: not far',
    );
    expect(shown(t), isTrue);
    held.complete();
    await frames(t);
  });

  testWidgets('scrolling from far to near re-checks the newest exactly once', (
    t,
  ) async {
    await open(t, n: 300);
    await scrollUpBy(t, position(t).viewportDimension * 3);
    await frames(t, 5);
    final mark = reads();
    await scrollDownToEnd(t);
    expect(position(t).extentBefore, 0, reason: 'fixture: back at the end');
    expect(reads() - mark, 1);
  });

  testWidgets('near the bottom of a jumped window it pages newer until live', (
    t,
  ) async {
    await open(t, n: 300, query: 'needle', hit: 'c1-30');
    expect(messages().isJumped, isTrue, reason: 'fixture');
    await scrollDownToEnd(t);
    expect(
      arounds(),
      containsAllInOrder(['around:c1:c1-30', 'around:c1:c1-80']),
      reason: 'loadNewer from the newest shown row of the window',
    );
    expect(messages().isJumped, isFalse);
    expect(_text('hay 299'), findsOneWidget);
  });

  group('regressions (scrolling down got stuck, 0.30.14)', () {
    testWidgets('plain scrolling up several older pages, then down, reaches '
        'the newest message', (t) async {
      await open(t, n: 300);
      for (var page = 0; page < 4; page++) {
        await t.drag(list(), const Offset(0, 4000));
        await frames(t, 3);
      }
      expect(
        c.read(messagesProvider).requireValue.length,
        greaterThan(150),
        reason: 'fixture: older pages loaded',
      );
      await scrollDownToEnd(t);
      expect(position(t).extentBefore, 0);
      expect(_text('hay 299'), findsOneWidget);
    });

    testWidgets('an incoming message while scrolled up is at the bottom', (
      t,
    ) async {
      await open(t, n: 300);
      chat.confirmSubscription();
      await scrollUpBy(t, position(t).viewportDimension * 3);
      await frames(t, 3);
      chat.deliver(
        Message(
          id: 'c1-new',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'fresh one',
          createdAt: _t0.add(const Duration(days: 2)),
        ),
      );
      await frames(t, 3);
      expect(
        c.read(messagesProvider).requireValue.last.id,
        'c1-new',
        reason: 'at the bottom already, before any scroll re-check',
      );
      await scrollDownToEnd(t);
      expect(_text('fresh one'), findsOneWidget);
      expect(c.read(messagesProvider).requireValue.last.id, 'c1-new');
    });

    testWidgets('a jump to an old search hit, then scrolling down, reaches '
        'the newest message without closing search', (t) async {
      await open(t, n: 300, query: 'needle', hit: 'c1-30');
      await frames(t);
      expect(messages().isJumped, isTrue, reason: 'fixture: jumped to hit');
      expect(_text('needle 30'), findsWidgets);
      await scrollDownToEnd(t);
      expect(messages().isJumped, isFalse);
      expect(_text('hay 299'), findsOneWidget);
      expect(c.read(chatSearchProvider).query, 'needle', reason: 'still open');
    });
  });
}
