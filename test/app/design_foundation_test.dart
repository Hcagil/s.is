// The v0.5.5 design foundation, seen through the app as main.dart mounts it:
// SisApp, the real controllers, and a fake only at each repository boundary.
// Colours are compared with what the active theme says, so the same checks
// hold in light and dark.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/brand.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/home/presentation/home_screen.dart';
import 'package:sis/features/profile/presentation/settings_screen.dart';

import '../support/design_fakes.dart';

const ela = Member(userId: 'u2', displayName: 'Ela Demir', tag: 'ela');
const omer = Member(userId: 'u3', displayName: 'ömer çelik', tag: 'omer');
const deniz = Member(userId: 'u4', displayName: 'Deniz Aydın', tag: 'deniz');

final conversations = [
  const Conversation(id: 'c1', other: ela, lastMessage: 'Perfect'),
  const Conversation(id: 'g1', title: '  weekend   plan  now'),
  const Conversation(id: 'c2', other: omer, lastMessage: 'ok'),
  const Conversation(id: 'g2', title: 'Family', lastMessage: 'Dinner at 8'),
  const Conversation(id: 'c3', other: deniz),
];

/// What each tile's avatar must read, worked out by hand from the contract.
const initialsById = {
  'c1': 'ED',
  'g1': 'WP',
  'c2': 'ÖÇ',
  'g2': 'F',
  'c3': 'DA',
};

Message msg(String id, String from, String body, int minute) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 23, 9, minute),
);

final history = {
  'c1': [
    msg('m1', 'u2', 'Are we still on for Saturday?', 1),
    msg('m2', 'u1', 'Yes! 10am at the market', 2),
    msg('m3', 'u2', 'Perfect', 3),
  ],
};

DesignChat chatWorld() => DesignChat(
  list: conversations,
  people: [ela, omer, deniz],
  history: history,
);

Future<void> pumpSignedIn(
  WidgetTester t, {
  DesignChat? chat,
  DesignPresence? presence,
}) async {
  await t.pumpWidget(
    designApp(
      auth: DesignAuth(session: true),
      chat: chat ?? chatWorld(),
      presence: presence,
    ),
  );
  await t.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget, reason: 'home did not open');
}

void useBrightness(WidgetTester t, Brightness b) {
  t.platformDispatcher.platformBrightnessTestValue = b;
  addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
}

ThemeData themeAt(WidgetTester t, Finder f) => Theme.of(t.element(f));

/// Every decoration painted at or under [f].
List<Decoration> decorations(Finder f) => find
    .descendant(of: f, matching: anyWidget, matchRoot: true)
    .evaluate()
    .map((e) => e.widget)
    .expand<Decoration?>(
      (w) => switch (w) {
        Container(:final decoration) => [decoration],
        DecoratedBox(:final decoration) => [decoration],
        Ink(:final decoration) => [decoration],
        _ => const [],
      },
    )
    .whereType<Decoration>()
    .toList();

final anyWidget = find.byWidgetPredicate((_) => true);

/// Every fill colour painted at or under [f].
List<Color> fills(Finder f) => [
  for (final d in decorations(f))
    if (d is BoxDecoration && d.color != null)
      d.color!
    else if (d is ShapeDecoration && d.color != null)
      d.color!,
  ...find
      .descendant(of: f, matching: anyWidget, matchRoot: true)
      .evaluate()
      .map((e) => e.widget)
      .expand<Color?>(
        (w) => switch (w) {
          Container(:final color) => [color],
          ColoredBox(:final color) => [color],
          CircleAvatar(:final backgroundColor) => [backgroundColor],
          Material(:final color) => [color],
          _ => const [],
        },
      )
      .whereType<Color>(),
];

List<Gradient> gradients(Finder f) => [
  for (final d in decorations(f))
    if (d is BoxDecoration && d.gradient != null)
      d.gradient!
    else if (d is ShapeDecoration && d.gradient != null)
      d.gradient!,
];

/// The colour a piece of text is actually painted in.
Color? paintedColor(WidgetTester t, Finder text) {
  final p = t.renderObject<RenderParagraph>(text);
  Color? c = p.text.style?.color;
  p.text.visitChildren((span) {
    c = span.style?.color ?? c;
    return false; // the first child span decides
  });
  return c;
}

/// Whether [text] sits inside something round.
bool inCircle(Finder text) => find
    .ancestor(of: text, matching: anyWidget)
    .evaluate()
    .map((e) => e.widget)
    .any(
      (w) => switch (w) {
        CircleAvatar() || ClipOval() => true,
        Container(decoration: BoxDecoration(shape: BoxShape.circle)) => true,
        DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle)) => true,
        Container(decoration: ShapeDecoration(shape: CircleBorder())) => true,
        DecoratedBox(decoration: ShapeDecoration(shape: CircleBorder())) =>
          true,
        Material(shape: CircleBorder()) => true,
        Material(type: MaterialType.circle) => true,
        _ => false,
      },
    );

bool greenish(Color c) => c.g > c.r * 1.2 && c.g > c.b * 1.2;

Finder byKey(String k) => find.byKey(ValueKey(k));

Finder textUnder(String key, String text) =>
    find.descendant(of: byKey(key), matching: find.text(text));

/// The wordmark reads "SIS", as a Text or rich text.
final wordmarkText = find.descendant(
  of: find.byType(SisWordmark),
  matching: find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == 'SIS',
  ),
);

/// Font family of every visible run of text at or under [f], icons excluded.
/// A span without its own family inherits its parent's, as the painter does.
List<(String, String?)> fontFamilies(WidgetTester t, Finder f) {
  final out = <(String, String?)>[];
  void walk(InlineSpan span, String? inherited) {
    final family = span.style?.fontFamily ?? inherited;
    if (span is TextSpan) {
      final text = span.text ?? '';
      final isIcon =
          text.runes.isNotEmpty &&
          text.runes.every((r) => r >= 0xE000 && r <= 0xF8FF);
      if (text.trim().isNotEmpty && !isIcon) out.add((text, family));
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c, family);
      }
    }
  }

  for (final e
      in find
          .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
          .evaluate()) {
    walk((e.renderObject! as RenderParagraph).text, null);
  }
  return out;
}

void main() {
  group('SisApp theming', () {
    testWidgets('follows a light system setting', (t) async {
      useBrightness(t, Brightness.light);
      await t.pumpWidget(designApp(auth: DesignAuth()));
      await t.pumpAndSettle();
      final theme = themeAt(t, find.text('Continue with Google'));
      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.primary, const Color(0xFF5B4CF0));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF5F4FA));
      expect(theme.extension<SisBrand>(), isNotNull);
    });

    testWidgets('follows a dark system setting', (t) async {
      useBrightness(t, Brightness.dark);
      await t.pumpWidget(designApp(auth: DesignAuth()));
      await t.pumpAndSettle();
      final theme = themeAt(t, find.text('Continue with Google'));
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, const Color(0xFF7B6BFF));
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0D0B22));
      expect(theme.extension<SisBrand>(), isNotNull);
    });
  });

  group('sign-in', () {
    testWidgets('shows the brand, the pitch, and the invitation rule', (
      t,
    ) async {
      await t.pumpWidget(designApp(auth: DesignAuth()));
      await t.pumpAndSettle();
      expect(find.byType(SisLogo), findsOneWidget);
      expect(find.byType(SisWordmark), findsOneWidget);
      expect(wordmarkText, findsOneWidget);
      expect(find.text('Stay in sync'), findsOneWidget);
      expect(
        find.text('Private messages for the people on your list.'),
        findsOneWidget,
      );
      expect(
        find.text('Only invited Google accounts can sign in.'),
        findsOneWidget,
      );
    });

    testWidgets('the Google button spans the width it is given', (t) async {
      // Wide enough that the label alone could never fill it.
      t.view.physicalSize = const Size(800, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(designApp(auth: DesignAuth()));
      await t.pumpAndSettle();

      final button = find
          .ancestor(
            of: find.text('Continue with Google'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          )
          .first;
      final box = t.renderObject<RenderBox>(button);
      expect(box.size.width, box.constraints.maxWidth);
      expect(
        box.size.width,
        greaterThan(box.getMaxIntrinsicWidth(double.infinity) + 24),
        reason: 'the button is only as wide as its label',
      );
    });

    testWidgets('the button signs in and lands on home', (t) async {
      final auth = DesignAuth();
      await t.pumpWidget(designApp(auth: auth, chat: chatWorld()));
      await t.pumpAndSettle();
      await t.tap(find.text('Continue with Google'));
      await t.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a canceled sign-in shows its reason and stays put', (t) async {
      final auth = DesignAuth(
        // A canceled sign-in is the one that returns to this screen.
        signInResult: const Err(
          ProviderFailure('account not on the list', userCanceled: true),
        ),
      );
      await t.pumpWidget(designApp(auth: auth));
      await t.pumpAndSettle();
      await t.tap(find.text('Continue with Google'));
      await t.pumpAndSettle();
      expect(auth.signInCalls, 1);
      expect(find.textContaining('account not on the list'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(SisLogo), findsOneWidget);
    });
  });

  group('home app bar', () {
    testWidgets('shows the logo and the wordmark, not a plain title', (
      t,
    ) async {
      await pumpSignedIn(t);
      final bar = find.byType(AppBar);
      expect(
        find.descendant(of: bar, matching: find.byType(SisLogo)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.byType(SisWordmark)),
        findsOneWidget,
      );
      expect(wordmarkText, findsOneWidget);
      final plainSis = find.descendant(of: bar, matching: find.text('SIS'));
      expect(
        plainSis.evaluate().length,
        find
            .descendant(
              of: find.byType(SisWordmark),
              matching: find.text('SIS'),
            )
            .evaluate()
            .length,
        reason: 'a plain "SIS" title is still in the app bar',
      );
    });

    testWidgets('the menu still opens settings and signs out', (t) async {
      await pumpSignedIn(t);
      await t.tap(byKey('home-menu'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-settings'));
      await t.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(byKey('home-menu'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-sign-out'));
      await t.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
    });
  });

  for (final b in Brightness.values) {
    group('conversation list ($b)', () {
      testWidgets('every tile shows its initials in a circle', (t) async {
        useBrightness(t, b);
        await pumpSignedIn(t);
        for (final MapEntry(key: id, value: initials) in initialsById.entries) {
          final f = textUnder('conversation-$id', initials);
          await t.scrollUntilVisible(byKey('conversation-$id'), 100);
          expect(f, findsOneWidget, reason: '$id should read $initials');
          expect(inCircle(f), isTrue, reason: '$id initials are not round');
        }
      });

      testWidgets('the online dot is the primary colour, never green', (
        t,
      ) async {
        useBrightness(t, b);
        await pumpSignedIn(t, presence: DesignPresence(online: {'u2'}));
        final dot = byKey('online-c1');
        expect(dot, findsOneWidget);
        expect(byKey('online-c2'), findsNothing, reason: 'ömer is offline');
        expect(byKey('online-c3'), findsNothing, reason: 'Deniz is offline');

        final primary = themeAt(t, dot).colorScheme.primary;
        final painted = fills(dot);
        expect(painted, contains(primary));
        expect(painted.where(greenish), isEmpty);
      });

      testWidgets('the new-chat picker shows initials avatars', (t) async {
        useBrightness(t, b);
        await pumpSignedIn(t);
        await t.tap(find.text('New chat'));
        await t.pumpAndSettle();
        for (final (id, initials) in [
          ('u2', 'ED'),
          ('u3', 'ÖÇ'),
          ('u4', 'DA'),
        ]) {
          final f = textUnder('member-$id', initials);
          expect(f, findsOneWidget, reason: '$id should read $initials');
          expect(inCircle(f), isTrue);
        }
      });
    });

    group('text is set in Manrope ($b)', () {
      testWidgets('every text in the conversation list', (t) async {
        useBrightness(t, b);
        final chat = chatWorld()
          ..list = [
            Conversation(
              id: 'c1',
              other: ela,
              lastMessage: 'Perfect',
              lastMessageAt: DateTime.now().toUtc(),
              lastSenderId: 'u2',
            ),
            Conversation(
              id: 'c2',
              other: omer,
              lastMessage: 'On my way',
              lastMessageAt: DateTime.utc(2026, 9, 1, 12),
              lastSenderId: 'u1', // the "You: …" form
            ),
            const Conversation(id: 'g2', title: 'Family'),
          ];
        await pumpSignedIn(t, chat: chat);

        final seen = [
          for (final id in ['c1', 'c2', 'g2'])
            ...fontFamilies(t, byKey('conversation-$id')),
        ];
        final texts = seen.map((s) => s.$1).join(' | ');
        // The fixture really rendered names, previews, "You" and times.
        for (final part in ['Ela Demir', 'Perfect', 'On my way', 'You']) {
          expect(texts, contains(part));
        }
        expect(texts, contains(RegExp(r'\d\d[:.]\d\d')), reason: 'no time');
        expect(
          seen.where((s) => s.$2 != 'Manrope').toList(),
          isEmpty,
          reason: 'text not in Manrope',
        );
      });

      testWidgets('the composer hint', (t) async {
        useBrightness(t, b);
        await pumpSignedIn(t);
        await t.tap(byKey('conversation-c1'));
        await t.pumpAndSettle();
        final hint = find.descendant(
          of: byKey('composer-field'),
          matching: find.text('Message'),
        );
        expect(hint, findsOneWidget);
        expect(fontFamilies(t, hint), [('Message', 'Manrope')]);
      });
    });

    group('message screen ($b)', () {
      Future<DesignPresence> open(WidgetTester t) async {
        useBrightness(t, b);
        final presence = DesignPresence(online: {'u2'});
        await pumpSignedIn(t, presence: presence);
        await t.tap(byKey('conversation-c1'));
        await t.pumpAndSettle();
        expect(find.byType(MessageScreen), findsOneWidget);
        return presence;
      }

      testWidgets('my bubble is the brand gradient with white text', (t) async {
        await open(t);
        final mine = byKey('message-m2');
        final brand = SisBrand.of(t.element(mine));
        expect(gradients(mine), contains(brand.gradient));
        expect(
          paintedColor(t, find.text('Yes! 10am at the market')),
          const Color(0xFFFFFFFF),
        );
      });

      testWidgets('their bubbles are the flat "theirs" colour', (t) async {
        await open(t);
        for (final id in ['m1', 'm3']) {
          final theirs = byKey('message-$id');
          final brand = SisBrand.of(t.element(theirs));
          expect(fills(theirs), contains(brand.theirs));
          expect(gradients(theirs), isEmpty, reason: '$id is a gradient');
        }
      });

      testWidgets('the status line is primary, online and typing', (t) async {
        final presence = await open(t);
        final status = byKey('conversation-status');
        final primary = themeAt(t, status).colorScheme.primary;

        final online = find.descendant(
          of: status,
          matching: find.text('online'),
          matchRoot: true,
        );
        expect(online, findsOneWidget);
        expect(paintedColor(t, online), primary);

        presence.channels['c1']!.type('u2');
        await t.pump();
        await t.pump();
        final typing = find.descendant(
          of: status,
          matching: find.textContaining('typing…'),
          matchRoot: true,
        );
        expect(typing, findsOneWidget);
        expect(paintedColor(t, typing), primary);
        await t.pump(const Duration(seconds: 10)); // let typing lapse
        await t.pumpAndSettle();
      });
    });
  }
}
