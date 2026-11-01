// The Bacanaks Ozel command chat in the app, from the contract:
// - header: the name "Bacanaks Özel", subtitle "Not end-to-end encrypted"
//   (TR "Uçtan uca şifreli değil"), its own avatar; a normal chat has none.
// - composer: hint "Type / for commands"; typing "/" opens the command panel
//   with /podium and "Total money from Vega"; a tap sends /podium through the
//   chat repository at once. A normal chat has no panel.
// - reply bubble: pod / podPrev show the title, the amount as given, and
//   "From Vega, fetched at HH:MM" in the phone's local time; no "Unchecked"
//   tag. podFail / podOff show their fixed text. EN and TR.
// - chat-list preview: an answer shows the title only, never the amount.
// Time is shown in local time: run under TZ=JST-9 (as CI does).
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
import 'package:sis/features/chat/presentation/bacanaks_widgets.dart'
    show BacanaksAvatar;
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

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

ChatFake world({required bool bacanaks}) => ChatFake(self: me.userId)
  ..conversationsResult = Ok([
    bacanaks
        ? const Conversation(
            id: 'c1',
            title: 'x',
            isAdminChat: true,
            isBacanaks: true,
          )
        : const Conversation(id: 'c1', other: bob),
  ])
  ..membersResult = const Ok([bob])
  ..messagesResult = const Ok([]);

Future<ChatFake> pumpChat(
  WidgetTester t, {
  required bool bacanaks,
  Locale locale = const Locale('en'),
}) async {
  t.view.physicalSize = const Size(411, 891);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final chat = world(bacanaks: bacanaks);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: localizedApp(
        locale: locale,
        home: MessageScreen(title: bacanaks ? 'Bacanaks Özel' : 'Bob'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return chat;
}

Finder get field => find.descendant(
  of: byKey('composer-field'),
  matching: find.byType(EditableText),
);

Future<void> pumpBubble(
  WidgetTester t,
  Map<String, dynamic> m,
  Locale locale,
) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
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
                body: '',
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
  // 02:20 UTC = 11:20 under JST-9 (CI and the test containers), 05:20 in Istanbul.
  final at = DateTime.utc(2026, 10, 29, 2, 20);
  String hhmm(DateTime d) {
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  test('the clock under test is not UTC (run with TZ=JST-9)', () {
    expect(
      at.toLocal().timeZoneOffset,
      isNot(Duration.zero),
      reason: 'under UTC a missing toLocal() would pass unseen',
    );
  });

  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    final lang = locale.languageCode;

    testWidgets(
      '[$lang] header: name, "not end-to-end encrypted" subtitle and avatar',
      (t) async {
        await pumpChat(t, bacanaks: true, locale: locale);
        expect(find.text('Bacanaks Özel'), findsWidgets);
        expect(find.text(l.podNotEnc), findsOneWidget);
        expect(find.byType(BacanaksAvatar), findsOneWidget);
      },
    );

    testWidgets(
      '[$lang] a normal chat has no Bacanaks subtitle, avatar, hint or panel',
      (t) async {
        await pumpChat(t, bacanaks: false, locale: locale);
        expect(find.text(l.podNotEnc), findsNothing);
        expect(find.byType(BacanaksAvatar), findsNothing);
        expect(find.text(l.podHint), findsNothing);
        await t.enterText(field, '/');
        await t.pumpAndSettle();
        expect(
          find.text(l.podCmdDesc),
          findsNothing,
          reason: 'no command panel',
        );
      },
    );

    testWidgets(
      '[$lang] composer hint, then "/" opens the panel and a tap sends /podium',
      (t) async {
        final chat = await pumpChat(t, bacanaks: true, locale: locale);
        expect(find.text(l.podHint), findsOneWidget);
        expect(
          find.text(l.podCmdDesc),
          findsNothing,
          reason: 'no panel before "/"',
        );
        await t.enterText(field, '/');
        await t.pumpAndSettle();
        expect(find.text(l.podCmdDesc), findsOneWidget);
        expect(find.text('/podium'), findsOneWidget);
        expect(
          chat.sent,
          isEmpty,
          reason: 'nothing is sent by opening the panel',
        );
        await t.tap(find.text('/podium'));
        await t.pumpAndSettle();
        expect(chat.sent.map((s) => (s.conversationId, s.body)).toList(), [
          ('c1', '/podium'),
        ]);
        expect(
          find.text(l.podCmdDesc),
          findsNothing,
          reason: 'the panel closes after sending',
        );
      },
    );

    testWidgets('[$lang] "/po" keeps the panel; "/x" closes it', (t) async {
      await pumpChat(t, bacanaks: true, locale: locale);
      await t.enterText(field, '/po');
      await t.pumpAndSettle();
      expect(find.text(l.podCmdDesc), findsOneWidget);
      await t.enterText(field, '/x');
      await t.pumpAndSettle();
      expect(find.text(l.podCmdDesc), findsNothing);
    });

    testWidgets(
      '[$lang] pod: title, amount as given, fetched line in local time, no Unchecked tag',
      (t) async {
        await pumpBubble(t, {
          'k': 'pod',
          'amt': amount,
          'day': '2026-10-29',
          'at': at.toIso8601String(),
        }, locale);
        final s = screenText(t);
        expect(s, contains(l.podTitle));
        expect(s, contains(amount));
        expect(s, contains(l.podFetched(hhmm(at))));
        expect(hhmm(at), '11:20', reason: 'fixture: JST-9');
        expect(
          s,
          isNot(contains('02:20')),
          reason: 'the fetch time is not shown in UTC',
        );
        for (final tag in [
          'Unchecked',
          'unchecked',
          'Kontrol edilmedi',
          'kontrol edilmedi',
        ]) {
          expect(s, isNot(contains(tag)));
        }
      },
    );

    testWidgets(
      '[$lang] pod / podPrev: a whole number ("7", "12345") and "99.999,99" are shown exactly as given',
      (t) async {
        for (final k in ['pod', 'podPrev']) {
          Future<String> shown(String amt) async {
            await pumpBubble(t, {
              'k': k,
              'amt': amt,
              'day': '2026-10-28',
              'at': at.toIso8601String(),
            }, locale);
            return screenText(t);
          }

          // The same bubble with a marker amount: the only difference allowed
          // is the amount itself, so a lone "7" cannot hide in other text.
          final base = await shown('#AMT#');
          expect(base, contains('#AMT#'));
          for (final amt in ['7', '12345', '99.999,99']) {
            expect(
              await shown(amt),
              base.replaceAll('#AMT#', amt),
              reason: '$k $amt',
            );
          }
        }
      },
    );

    testWidgets(
      '[$lang] podPrev: previous-day title with the day, amount, fetched line',
      (t) async {
        await pumpBubble(t, {
          'k': 'podPrev',
          'amt': amount,
          'day': '2026-10-28',
          'at': at.toIso8601String(),
        }, locale);
        final s = screenText(t);
        final title = l.podPrevTitle('§');
        expect(s, contains(title.substring(0, title.indexOf('§'))));
        expect(
          RegExp(r'\(28\b[^)]*\)').hasMatch(s),
          isTrue,
          reason: 'the previous day (28th) is named: $s',
        );
        expect(
          s,
          isNot(contains(l.podTitle)),
          reason: 'not the current-day title',
        );
        expect(s, contains(amount));
        expect(s, contains(l.podFetched(hhmm(at))));
        expect(s, isNot(contains('Unchecked')));
        expect(s, isNot(contains('Kontrol edilmedi')));
      },
    );

    testWidgets(
      '[$lang] podFail and podOff show their fixed text and no amount line',
      (t) async {
        await pumpBubble(t, {'k': 'podFail'}, locale);
        expect(screenText(t), contains(l.podFail));
        expect(screenText(t), isNot(contains(l.podFetched('').trim())));
        await pumpBubble(t, {'k': 'podOff'}, locale);
        expect(screenText(t), contains(l.podOff));
      },
    );

    test(
      '[$lang] the chat-list preview of an answer is the title only, never the amount',
      () {
        final pod = adminPreviewLine(l, {
          'k': 'pod',
          'amt': amount,
          'day': '2026-10-29',
          'at': at.toIso8601String(),
        });
        final prev = adminPreviewLine(l, {
          'k': 'podPrev',
          'amt': amount,
          'day': '2026-10-28',
          'at': at.toIso8601String(),
        });
        expect(pod, l.podTitle);
        expect(prev, isNot(contains(amount)));
        expect(prev, isNotEmpty);
        expect(adminPreviewLine(l, {'k': 'podFail'}), l.podFail);
        expect(adminPreviewLine(l, {'k': 'podOff'}), l.podOff);
      },
    );
  }
}
