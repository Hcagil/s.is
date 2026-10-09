// 0.30.7 presentation, from the contract:
//
// Fix 4 -- the iPhone composer gap. On iOS with a 34 px bottom inset the
// composer pads itself 38 px at the bottom and no SafeArea adds the inset
// again; with the keyboard up (viewInsets.bottom > 0) it pads 4. Android:
// 12 px plus the SafeArea's inset, unchanged. The read-only composers
// (composer-system, composer-left) add the inset on iOS only.
//   Measured as geometry, never as widget structure: the gap between the
//   send button's bottom and the screen's (or keyboard's) top edge. The
//   Android gap is 34 + 12 + s and the iOS one 38 + s for the same s, so iOS
//   sits exactly 8 px lower; with the keyboard up iOS sits 4 + s above it.
// Fix 5 -- the message field capitalises sentences.
// Fix 6 -- in a group the list preview names a known other sender ("Name:
// message"); own, 1:1, SIS and unknown senders are unchanged. In the chat a
// sender's name is slot-coloured, w600, 13 px; a departed sender's stays
// grey. A live message from a sender the list does not know makes it read
// the list again.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/conversation_list.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const hugh = Member(userId: 'u2', displayName: 'Hugh');
const iona = Member(userId: 'u3', displayName: 'Iona');
const gone = Member(userId: 'u4', displayName: 'Gus');

final _t0 = DateTime.utc(2026, 10, 1, 9);

Message msg(String id, String from, {String conv = 'g1', int minute = 0}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: 'text $id',
      createdAt: _t0.add(Duration(minutes: minute)),
    );

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> _container(ChatFake chat) => settled(
  ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      sessionControllerProvider.overrideWith(_In.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    ],
  ),
);

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// The rectangle of the nearest painted surface behind [f]: the first
/// ancestor that fills itself with a colour.
Rect surfaceUnder(WidgetTester t, Finder f) {
  Element? found;
  t.element(f).visitAncestorElements((e) {
    final w = e.widget;
    final painted = switch (w) {
      Container(:final color?) => color.a > 0,
      Container(decoration: BoxDecoration(:final color?)) => color.a > 0,
      DecoratedBox(decoration: BoxDecoration(:final color?)) => color.a > 0,
      ColoredBox(:final color) => color.a > 0,
      Material(:final type, :final color) =>
        type != MaterialType.transparency && (color?.a ?? 1) > 0,
      _ => false,
    };
    if (painted) found = e;
    return !painted;
  });
  expect(found, isNotNull, reason: 'nothing painted behind $f');
  final box = found!.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Lets the timers of a tree mounted and replaced within one test run out.
Future<void> unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
}

Future<ProviderContainer> mountChat(
  WidgetTester t,
  ChatFake chat, {
  required String open,
  TargetPlatform platform = TargetPlatform.android,
  double inset = 34,
  double keyboard = 0,
  bool group = false,
  ThemeData? theme,
}) async {
  final c = await _container(chat);
  c.read(openConversationProvider.notifier).open(open);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: (theme ?? ThemeData()).copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: keyboard > 0 ? 0 : inset),
            viewPadding: EdgeInsets.only(bottom: inset),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: MessageScreen(group: group, title: 'Chat'),
      ),
    ),
  );
  await steps(t);
  return c;
}

void main() {
  late ChatFake chat;

  setUp(() {
    chat = ChatFake(self: 'u1', latency: const Duration(milliseconds: 2));
    chat.history['c1'] = [msg('m1', 'u2', conv: 'c1')];
    chat.history['sis'] = [msg('w1', 'sys', conv: 'sis')];
    chat.history['old'] = [msg('o1', 'u2', conv: 'old')];
    chat.conversationsResult = const Ok([
      Conversation(id: 'c1', other: hugh),
      Conversation(id: 'sis', title: 'SIS', isSystem: true),
      Conversation(id: 'old', title: 'Old', hasLeft: true),
    ]);
  });

  group('the composer at the bottom edge', () {
    // An empty field shows the voice button in the send button's place.
    final send = find.byKey(const ValueKey('composer-voice'));

    Future<double> gap(WidgetTester t, {required TargetPlatform on}) async {
      await mountChat(t, chat, open: 'c1', platform: on);
      final screen = t.getSize(find.byType(MessageScreen)).height;
      return screen - t.getRect(send).bottom;
    }

    testWidgets('iPhone: 8 px lower than Android -- 38 px of its own, no '
        'SafeArea inset on top', (t) async {
      final android = await gap(t, on: TargetPlatform.android);
      final ios = await gap(t, on: TargetPlatform.iOS);
      expect(ios, closeTo(android - 34 - 12 + 38, 0.01));
      // ...and the composer's own surface runs to the bottom edge: no band
      // of the page left under it where a SafeArea would have been.
      final screen = t.getSize(find.byType(MessageScreen)).height;
      expect(surfaceUnder(t, send).bottom, closeTo(screen, 0.01));
      await unmount(t);
    });

    testWidgets('Android: the SafeArea keeps the composer above the inset', (
      t,
    ) async {
      await mountChat(t, chat, open: 'c1');
      final screen = t.getSize(find.byType(MessageScreen)).height;
      expect(surfaceUnder(t, send).bottom, closeTo(screen - 34, 0.01));
    });

    testWidgets('iPhone with the keyboard up: 4 px of its own above the '
        'keyboard', (t) async {
      final android = await gap(t, on: TargetPlatform.android);
      await mountChat(
        t,
        chat,
        open: 'c1',
        platform: TargetPlatform.iOS,
        keyboard: 300,
      );
      final screen = t.getSize(find.byType(MessageScreen)).height;
      final aboveKeyboard = screen - 300 - t.getRect(send).bottom;
      expect(aboveKeyboard, closeTo(android - 34 - 12 + 4, 0.01));
      await unmount(t);
    });

    for (final (id, key) in [
      ('sis', 'composer-system'),
      ('old', 'composer-left'),
    ]) {
      testWidgets('$key on iPhone keeps its words above the 34 px inset', (
        t,
      ) async {
        await mountChat(t, chat, open: id, platform: TargetPlatform.iOS);
        final screen = t.getSize(find.byType(MessageScreen)).height;
        final words = find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(RichText),
        );
        expect(words, findsWidgets, reason: '$key did not show');
        for (final e in words.evaluate()) {
          final box = e.renderObject! as RenderBox;
          final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
          expect(
            bottom,
            lessThanOrEqualTo(screen - 34),
            reason: '$key text runs under the home indicator',
          );
        }
      });
    }

    testWidgets('the message field capitalises sentences', (t) async {
      await mountChat(t, chat, open: 'c1');
      final field = t.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('composer-field')),
          matching: find.byType(TextField),
          matchRoot: true,
        ),
      );
      expect(field.textCapitalization, TextCapitalization.sentences);
    });
  });

  group('group sender colours in the chat', () {
    setUp(() {
      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Club'),
      ]);
      chat.groupRosters['g1'] = [
        const GroupMember(member: me, isAdmin: true, colorSlot: 0),
        const GroupMember(member: hugh, isAdmin: false, colorSlot: 3),
        const GroupMember(member: iona, isAdmin: false, colorSlot: 7),
        const GroupMember(
          member: gone,
          isAdmin: false,
          colorSlot: 5,
          leftReason: LeftReason.left,
        ),
      ];
      chat.history['g1'] = [
        msg('h1', 'u2', minute: 1),
        msg('i1', 'u3', minute: 2),
        msg('x1', 'u4', minute: 3),
        msg('h2', 'u2', minute: 4),
      ];
    });

    TextStyle nameStyle(WidgetTester t, String messageId) {
      final f = find.descendant(
        of: find.byKey(ValueKey('sender-$messageId')),
        matching: find.byType(RichText),
        matchRoot: true,
      );
      expect(f, findsOneWidget, reason: 'no sender name on $messageId');
      return t.widget<RichText>(f).text.style!;
    }

    for (final dark in [false, true]) {
      testWidgets('each name wears its slot colour, w600, 13 px '
          '(${dark ? 'dark' : 'light'})', (t) async {
        await mountChat(
          t,
          chat,
          open: 'g1',
          group: true,
          theme: dark ? ThemeData.dark() : ThemeData.light(),
        );
        for (final (id, slot) in [('h1', 3), ('i1', 7)]) {
          final style = nameStyle(t, id);
          expect(style.color, Color(groupColorArgb(slot, dark: dark)));
          expect(style.fontWeight, FontWeight.w600);
          expect(style.fontSize, 13);
        }
      });
    }

    testWidgets("a departed sender's name stays grey, not their slot colour", (
      t,
    ) async {
      await mountChat(t, chat, open: 'g1', group: true);
      final color = nameStyle(t, 'x1').color!;
      final palette = {
        for (var s = 0; s < groupColorSlots; s++)
          Color(groupColorArgb(s, dark: false)),
      };
      expect(palette, isNot(contains(color)));
      expect(
        (color.r - color.g).abs() < 0.08 && (color.g - color.b).abs() < 0.08,
        isTrue,
        reason: '$color is not a grey',
      );
    });

    testWidgets('a 1:1 names nobody above its bubbles', (t) async {
      await mountChat(t, chat, open: 'c1');
      expect(find.byKey(const ValueKey('sender-m1')), findsNothing);
    });
  });

  group('the list preview', () {
    String previewOf(WidgetTester t, String id) => find
        .descendant(
          of: find.byKey(ValueKey('conversation-$id')),
          matching: find.byType(RichText),
        )
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .join(' | ');

    testWidgets('names a known other sender in a group, and nobody else', (
      t,
    ) async {
      chat.conversationsResult = Ok([
        Conversation(
          id: 'g1',
          title: 'Club',
          lastMessage: 'see you',
          lastMessageAt: _t0,
          lastSenderId: 'u2',
          senders: const {'u2': GroupVoice('Hugh', 3)},
        ),
        Conversation(
          id: 'g2',
          title: 'Mine',
          lastMessage: 'my words',
          lastMessageAt: _t0,
          lastSenderId: 'u1',
          // Even were the member themself among the voices: "You:".
          senders: const {
            'u1': GroupVoice('Maya', 0),
            'u2': GroupVoice('Hugh', 3),
          },
        ),
        Conversation(
          id: 'g3',
          title: 'Stranger',
          lastMessage: 'who am i',
          lastMessageAt: _t0,
          lastSenderId: 'u9',
          senders: const {'u2': GroupVoice('Hugh', 3)},
        ),
        Conversation(
          id: 'c1',
          other: hugh,
          lastMessage: 'direct words',
          lastMessageAt: _t0,
          lastSenderId: 'u2',
          // Even were voices present, a 1:1 names nobody.
          senders: const {'u2': GroupVoice('Hugh', 3)},
        ),
        Conversation(
          id: 'sis',
          title: 'SIS',
          isSystem: true,
          lastMessage: 'whats new',
          lastMessageAt: _t0,
          lastSenderId: 'sys',
          senders: const {'sys': GroupVoice('SIS', 0)},
        ),
      ]);
      final c = await _container(chat);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ConversationList(),
          ),
        ),
      );
      await steps(t);

      expect(previewOf(t, 'g1'), contains('Hugh: see you'));
      expect(previewOf(t, 'g2'), contains('You: my words'));
      expect(previewOf(t, 'g2'), isNot(contains('Hugh')));
      expect(previewOf(t, 'g3'), contains('who am i'));
      expect(previewOf(t, 'g3'), isNot(contains(': who am i')));
      expect(previewOf(t, 'c1'), contains('direct words'));
      expect(previewOf(t, 'c1'), isNot(contains(': direct words')));
      expect(previewOf(t, 'c1'), isNot(contains('Hugh: ')));
      expect(previewOf(t, 'sis'), contains('whats new'));
      expect(previewOf(t, 'sis'), isNot(contains(': whats new')));
    });
  });

  group('the list controller', () {
    late ProviderContainer c;

    Future<void> live() async {
      c = await _container(chat);
      c.listen(conversationListProvider, (_, _) {});
      await c.read(conversationListProvider.future);
      chat.confirmAllSubscription();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    int reads() => chat.calls.where((x) => x == 'conversations').length;

    setUp(() {
      chat.conversationsResult = Ok([
        Conversation(
          id: 'g1',
          title: 'Club',
          lastMessage: 'old',
          lastMessageAt: _t0,
          lastSenderId: 'u2',
          senders: const {'u2': GroupVoice('Hugh', 3)},
        ),
      ]);
    });

    test(
      'a live message from an unknown group sender reads the list again',
      () async {
        await live();
        final before = reads();
        chat.deliver(msg('n1', 'u3', minute: 5));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(reads(), greaterThan(before), reason: 'stale, unnamed preview');
      },
    );

    test(
      'a known sender updates the preview in place and keeps the senders',
      () async {
        await live();
        final before = reads();
        chat.deliver(msg('k1', 'u2', minute: 5));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final row = c.read(conversationListProvider).requireValue.single;
        expect(row.lastMessage, 'text k1');
        expect(row.senders['u2']?.name, 'Hugh');
        expect(reads(), before, reason: 'a known sender needs no re-read');
      },
    );
  });
}
