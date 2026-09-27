// Message search on screen (v0.16), written from the contract, reached the
// way a member reaches it: the whole app as main.dart mounts it (SisApp under
// the production provider set), fakes only at the repository boundaries.
// ChatFake answers messages() with the newest 500 like the real read, so a
// hit "older than what is loaded" is genuinely not loaded here.
//
// Highlight is judged by how characters are drawn, not by how the widget is
// built: a character inside a match must be drawn differently from the same
// bubble with search closed (or, in a list snippet, from the characters
// around it), and nothing outside a match may change. Run under TZ=JST-9.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/initials.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/person_avatar.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone', tag: 'bobby');
const cem = Member(userId: 'u3', displayName: 'Cem Ay', tag: 'cem');

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

final t0 = DateTime.utc(2026, 3, 1, 8);

const longWords =
    'this is a deliberately long message that wraps over several lines in '
    'the bubble so that its time cannot sit on the last line';

/// Bodies of the "apple" hits in c1, by index (oldest first). 20 and 40
/// are older than the newest 500; 150 is loaded but far up the list.
const appleBodies = {
  20: 'Apple pie at noon', // bob
  40: 'I baked an apple crumble', // me
  150: 'mine and long: $longWords, with an apple in it', // me
  550: 'apple and APPLE again', // bob, short: inline time
  590: 'green apple', // me, short: inline time
  595: 'theirs and long: $longWords, and one apple', // bob
};

/// c1 hits for "apple", newest first.
const c1Hits = ['c1-595', 'c1-590', 'c1-550', 'c1-150', 'c1-40', 'c1-20'];

List<Message> c1History() => [
  for (var i = 0; i < 600; i++)
    Message(
      id: 'c1-$i',
      conversationId: 'c1',
      senderId: const {40, 150, 590}.contains(i) || (i.isEven && i % 3 == 0)
          ? 'u1'
          : const {20, 550, 595}.contains(i)
          ? 'ub'
          : (i.isOdd ? 'ub' : 'u1'),
      body: appleBodies[i] ?? 'hay $i',
      createdAt: t0.add(Duration(minutes: i)),
    ),
];

/// The newest message of all, in the group: a minute ago (today, locally).
Message juice() {
  final now = DateTime.now();
  var at = now.subtract(const Duration(minutes: 1));
  if (at.toLocal().day != now.toLocal().day) at = now;
  return Message(
    id: 'g1-juice',
    conversationId: 'g1',
    senderId: 'u3',
    body: 'apple juice anyone?',
    createdAt: at.toUtc(),
  );
}

class World {
  World() {
    final j = juice();
    chat
      ..conversationsResult = Ok([
        Conversation(
          id: 'g1',
          title: 'Club',
          lastMessage: j.body,
          lastMessageAt: j.createdAt,
          lastSenderId: 'u3',
        ),
        Conversation(
          id: 'c1',
          other: bob,
          lastMessage: 'hay 599',
          lastMessageAt: t0.add(const Duration(minutes: 599)),
          lastSenderId: 'ub',
        ),
      ])
      ..membersResult = const Ok([bob, cem])
      ..roster['c1'] = [me, bob]
      ..roster['g1'] = [me, bob, cem]
      ..history['c1'] = c1History()
      ..history['g1'] = [
        for (var i = 0; i < 5; i++)
          Message(
            id: 'g1-$i',
            conversationId: 'g1',
            senderId: i.isEven ? 'u3' : 'ub',
            body: 'club $i',
            createdAt: t0.add(Duration(days: 1, minutes: i)),
          ),
        j,
      ];
  }

  final chat = ChatFake(latency: const Duration(milliseconds: 2), self: 'u1');

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: me),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      profileRepositoryProvider.overrideWithValue(
        ProfileFake(
          profile: const OwnProfile(
            userId: 'u1',
            displayName: 'Maya Kaya',
            tag: 'maya',
            onboardingDone: true,
          ),
        ),
      ),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
    child: const SisApp(),
  );

  int arounds() => chat.calls.where((c) => c.startsWith('around:')).length;
}

Finder byKey(String key) => find.byKey(ValueKey(key));
Finder bubble(String id) => byKey('message-$id');
Finder row(String id) => byKey('list-search-result-$id');
Finder get anyRow => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('list-search-result-'),
);

/// Pumps [steps] x 50 ms: debounce, loads and scroll animations finish.
Future<void> settle(WidgetTester t, [int steps = 30]) async {
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> home(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await settle(t, 10);
  expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
}

Finder editable(String key) => find.descendant(
  of: byKey(key),
  matching: find.byType(EditableText),
  matchRoot: true,
);

Future<void> type(WidgetTester t, String key, String text) async {
  await t.enterText(editable(key), text);
  await settle(t);
}

Future<void> openChat(WidgetTester t, String id) async {
  await t.tap(byKey('conversation-$id'));
  await settle(t);
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> openSearch(WidgetTester t, String query) async {
  await t.tap(byKey('chat-search-button'));
  await settle(t, 10);
  expect(byKey('chat-search-field'), findsOneWidget);
  await type(t, 'chat-search-field', query);
}

/// All text under [f], joined.
String textUnder(Finder f) => find
    .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join(' ');

String count() => textUnder(byKey('chat-search-count'));

/// Every character drawn by the RichTexts under [f], with the style it is
/// drawn in (parent styles merged down), in order.
List<(String, TextStyle?)> drawn(Finder f) {
  final out = <(String, TextStyle?)>[];
  void walk(InlineSpan s, TextStyle? parent) {
    final style = parent == null ? s.style : parent.merge(s.style);
    if (s is TextSpan) {
      for (final ch in (s.text ?? '').split('')) {
        out.add((ch, style));
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c, style);
      }
    } else {
      out.add(('￼', style));
    }
  }

  for (final e
      in find
          .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
          .evaluate()) {
    walk((e.widget as RichText).text, null);
  }
  return out;
}

/// Offsets covered by case-insensitive, non-overlapping [q] in [text].
Set<int> covered(String text, String q) {
  final out = <int>{};
  final lower = text.toLowerCase(), lq = q.toLowerCase();
  var i = lower.indexOf(lq);
  while (i >= 0) {
    out.addAll([for (var k = i; k < i + lq.length; k++) k]);
    i = lower.indexOf(lq, i + lq.length);
  }
  return out;
}

/// [after] draws exactly the characters of [q] differently from [before]:
/// every match changed, nothing else did.
void highlightedExactly(
  List<(String, TextStyle?)> before,
  List<(String, TextStyle?)> after,
  String q,
  String what,
) {
  final text = before.map((c) => c.$1).join();
  expect(
    after.map((c) => c.$1).join(),
    text,
    reason: '$what: search changed the text itself',
  );
  final want = covered(text, q);
  expect(want, isNotEmpty, reason: '$what: fixture has no match');
  final changed = {
    for (var i = 0; i < text.length; i++)
      if (before[i].$2 != after[i].$2) i,
  };
  expect(
    changed,
    want,
    reason: '$what: highlighted ${[for (final i in changed) text[i]].join()}',
  );
}

/// Under [root] (a list row or a bubble): every match character of the
/// paragraph showing [q] is drawn in a style no other character there has.
void standsOut(Finder root, String body, String q) {
  expect(root, findsOneWidget, reason: '$root is not built');
  final paragraph = find
      .descendant(of: root, matching: find.byType(RichText))
      .evaluate()
      .map((e) => e.widget as RichText)
      .where(
        (r) => r.text.toPlainText().toLowerCase().contains(q.toLowerCase()),
      );
  expect(paragraph, hasLength(1), reason: 'one snippet showing "$q"');
  final chars = drawn(find.byWidget(paragraph.single))
      .where((c) => c.$1 != '￼')
      .toList();
  final text = chars.map((c) => c.$1).join();
  final hits = covered(text, q);
  final matchStyles = {for (final i in hits) chars[i].$2};
  final otherStyles = {
    for (var i = 0; i < text.length; i++)
      if (!hits.contains(i) && text[i].trim().isNotEmpty) chars[i].$2,
  };
  expect(
    hits.length,
    covered(body, q).length,
    reason: 'every occurrence in the snippet',
  );
  expect(
    matchStyles.intersection(otherStyles),
    isEmpty,
    reason: 'a match is drawn like the text around it: "$text"',
  );
}

/// The visible, non-transparent edges drawn on and around [id]'s bubble
/// (up to its list item), as "width/colour".
Set<String> edges(WidgetTester t, String id) {
  final out = <String>{};
  void side(BorderSide s) {
    if (s.style != BorderStyle.none && s.width > 0 && s.color.a > 0) {
      out.add('${s.width}/${s.color}');
    }
  }

  void of(Widget w) {
    Decoration? d;
    if (w is DecoratedBox) d = w.decoration;
    if (w is Material && w.shape is OutlinedBorder) {
      side((w.shape! as OutlinedBorder).side);
    }
    if (d is BoxDecoration && d.border is Border) {
      final b = d.border! as Border;
      [b.top, b.right, b.bottom, b.left].forEach(side);
    }
    if (d is ShapeDecoration && d.shape is OutlinedBorder) {
      side((d.shape as OutlinedBorder).side);
    }
  }

  final b = bubble(id);
  expect(b, findsOneWidget, reason: '$id is not built');
  for (final e
      in find
          .descendant(
            of: b,
            matching: find.byWidgetPredicate((_) => true),
            matchRoot: true,
          )
          .evaluate()) {
    of(e.widget);
  }
  b.evaluate().single.visitAncestorElements((e) {
    if (e.widget is Scrollable || e.widget is SliverMultiBoxAdaptorWidget) {
      return false;
    }
    of(e.widget);
    return true;
  });
  return out;
}

/// [id]'s bubble lies wholly inside the message list's viewport.
void inView(WidgetTester t, String id) {
  final b = bubble(id);
  expect(b, findsOneWidget, reason: '$id is not on screen at all');
  final list = find.ancestor(of: b, matching: find.byType(Scrollable)).first;
  final v = t.getRect(list), r = t.getRect(b);
  expect(
    r.top >= v.top - 1 && r.bottom <= v.bottom + 1,
    isTrue,
    reason: '$id at $r is not scrolled into the list at $v',
  );
}

/// The background colour an avatar paints behind [initials] under [root].
Color tintOf(WidgetTester t, Finder root, String initials) {
  final text = find.descendant(of: root, matching: find.text(initials));
  expect(text, findsWidgets, reason: 'no avatar "$initials" under $root');
  Color? found;
  t.element(text.first).visitAncestorElements((e) {
    final w = e.widget;
    Color? c;
    if (w is CircleAvatar) {
      c = w.backgroundColor;
    } else if (w is DecoratedBox && w.decoration is BoxDecoration) {
      c = (w.decoration as BoxDecoration).color;
    } else if (w is Container) {
      c = w.color;
    }
    if (c == null) return true;
    found = c;
    return false;
  });
  expect(found, isNotNull, reason: 'no painted avatar behind "$initials"');
  return found!;
}

/// A failure as the real repository makes one: a new instance each time.
Err<List<Message>> offline() => Err(NetworkFailure(offlineText));
String get offlineText => 'No connection.';

/// The messages the open chat holds, oldest first -- what the screen lists.
List<String> shownIds(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(MessageScreen)))
        .read(messagesProvider)
        .requireValue
        .map((m) => m.id)
        .toList();

String two(int v) => v.toString().padLeft(2, '0');

bool enabled(WidgetTester t, String key) {
  final data = t.getSemantics(byKey(key)).getSemanticsData();
  return data.flagsCollection.isEnabled == Tristate.isTrue;
}

void main() {
  group('chat list search', () {
    testWidgets('the field sits above the chats; one or two characters ask '
        'nothing and keep the list; three show results newest first in '
        'place of the list, debounced', (t) async {
      final w = World();
      await home(t, w);
      final field = byKey('list-search-field');
      expect(field, findsOneWidget);
      expect(
        t.getRect(field).bottom,
        lessThanOrEqualTo(t.getRect(byKey('conversation-g1')).top),
        reason: 'above the chats',
      );

      for (final short in ['a', 'ap', ' ap ']) {
        await type(t, 'list-search-field', short);
        expect(w.chat.searches, isEmpty, reason: '"$short": under three');
        expect(byKey('conversation-c1'), findsOneWidget, reason: short);
        expect(find.text('No messages found'), findsNothing, reason: short);
      }

      await t.enterText(editable('list-search-field'), 'app');
      await t.pump(const Duration(milliseconds: 100));
      await t.enterText(editable('list-search-field'), 'apple');
      await t.pump(const Duration(milliseconds: 100));
      expect(w.chat.searches, isEmpty, reason: 'debounced while typing');
      await settle(t);
      expect(w.chat.searches.map((s) => s.query), ['apple']);
      expect(w.chat.searches.single.conversationId, isNull);

      expect(byKey('conversation-c1'), findsNothing, reason: 'list replaced');
      expect(byKey('conversation-g1'), findsNothing);
      final shown = anyRow
          .evaluate()
          .map((e) => (e.widget.key! as ValueKey<String>).value)
          .toList();
      expect(shown.first, 'list-search-result-g1-juice');
      final tops = [
        for (final id in ['g1-juice', ...c1Hits.take(3)])
          t.getRect(row(id)).top,
      ];
      expect(tops, orderedEquals([...tops]..sort()), reason: 'newest first');
    });

    testWidgets('a row: the chat\'s avatar (same seed and tint as its tile), '
        'the chat\'s name, the time -- for my message and theirs', (t) async {
      final w = World();
      await home(t, w);
      final bobInList = tintOf(
        t,
        byKey('conversation-c1'),
        initialsOf(bob.displayName),
      );
      final clubInList = tintOf(
        t,
        byKey('conversation-g1'),
        initialsOf('Club'),
      );
      await type(t, 'list-search-field', 'apple');

      // Received, in a group: the group's avatar and name, not the sender's.
      final g = row('g1-juice');
      expect(g, findsOneWidget);
      final gAvatar = find.descendant(
        of: g,
        matching: find.byType(PersonAvatar),
      );
      expect(gAvatar, findsOneWidget);
      expect(t.widget<PersonAvatar>(gAvatar).seed, 'g1');
      expect(tintOf(t, g, initialsOf('Club')), clubInList);
      expect(textUnder(g), contains('Club'));
      expect(textUnder(g), isNot(contains('Cem')));
      final at = juice().createdAt.toLocal();
      expect(
        textUnder(g),
        contains('${two(at.hour)}:${two(at.minute)}'),
        reason: 'the local time of the message (TZ=JST-9)',
      );

      // Mine, in a 1:1: still the chat's avatar and name -- Bob's.
      final mine = row('c1-590');
      expect(mine, findsOneWidget);
      final mAvatar = find.descendant(
        of: mine,
        matching: find.byType(PersonAvatar),
      );
      expect(t.widget<PersonAvatar>(mAvatar).seed, 'ub');
      expect(tintOf(t, mine, initialsOf(bob.displayName)), bobInList);
      expect(textUnder(mine), contains('Bob Stone'));
    });

    testWidgets('the snippet is one line, every occurrence highlighted '
        'whatever its case', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'aPPle');
      standsOut(row('c1-550'), appleBodies[550]!, 'apple');
      standsOut(row('c1-590'), appleBodies[590]!, 'apple');
      standsOut(row('g1-juice'), 'apple juice anyone?', 'apple');

      final snippet = find
          .descendant(of: row('c1-550'), matching: find.byType(RichText))
          .evaluate()
          .firstWhere(
            (e) => (e.widget as RichText).text.toPlainText().contains('again'),
          );
      expect(
        (snippet.renderObject! as RenderParagraph).maxLines,
        1,
        reason: 'one line',
      );
    });

    testWidgets('emptying the field brings the list back', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      expect(anyRow, findsWidgets);
      await type(t, 'list-search-field', '');
      expect(anyRow, findsNothing);
      expect(byKey('conversation-c1'), findsOneWidget);
      expect(byKey('conversation-g1'), findsOneWidget);
    });

    testWidgets('no hits: "No messages found"', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'zebra');
      expect(w.chat.searches.last.query, 'zebra');
      expect(find.text('No messages found'), findsOneWidget);
      expect(anyRow, findsNothing);
    });

    testWidgets('a failed search shows the SIS notice and keeps the previous '
        'results; the next failure shows it again', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      expect(row('c1-550'), findsOneWidget);
      expect(notice, findsNothing);

      w.chat.searchResult = offline();
      await type(t, 'list-search-field', 'apples');
      expect(noticeSaying('No connection.'), findsOneWidget);
      expect(row('c1-550'), findsOneWidget, reason: 'results stay');
      expect(find.text('No messages found'), findsNothing);
      await drainNotice(t);

      w.chat.searchResult = offline();
      await type(t, 'list-search-field', 'applesauce');
      expect(noticeSaying('No connection.'), findsOneWidget, reason: 'again');
      expect(row('c1-550'), findsOneWidget);
      await drainNotice(t);
    });
  });

  group('from a list result into the chat', () {
    testWidgets('a hit older than the newest 500: the chat opens on it, '
        'search open on the query, it current and scrolled into view', (
      t,
    ) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      await t.scrollUntilVisible(
        row('c1-20'),
        200,
        scrollable: find
            .ancestor(of: row('g1-juice'), matching: find.byType(Scrollable))
            .first,
      );
      await t.tap(row('c1-20'));
      await settle(t, 40);

      expect(find.byType(MessageScreen), findsOneWidget);
      expect(
        t.widget<EditableText>(editable('chat-search-field')).controller.text,
        'apple',
      );
      expect(count(), '6/6', reason: 'the oldest of six hits is current');
      inView(t, 'c1-20');
      expect(w.chat.calls, contains('around:c1:c1-20'));
    });

    testWidgets('windows answered out of order: the tapped hit still wins', (
      t,
    ) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      await t.scrollUntilVisible(
        row('c1-20'),
        200,
        scrollable: find
            .ancestor(of: row('g1-juice'), matching: find.byType(Scrollable))
            .first,
      );
      final holds = [for (var i = 0; i < 3; i++) w.chat.holdAround()];
      await t.tap(row('c1-20'));
      await settle(t, 10);
      // The last asked answers first, the first asked last.
      for (final h in holds.reversed) {
        h.complete();
        await settle(t, 10);
      }
      await settle(t, 30);
      expect(count(), '6/6');
      inView(t, 'c1-20');
    });

    testWidgets('a loaded hit: opens on it, current, in view', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      await t.tap(row('c1-550'));
      await settle(t, 40);
      expect(count(), '3/6');
      inView(t, 'c1-550');
    });

    testWidgets('a group hit opens the group on it', (t) async {
      final w = World();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      await t.tap(row('g1-juice'));
      await settle(t, 40);
      expect(
        find.descendant(
          of: find.byType(MessageScreen),
          matching: find.text('club 0'),
        ),
        findsWidgets,
      );
      expect(count(), '1/1');
      inView(t, 'g1-juice');
    });

    testWidgets('the window around an old hit fails to load: SIS notice, '
        'the chat still shows its newest messages', (t) async {
      final w = World();
      w.chat.messagesAroundResult = offline();
      await home(t, w);
      await type(t, 'list-search-field', 'apple');
      await t.scrollUntilVisible(
        row('c1-20'),
        200,
        scrollable: find
            .ancestor(of: row('g1-juice'), matching: find.byType(Scrollable))
            .first,
      );
      await t.tap(row('c1-20'));
      await settle(t, 40);
      expect(find.byType(MessageScreen), findsOneWidget);
      expect(noticeSaying('No connection.'), findsOneWidget);
      expect(bubble('c1-599'), findsOneWidget, reason: 'messages stay');
      await drainNotice(t);
    });
  });

  group('in-chat search', () {
    testWidgets('the header button opens the search bar, not the profile', (
      t,
    ) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      expect(byKey('conversation-title'), findsOneWidget);
      await t.tap(byKey('chat-search-button'));
      await settle(t, 10);
      expect(find.byType(PersonScreen), findsNothing);
      for (final k in [
        'chat-search-field',
        'chat-search-older',
        'chat-search-newer',
        'chat-search-close',
      ]) {
        expect(byKey(k), findsOneWidget, reason: k);
      }
      await type(t, 'chat-search-field', 'apple');
      expect(count(), '1/6');
    });

    testWidgets('searches this chat only; n/m from the newest; the newest '
        'hit current and in view', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'apple');
      expect(w.chat.searches.last.query, 'apple');
      expect(w.chat.searches.last.conversationId, 'c1');
      expect(count(), '1/6');
      inView(t, 'c1-595');
    });

    testWidgets('↑ older and ↓ newer walk the hits one by one, across what '
        'is loaded and what is not, each current hit emphasised and in view; '
        'both stop at the ends', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'apple');
      final notCurrent = <String, Set<String>>{};

      Future<void> step(String key, String want, String id) async {
        await t.tap(byKey(key));
        await settle(t, 40);
        expect(count(), want, reason: 'after $key');
        inView(t, id);
      }

      // Newest to oldest: 595 590 550 150 (loaded) 40 20 (not loaded).
      for (final (i, id) in c1Hits.indexed.skip(1)) {
        final previous = c1Hits[i - 1];
        final emphasised = edges(t, previous);
        await step('chat-search-older', '${i + 1}/6', id);
        if (bubble(previous).evaluate().isNotEmpty) {
          notCurrent[previous] = edges(t, previous);
          expect(
            emphasised.difference(notCurrent[previous]!),
            isNotEmpty,
            reason: '$previous had no emphasised edge while current',
          );
        }
      }
      expect(w.arounds(), greaterThan(0), reason: '40 and 20 needed a load');

      await t.tap(byKey('chat-search-older'));
      await settle(t, 20);
      expect(count(), '6/6', reason: 'stops at the oldest');
      inView(t, 'c1-20');

      // And back up, across the boundary again.
      for (final (i, id) in c1Hits.indexed.toList().reversed.skip(1)) {
        await step('chat-search-newer', '${i + 1}/6', id);
      }
      await t.tap(byKey('chat-search-newer'));
      await settle(t, 20);
      expect(count(), '1/6', reason: 'stops at the newest');
      inView(t, 'c1-595');
    });

    testWidgets('matches are highlighted in every bubble -- mine and theirs, '
        'inline-time and long, loaded or not -- and only the matches', (
      t,
    ) async {
      // Tall enough that the newest dozen bubbles are all built.
      t.view.physicalSize = const Size(800, 2400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      const plainFirst = ['c1-595', 'c1-590']; // theirs long; mine inline
      final before = {for (final id in plainFirst) id: drawn(bubble(id))};
      await openSearch(t, 'APPLE');
      for (final id in plainFirst) {
        highlightedExactly(before[id]!, drawn(bubble(id)), 'apple', id);
      }

      // Further up, each checked as it becomes the current hit: theirs
      // inline (550), mine long (150), mine and theirs never loaded (40, 20).
      await t.tap(byKey('chat-search-older'));
      await settle(t, 40);
      expect(count(), '2/6');
      for (final (i, n) in [550, 150, 40, 20].indexed) {
        await t.tap(byKey('chat-search-older'));
        await settle(t, 40);
        expect(count(), '${i + 3}/6');
        standsOut(bubble('c1-$n'), appleBodies[n]!, 'apple');
      }
    });

    for (final (label, marks) in [
      ('unread', const <ReadMark>[ReadMark(userId: 'ub', shares: true)]),
      ('read', [ReadMark(userId: 'ub', shares: true, readAt: DateTime.now())]),
    ]) {
      testWidgets('the current hit has an emphasised edge -- theirs, and mine '
          'while $label', (t) async {
        t.view.physicalSize = const Size(800, 2400);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final w = World();
        w.chat.readMarksData['c1'] = marks;
        await home(t, w);
        await openChat(t, 'c1');
        await openSearch(t, 'apple');
        expect(count(), '1/6');
        final theirsCurrent = edges(t, 'c1-595');
        final mineNot = edges(t, 'c1-590');

        await t.tap(byKey('chat-search-older'));
        await settle(t, 40);
        expect(count(), '2/6');
        final theirsNot = edges(t, 'c1-595');
        final mineCurrent = edges(t, 'c1-590');
        expect(
          theirsCurrent.difference(theirsNot),
          isNotEmpty,
          reason: 'theirs: current $theirsCurrent, not current $theirsNot',
        );
        expect(
          mineCurrent.difference(mineNot),
          isNotEmpty,
          reason: 'mine: current $mineCurrent, not current $mineNot',
        );
      });
    }

    testWidgets('one or two characters: no request, no count, no highlight; '
        'three search', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'ap');
      expect(w.chat.searches, isEmpty);
      expect(count(), isEmpty, reason: 'no counter under three characters');
      expect(find.text('No results'), findsNothing);
      expect(
        drawn(bubble('c1-595')).where((c) => c.$2?.backgroundColor != null),
        isEmpty,
        reason: 'nothing highlighted under three characters',
      );

      await type(t, 'chat-search-field', 'app');
      expect(w.chat.searches.map((s) => s.query), ['app']);
      expect(count(), '1/6');

      await type(t, 'chat-search-field', ' ap ');
      expect(w.chat.searches, hasLength(1), reason: 'trimmed: two again');
      expect(count(), isEmpty);
      expect(
        drawn(bubble('c1-595')).where((c) => c.$2?.backgroundColor != null),
        isEmpty,
        reason: 'the highlight goes with the hits',
      );
    });

    testWidgets('no hits: "No results", both arrows disabled', (t) async {
      final tester = t.ensureSemantics();
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'zebra');
      expect(count(), 'No results');
      expect(enabled(t, 'chat-search-older'), isFalse);
      expect(enabled(t, 'chat-search-newer'), isFalse);

      await openSearchAgain(t, 'apple');
      expect(enabled(t, 'chat-search-older'), isTrue);
      tester.dispose();
    });

    testWidgets('closing returns to the normal header and the live newest '
        'messages, highlights gone', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      final plain = drawn(bubble('c1-590'));
      await openSearch(t, 'apple');
      for (var i = 0; i < 5; i++) {
        await t.tap(byKey('chat-search-older'));
        await settle(t, 40);
      }
      expect(count(), '6/6');
      expect(bubble('c1-599'), findsNothing, reason: 'jumped away from live');

      await t.tap(byKey('chat-search-close'));
      await settle(t, 40);
      expect(byKey('chat-search-field'), findsNothing);
      expect(byKey('conversation-title'), findsOneWidget);
      expect(bubble('c1-20'), findsNothing, reason: 'back to the newest 500');
      inView(t, 'c1-599');
      expect(
        drawn(bubble('c1-590')).map((c) => c.$2),
        plain.map((c) => c.$2),
        reason: 'no highlight left behind',
      );
    });

    testWidgets('leaving the chat and coming back starts with search closed '
        'and live', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'apple');
      for (var i = 0; i < 5; i++) {
        await t.tap(byKey('chat-search-older'));
        await settle(t, 40);
      }
      await t.pageBack();
      await settle(t);
      await openChat(t, 'c1');
      expect(byKey('chat-search-field'), findsNothing);
      expect(byKey('conversation-title'), findsOneWidget);
      inView(t, 'c1-599');
      expect(bubble('c1-20'), findsNothing);
    });

    testWidgets('a hit whose window fails to load: SIS notice, the previous '
        'messages stay', (t) async {
      final w = World();
      await home(t, w);
      await openChat(t, 'c1');
      await openSearch(t, 'apple');
      for (var i = 0; i < 3; i++) {
        await t.tap(byKey('chat-search-older'));
        await settle(t, 40);
      }
      expect(count(), '4/6');
      final before = shownIds(t);
      expect(before, contains('c1-150'));
      expect(before, isNot(contains('c1-40')), reason: 'fixture: not loaded');
      w.chat.messagesAroundResult = offline();
      await t.tap(byKey('chat-search-older'));
      await settle(t, 40);
      expect(noticeSaying('No connection.'), findsOneWidget);
      expect(shownIds(t), before, reason: 'the previous messages stay');
      expect(t.takeException(), isNull);
      await drainNotice(t);
    });
  });
}

Future<void> openSearchAgain(WidgetTester t, String query) =>
    type(t, 'chat-search-field', query);
