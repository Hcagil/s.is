import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/admin_chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/text_sharer.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const bot = '00000000-0000-0000-0000-00000000ad41';
const amount = '12.345,67';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _NoSharer implements TextSharer {
  @override
  Future<void> share(String text) async {}
}

class _NoAdminRepo implements AdminChatRepository {
  @override
  Future<Result<void>> answer(String cardId, bool yes) async => const Ok(null);
}

Finder byKey(String k) => find.byKey(ValueKey(k));

String screenText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
  for (final t in tester.widgetList<RichText>(find.byType(RichText)))
    t.text.toPlainText(),
  for (final t in tester.widgetList<EditableText>(find.byType(EditableText)))
    t.controller.text,
].join('\n');

ChatFake world(String? key) => ChatFake(self: me.userId)
  ..conversationsResult = Ok([
    key != null
        ? Conversation(id: 'c1', title: 'x', isAdminChat: true, staffKey: key)
        : const Conversation(id: 'c1', other: bob),
  ])
  ..membersResult = const Ok([bob])
  ..messagesResult = const Ok([]);

Future<void> pumpBubble(
  WidgetTester t,
  Map<String, dynamic> m,
  Locale locale, {
  String body = '',
}) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(staff: StaffRegistryFake(stored: neutralRegistry())),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        chatRepositoryProvider.overrideWithValue(world('staff_b')),
        textSharerProvider.overrideWithValue(_NoSharer()),
        adminChatRepositoryProvider.overrideWithValue(_NoAdminRepo()),
      ],
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminReplyBubble(
              message: Message(
                id: 'r1',
                conversationId: 'c1',
                senderId: bot,
                body: body,
                createdAt: DateTime.utc(2026, 10, 29, 2, 21),
                adminMsg: m,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    final lang = locale.languageCode;

    testWidgets('[$lang] salesTotal renders title, amount and fetched line', (
      t,
    ) async {
      await pumpBubble(t, {
        'k': 'salesTotal',
        'amt': amount,
        'at': DateTime.utc(2026, 10, 29, 2, 20).toIso8601String(),
      }, locale);
      final s = screenText(t);
      expect(s, contains(l.salesTitle));
      expect(s, contains(amount));
    });

    testWidgets(
      '[$lang] salesTotalPrev renders previous-day title and amount',
      (t) async {
        await pumpBubble(t, {'k': 'salesTotalPrev', 'amt': amount}, locale);
        final s = screenText(t);
        expect(s, contains(l.salesPrevTitle('')));
        expect(s, contains(amount));
      },
    );

    testWidgets('[$lang] salesFailed renders failure text', (t) async {
      await pumpBubble(t, {'k': 'salesFailed'}, locale);
      expect(screenText(t), contains(l.salesFail));
    });

    testWidgets('[$lang] salesIsOff renders off text', (t) async {
      await pumpBubble(t, {'k': 'salesIsOff'}, locale);
      expect(screenText(t), contains(l.salesOff));
    });

    testWidgets('[$lang] salesUnknown renders unknown text with command', (
      t,
    ) async {
      await pumpBubble(t, {'k': 'salesUnknown', 'c': '/report'}, locale);
      expect(screenText(t), contains(l.salesUnknown('/report')));
    });

    testWidgets('[$lang] salesLimit renders rate limit text', (t) async {
      await pumpBubble(t, {'k': 'salesLimit'}, locale);
      expect(screenText(t), contains(l.salesRate));
    });

    testWidgets('[$lang] salesSwitchOn renders switch on text with command', (
      t,
    ) async {
      await pumpBubble(t, {'k': 'salesSwitchOn', 'c': '/report'}, locale);
      expect(screenText(t), contains(l.salesSwOn('/report')));
    });

    testWidgets('[$lang] salesSwitchOff renders switch off text with command', (
      t,
    ) async {
      await pumpBubble(t, {'k': 'salesSwitchOff', 'c': '/report'}, locale);
      expect(screenText(t), contains(l.salesSwOff('/report')));
    });

    testWidgets('[$lang] unknown key falls back to the body text', (t) async {
      await pumpBubble(
        t,
        {'k': 'zzNewKey'},
        locale,
        body: 'Plain English body',
      );
      expect(screenText(t), contains('Plain English body'));
    });
  }
}
