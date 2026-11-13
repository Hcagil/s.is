// The sales staff chat in the app (the registry chat whose commands include
// the sales_total handler), from the contract:
// - header: the registry title, subtitle "Not end-to-end encrypted"
//   (TR "Uçtan uca şifreli değil"), its own avatar; a normal chat and a staff
//   chat without sales_total have none.
// - composer: hint "Type / for commands"; typing "/" opens the command list
//   with the registry word and its server help; a tap fills "/word " and
//   sends nothing. A normal chat has no list.
// - reply bubble: salesTotal / salesTotalPrev show the title, the amount as given, and
//   the fetched line at HH:MM in the phone's local time; no "Unchecked"
//   tag. salesFailed / salesIsOff show their fixed text. EN and TR.
// - chat-list preview: an answer shows the title only, never the amount.
// Time is shown in local time: run under TZ=JST-9 (as CI does).
// Fixture words are neutral ("/report", "staff_b"), never real ones.
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
import 'package:sis/features/chat/presentation/staff_widgets.dart'
    show SalesAvatar;
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

/// [key] null: a normal 1:1 chat; else a staff chat with that staffKey.
ChatFake world(String? key) => ChatFake(self: me.userId)
  ..conversationsResult = Ok([
    key != null
        ? Conversation(id: 'c1', title: 'x', isAdminChat: true, staffKey: key)
        : const Conversation(id: 'c1', other: bob),
  ])
  ..membersResult = const Ok([bob])
  ..messagesResult = const Ok([]);

Future<ChatFake> pumpChat(
  WidgetTester t, {
  required String? key,
  Locale locale = const Locale('en'),
}) async {
  t.view.physicalSize = const Size(411, 891);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final chat = world(key);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(staff: StaffRegistryFake(stored: neutralRegistry())),
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
        // A staff chat takes its title from the registry.
        home: MessageScreen(title: key == null ? 'Bob' : null),
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
        await pumpChat(t, key: 'staff_b', locale: locale);
        expect(find.text(lang == 'tr' ? 'Ekip B' : 'Staff B'), findsWidgets);
        expect(find.text(l.salesNotEnc), findsOneWidget);
        expect(find.byType(SalesAvatar), findsOneWidget);
      },
    );

    testWidgets(
      '[$lang] a normal chat has no sales subtitle, avatar, hint or panel',
      (t) async {
        await pumpChat(t, key: null, locale: locale);
        expect(find.text(l.salesNotEnc), findsNothing);
        expect(find.byType(SalesAvatar), findsNothing);
        expect(find.text(l.salesHint), findsNothing);
        await t.enterText(field, '/');
        await t.pumpAndSettle();
        expect(byKey('command-list-panel'), findsNothing);
      },
    );

    testWidgets(
      '[$lang] a staff chat without the sales_total handler is not the sales chat',
      (t) async {
        await pumpChat(t, key: 'staff_a', locale: locale);
        expect(find.text(l.salesNotEnc), findsNothing);
        expect(find.byType(SalesAvatar), findsNothing);
      },
    );

    testWidgets(
      '[$lang] composer hint, then "/" opens the list and a tap fills /report without sending',
      (t) async {
        final chat = await pumpChat(t, key: 'staff_b', locale: locale);
        expect(find.text(l.salesHint), findsOneWidget);
        expect(byKey('command-list-panel'), findsNothing);
        await t.enterText(field, '/');
        await t.pumpAndSettle();
        expect(byKey('command-list-panel'), findsOneWidget);
        expect(
          find.text((lang == 'tr' ? 'Toplamı göster' : 'Show the total')),
          findsOneWidget,
        );
        expect(find.text('/report'), findsOneWidget);
        expect(chat.sent, isEmpty, reason: 'opening the list sends nothing');
        await t.tap(find.text('/report'));
        await t.pumpAndSettle();
        expect(chat.sent, isEmpty, reason: 'a pick never sends');
        expect(t.widget<EditableText>(field).controller.text, '/report ');
        expect(byKey('command-list-panel'), findsNothing);
      },
    );

    testWidgets('[$lang] "/rep" keeps the list; "/x" closes it', (t) async {
      await pumpChat(t, key: 'staff_b', locale: locale);
      await t.enterText(field, '/rep');
      await t.pumpAndSettle();
      expect(byKey('command-list-panel'), findsOneWidget);
      await t.enterText(field, '/x');
      await t.pumpAndSettle();
      expect(byKey('command-list-panel'), findsNothing);
    });

    testWidgets(
      '[$lang] salesTotal: title, amount as given, fetched line in local time, no Unchecked tag',
      (t) async {
        await pumpBubble(t, {
          'k': 'salesTotal',
          'amt': amount,
          'day': '2026-10-29',
          'at': at.toIso8601String(),
        }, locale);
        final s = screenText(t);
        expect(s, contains(l.salesTitle));
        expect(s, contains(amount));
        expect(s, contains(l.salesFetchedNoSource(hhmm(at))));
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
      '[$lang] salesTotal / salesTotalPrev: a whole number ("7", "12345") and "99.999,99" are shown exactly as given',
      (t) async {
        for (final k in ['salesTotal', 'salesTotalPrev']) {
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
      '[$lang] salesTotalPrev: previous-day title with the day, amount, fetched line',
      (t) async {
        await pumpBubble(t, {
          'k': 'salesTotalPrev',
          'amt': amount,
          'day': '2026-10-28',
          'at': at.toIso8601String(),
        }, locale);
        final s = screenText(t);
        final title = l.salesPrevTitle('§');
        expect(s, contains(title.substring(0, title.indexOf('§'))));
        expect(
          RegExp(r'\(28\b[^)]*\)').hasMatch(s),
          isTrue,
          reason: 'the previous day (28th) is named: $s',
        );
        expect(
          s,
          isNot(contains(l.salesTitle)),
          reason: 'not the current-day title',
        );
        expect(s, contains(amount));
        expect(s, contains(l.salesFetchedNoSource(hhmm(at))));
        expect(s, isNot(contains('Unchecked')));
        expect(s, isNot(contains('Kontrol edilmedi')));
      },
    );

    testWidgets(
      '[$lang] salesTotal / salesTotalPrev: a src key shows the source line; no src shows the no-source line',
      (t) async {
        for (final k in ['salesTotal', 'salesTotalPrev']) {
          // with src
          await pumpBubble(t, {
            'k': k,
            'amt': amount,
            'day': '2026-10-28',
            'at': at.toIso8601String(),
            'src': 'QaSource',
          }, locale);
          final sWithSrc = screenText(t);
          expect(sWithSrc, contains(l.salesFetched('QaSource', hhmm(at))));
          expect(sWithSrc, isNot(contains(l.salesFetchedNoSource(hhmm(at)))));
          // without src
          await pumpBubble(t, {
            'k': k,
            'amt': amount,
            'day': '2026-10-28',
            'at': at.toIso8601String(),
          }, locale);
          final sNoSrc = screenText(t);
          expect(sNoSrc, contains(l.salesFetchedNoSource(hhmm(at))));
          expect(sNoSrc, isNot(contains('QaSource')));
          // src empty
          await pumpBubble(t, {
            'k': k,
            'amt': amount,
            'day': '2026-10-28',
            'at': at.toIso8601String(),
            'src': '',
          }, locale);
          final sEmptySrc = screenText(t);
          expect(sEmptySrc, contains(l.salesFetchedNoSource(hhmm(at))));
        }
      },
    );

    testWidgets(
      '[$lang] salesFailed and salesIsOff show their fixed text and no amount line',
      (t) async {
        await pumpBubble(t, {'k': 'salesFailed'}, locale);
        expect(screenText(t), contains(l.salesFail));
        expect(
          screenText(t),
          isNot(contains(l.salesFetchedNoSource('').trim())),
        );
        await pumpBubble(t, {'k': 'salesIsOff'}, locale);
        expect(screenText(t), contains(l.salesOff));
      },
    );

    test(
      '[$lang] the chat-list preview of an answer is the title only, never the amount',
      () {
        final salesTotal = adminPreviewLine(l, {
          'k': 'salesTotal',
          'amt': amount,
          'day': '2026-10-29',
          'at': at.toIso8601String(),
        });
        final prev = adminPreviewLine(l, {
          'k': 'salesTotalPrev',
          'amt': amount,
          'day': '2026-10-28',
          'at': at.toIso8601String(),
        });
        expect(salesTotal, l.salesTitle);
        expect(prev, isNot(contains(amount)));
        expect(prev, isNotEmpty);
        expect(adminPreviewLine(l, {'k': 'salesFailed'}), l.salesFail);
        expect(adminPreviewLine(l, {'k': 'salesIsOff'}), l.salesOff);
      },
    );
  }
}
