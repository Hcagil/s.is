import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';

import 'package:sis/features/appearance/domain/custom_theme.dart';

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

Finder key(String k) => find.byKey(ValueKey(k));

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

bool paintsWhite(WidgetTester t, Finder of) {
  for (final (d, _) in painted(t, of)) {
    if (d case BoxDecoration(:final color, :final gradient)) {
      if (color == const Color(0xFFFFFFFF)) return true;
      if (gradient case Gradient g) {
        if (g.colors.every((c) => c == const Color(0xFFFFFFFF))) return true;
      }
    }
  }
  return false;
}

const white = CustomTheme(
  id: 'w',
  name: 'White',
  mode: CustomThemeMode.light,
  accent: 0xFF7B6BFF,
  mine: 0xFFFFFFFF,
  theirs: 0xFFFFFFFF,
  background: 0xFF0D0B22,
);

Future<void> pump(
  WidgetTester t,
  List<Message> history, {
  Brightness brightness = Brightness.light,
  required SisBrand brand,
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
        theme: sisTheme(brightness, brand: brand),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('white bubble text contrast', () {
    for (final b in Brightness.values) {
      testWidgets('mine bubble shows dark readable text on $b', (t) async {
        final brand = sisBrandForCustom(white, b);
        await pump(
          t,
          [msg('m', body: 'hello there')],
          brightness: b,
          brand: brand,
        );
        final bubble = key('message-m');
        final text = textColour(
          t,
          find.descendant(of: bubble, matching: find.text('hello there')),
        )!;
        expect(
          contrast(text, const Color(0xFFFFFFFF)),
          greaterThanOrEqualTo(4.5),
        );
        expect(text, brand.onMine);
        expect(paintsWhite(t, bubble), isTrue);
      });

      testWidgets('theirs bubble shows dark readable text on $b', (t) async {
        final brand = sisBrandForCustom(white, b);
        await pump(
          t,
          [msg('o', body: 'hi back', from: 'u2')],
          brightness: b,
          brand: brand,
        );
        final bubble = key('message-o');
        final text = textColour(
          t,
          find.descendant(of: bubble, matching: find.text('hi back')),
        )!;
        expect(
          contrast(text, const Color(0xFFFFFFFF)),
          greaterThanOrEqualTo(4.5),
        );
        expect(text, brand.onTheirs);
      });
    }
  });
}
