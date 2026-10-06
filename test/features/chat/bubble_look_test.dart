// Two looks of Update 1 slice 5, on the real MessageScreen:
//  * my bubble's text reads at 4.5:1 or better on its gradient, in all six
//    palettes, light and dark (before this slice 10 of 12 were below);
//  * a photo-only bubble (an attachment and nothing else: no body, reply,
//    forward or deletion) has no outer box; its time -- and on mine the tick
//    -- sit on the photo in a dark pill; the photo box keeps its fixed size.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final t0 = DateTime.utc(2026, 10, 5, 9);

Message msg(
  String id, {
  String body = '',
  String from = 'u1',
  String? path,
  String? replyTo,
  bool forwarded = false,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: t0.add(Duration(minutes: minute)),
  attachmentPath: path,
  replyTo: replyTo,
  forwarded: forwarded,
);

Future<void> pump(
  WidgetTester t,
  List<Message> history, {
  Brightness brightness = Brightness.light,
  AppThemeId palette = AppThemeId.violet,
}) async {
  t.view
    ..physicalSize = const Size(800, 2400)
    ..devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final chat = ChatFake(self: me.userId)
    ..history['c1'] = history
    ..holdBytes(); // photos stay in flight: the box is the fixed one
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(brightness, theme: palette),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Finder key(String k) => find.byKey(ValueKey(k));

/// Every painted (filled or gradient) box decoration under [of], with its
/// on-screen rect.
List<(Decoration, Rect)> painted(WidgetTester t, Finder of) => [
  for (final e
      in find
          .descendant(
            of: of,
            matching: find.byWidgetPredicate((_) => true),
            matchRoot: true,
          )
          .evaluate())
    if (switch (e.widget) {
          Container(:final decoration) => decoration,
          DecoratedBox(:final decoration) => decoration,
          Ink(:final decoration) => decoration,
          _ => null,
        }
        case final Decoration d
        when (d is BoxDecoration && (d.color != null || d.gradient != null)) ||
            (d is ShapeDecoration && (d.color != null || d.gradient != null)))
      (d, t.getRect(find.byElementPredicate((x) => x == e))),
];

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Color? textColour(WidgetTester t, Finder text) {
  final p = t.renderObject<RenderParagraph>(text);
  Color? c = p.text.style?.color;
  p.text.visitChildren((span) {
    c = span.style?.color ?? c;
    return false;
  });
  return c;
}

bool inside(Rect inner, Rect outer) =>
    outer.inflate(0.5).contains(inner.topLeft) &&
    outer.inflate(0.5).contains(inner.bottomRight);

void main() {
  group('my bubble text contrast', () {
    for (final palette in AppThemeId.values) {
      for (final b in Brightness.values) {
        testWidgets('${palette.name}, ${b.name}: at least 4.5:1', (t) async {
          await pump(
            t,
            [msg('m', body: 'hello there')],
            brightness: b,
            palette: palette,
          );
          final bubble = key('message-m');
          final gradients = [
            for (final (d, _) in painted(t, bubble))
              if (d case BoxDecoration(gradient: final Gradient g)) g,
          ];
          expect(gradients, isNotEmpty, reason: 'my bubble has no gradient');
          final text = textColour(
            t,
            find.descendant(of: bubble, matching: find.text('hello there')),
          )!;
          final stops = gradients.first.colors;
          var worst = double.infinity;
          for (var i = 0; i + 1 < stops.length; i++) {
            for (var k = 0; k <= 10; k++) {
              final c = Color.lerp(stops[i], stops[i + 1], k / 10)!;
              worst = math.min(worst, contrast(text, c));
            }
          }
          expect(
            worst,
            greaterThanOrEqualTo(4.5),
            reason: 'text $text on $stops',
          );
        });
      }
    }

    test(
      'forWhiteText gives a colour white text reads on at min or better',
      () {
        for (final c in [
          const Color(0xFF3A1D8F),
          const Color(0xFF8B7CF6),
          const Color(0xFF39C6F0),
          const Color(0xFFFFD54F),
          const Color(0xFFFFFFFF),
        ]) {
          expect(
            contrast(Colors.white, SisBrand.forWhiteText(c)),
            greaterThanOrEqualTo(4.5),
            reason: '$c',
          );
          expect(
            contrast(Colors.white, SisBrand.forWhiteText(c, min: 7)),
            greaterThanOrEqualTo(7),
            reason: '$c at 7',
          );
        }
      },
    );
  });

  group('a photo-only bubble', () {
    Future<void> photos(WidgetTester t) => pump(t, [
      msg('a', body: 'hello', from: 'u2'),
      msg('p', path: 'c1/p.jpg', minute: 1),
      msg('q', body: 'a caption', path: 'c1/q.jpg', minute: 2),
      msg('r', path: 'c1/r.jpg', from: 'u2', minute: 3),
      msg('s', path: 'c1/s.jpg', replyTo: 'a', minute: 4),
      msg('f', path: 'c1/f.jpg', forwarded: true, minute: 5),
    ]);

    void boxless(WidgetTester t, String id, String path, {required bool tick}) {
      final photo = t.getRect(key('attachment-$path'));
      for (final (d, r) in painted(t, key('message-$id'))) {
        expect(
          inside(r, photo),
          isTrue,
          reason: '$id: a painted box $r ($d) reaches outside the photo $photo',
        );
      }
      final time = t.getRect(key('time-$id'));
      expect(inside(time, photo), isTrue, reason: 'time $time not on photo');
      if (tick) {
        final k = t.getRect(key('tick-$id'));
        expect(inside(k, photo), isTrue, reason: 'tick $k not on photo');
      } else {
        expect(key('tick-$id'), findsNothing);
      }
      // The pill: a dark painted box on the photo holding the time.
      final pills = [
        for (final (d, r) in painted(t, key('message-$id')))
          if (inside(time, r) && inside(r, photo) && r.width < photo.width - 4)
            if (switch (d) {
                  BoxDecoration(:final color?) => color,
                  ShapeDecoration(:final color?) => color,
                  _ => null,
                }
                case final Color c when c.a > 0.3 && c.computeLuminance() < 0.2)
              r,
      ];
      expect(pills, isNotEmpty, reason: '$id: the time is not in a dark pill');
    }

    testWidgets('mine: no box, time and tick on the photo in a dark pill', (
      t,
    ) async {
      await photos(t);
      boxless(t, 'p', 'c1/p.jpg', tick: true);
    });

    testWidgets('theirs: no box, time on the photo in a dark pill', (t) async {
      await photos(t);
      boxless(t, 'r', 'c1/r.jpg', tick: false);
    });

    testWidgets('the photo box keeps its fixed size: the same as with a '
        'caption', (t) async {
      await photos(t);
      expect(
        t.getSize(key('attachment-c1/p.jpg')),
        t.getSize(key('attachment-c1/q.jpg')),
      );
      expect(
        t.getSize(key('attachment-c1/r.jpg')),
        t.getSize(key('attachment-c1/q.jpg')),
      );
    });

    testWidgets('a caption, a reply or a forward keeps the box, and the time '
        'below the photo', (t) async {
      await photos(t);
      for (final (id, path) in [
        ('q', 'c1/q.jpg'),
        ('s', 'c1/s.jpg'),
        ('f', 'c1/f.jpg'),
      ]) {
        final photo = t.getRect(key('attachment-$path'));
        final outside = [
          for (final (_, r) in painted(t, key('message-$id')))
            if (!inside(r, photo)) r,
        ];
        expect(outside, isNotEmpty, reason: '$id lost its box');
        expect(
          t.getRect(key('time-$id')).top,
          greaterThanOrEqualTo(photo.bottom - 0.5),
          reason: '$id: the time is on the photo',
        );
      }
    });
  });
}
