// The two generic server-text replies, wired as main.dart wires
// AdminReplyBubble (adminChatRepositoryProvider; adminAnswerProvider left to
// read the repository). 'card': the server's text plus Confirm and Cancel,
// each answering this card through the repository. 'note': the server's text
// only. The server writes the text both as the message body and as
// admin_msg 't'; the fake repository records answers and replies Ok, a
// refusal, or late.
import 'dart:async';

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
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async =>
      const Allowed(Member(userId: 'u1', displayName: 'Maya'));
}

class RecordingRepo implements AdminChatRepository {
  RecordingRepo([this.reply = const Ok(null)]);
  final calls = <(String, bool)>[];
  final Result<void> reply;
  Completer<Result<void>>? gate;
  @override
  Future<Result<void>> answer(String cardId, bool yes) async {
    calls.add((cardId, yes));
    if (gate != null) return gate!.future;
    return reply;
  }
}

const bot = '00000000-0000-0000-0000-00000000ad41';
const text = 'Server text for p***@m***.test';

Future<RecordingRepo> pump(
  WidgetTester tester,
  Map<String, dynamic> m, {
  Locale locale = const Locale('en'),
  RecordingRepo? repo,
}) async {
  final r = repo ?? RecordingRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(staff: StaffRegistryFake(stored: neutralRegistry())),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        chatRepositoryProvider.overrideWithValue(
          ChatFake(self: 'u1')
            ..conversationsResult = const Ok([
              Conversation(
                id: 'admin-conv',
                title: 'x',
                isAdminChat: true,
                staffKey: 'staff_b',
              ),
            ]),
        ),
        adminChatRepositoryProvider.overrideWithValue(r),
      ],
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminReplyBubble(
              message: Message(
                id: 'card-9',
                conversationId: 'admin-conv',
                senderId: bot,
                body: text,
                createdAt: DateTime.utc(2026, 11, 6, 9),
                adminMsg: m,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return r;
}

String screenText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
  for (final t in tester.widgetList<RichText>(find.byType(RichText)))
    t.text.toPlainText(),
].join('\n');

Finder buttons() => find.descendant(
  of: find.byType(AdminReplyBubble),
  matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
);

void main() {
  const card = {'k': 'card', 't': text};
  const note = {'k': 'note', 't': text};

  group('card', () {
    for (final (locale, l) in [
      (const Locale('en'), l10nEn),
      (const Locale('tr'), l10nTr),
    ]) {
      testWidgets('${locale.languageCode}: shows the server text and both '
          'buttons', (tester) async {
        await pump(tester, card, locale: locale);
        expect(screenText(tester), contains(text));
        expect(find.text(l.adminCardConfirm), findsOneWidget);
        expect(find.text(l.adminCardCancel), findsOneWidget);
        expect(buttons(), findsNWidgets(2));
      });

      testWidgets('${locale.languageCode}: Confirm answers yes, Cancel no, '
          'for this card', (tester) async {
        final repo = await pump(tester, card, locale: locale);
        await tester.tap(find.text(l.adminCardConfirm));
        await tester.pumpAndSettle();
        expect(repo.calls, [('card-9', true)]);
        final repo2 = await pump(tester, card, locale: locale);
        await tester.tap(find.text(l.adminCardCancel));
        await tester.pumpAndSettle();
        expect(repo2.calls, [('card-9', false)]);
      });
    }

    testWidgets('the card is not the tester-removal card', (tester) async {
      await pump(tester, card);
      final s = screenText(tester);
      expect(s, isNot(contains(l10nEn.adminConfTitle)));
      expect(find.text(l10nEn.adminConfYes), findsNothing);
    });

    testWidgets('a refused answer does not throw', (tester) async {
      final repo = await pump(
        tester,
        card,
        repo: RecordingRepo(const Err(DeniedFailure())),
      );
      await tester.tap(find.text(l10nEn.adminCardConfirm));
      await tester.pumpAndSettle();
      expect(repo.calls, [('card-9', true)]);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('a late answer: sent at once, the text stays up', (
      tester,
    ) async {
      final slow = RecordingRepo()..gate = Completer<Result<void>>();
      await pump(tester, card, repo: slow);
      await tester.tap(find.text(l10nEn.adminCardConfirm));
      await tester.pump();
      expect(slow.calls, [('card-9', true)]);
      expect(screenText(tester), contains(text));
      slow.gate!.complete(const Ok(null));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('note', () {
    for (final locale in [const Locale('en'), const Locale('tr')]) {
      testWidgets('${locale.languageCode}: shows the server text, no buttons, '
          'no help', (tester) async {
        final repo = await pump(tester, note, locale: locale);
        expect(screenText(tester), contains(text));
        expect(buttons(), findsNothing);
        expect(
          screenText(tester),
          isNot(
            contains(
              (locale.languageCode == 'tr' ? l10nTr : l10nEn).adminHelpHeader,
            ),
          ),
        );
        expect(repo.calls, isEmpty);
      });
    }
  });
}
