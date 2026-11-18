// test/features/chat/unread_line_send_repro_test.dart
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
    'unread opened (history msgs(30), unread: Future.value(5)): sending a message brings the new bubble on screen',
    (t) async {
      await open(t, history: msgs(30), unread: Future.value(5));
      // sanity check: list sits at first unread, newest off screen
      expect(
        row(29),
        findsNothing,
        reason: 'newest message off screen initially',
      );
      await t.enterText(
        find.byKey(const ValueKey('composer-field')),
        'my new message',
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('composer-send')));
      await frames(t, 30);
      expect(chat.sent.length, 1, reason: 'message sent');
      expect(
        find.text('my new message', findRichText: true),
        findsOneWidget,
        reason: 'own bubble visible after send',
      );
      final top = t
          .getTopLeft(find.text('my new message', findRichText: true))
          .dy;
      final h = t.view.physicalSize.height / t.view.devicePixelRatio;
      expect(top >= 0 && top <= h, isTrue, reason: 'bubble within view');
    },
  );

  testWidgets(
    'no unread (unread: Future.value(0)): sending a message shows the new bubble',
    (t) async {
      await open(t, history: msgs(30), unread: Future.value(0));
      await t.enterText(
        find.byKey(const ValueKey('composer-field')),
        'my new message',
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('composer-send')));
      await frames(t, 30);
      expect(chat.sent.length, 1, reason: 'message sent');
      expect(
        find.text('my new message', findRichText: true),
        findsOneWidget,
        reason: 'own bubble visible after send',
      );
      final top = t
          .getTopLeft(find.text('my new message', findRichText: true))
          .dy;
      final h = t.view.physicalSize.height / t.view.devicePixelRatio;
      expect(top >= 0 && top <= h, isTrue, reason: 'bubble within view');
    },
  );
}
