// AdminReplyBubble: a failed Apple step (k = fail / failRm) names its reason
// code r in words -- timeout, rejected and dispatch map to their own strings
// in English and Turkish; any other code is shown as it came.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/admin_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/text_sharer.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

import '../../support/l10n.dart';

class RecordingSharer implements TextSharer {
  final shared = <String>[];
  @override
  Future<void> share(String text) async => shared.add(text);
}

class RecordingAdminRepo implements AdminChatRepository {
  RecordingAdminRepo([this.reply = const Ok(null)]);
  final calls = <(String, bool)>[];
  Result<void> reply;
  Completer<Result<void>>? gate;
  @override
  Future<Result<void>> answer(String cardId, bool yes) async {
    calls.add((cardId, yes));
    if (gate != null) return gate!.future;
    return reply;
  }
}

const bot = '00000000-0000-0000-0000-00000000ad41';
Message adminMsg(Map<String, dynamic> m, {String id = 'card-1'}) => Message(
  id: id,
  conversationId: 'admin-conv',
  senderId: bot,
  body: '',
  createdAt: DateTime.utc(2026, 10, 13, 9),
  adminMsg: m,
);

Future<(RecordingSharer, RecordingAdminRepo)> pump(
  WidgetTester tester,
  Map<String, dynamic> m, {
  Locale locale = const Locale('en'),
  RecordingAdminRepo? repo,
}) async {
  final sharer = RecordingSharer();
  final r = repo ?? RecordingAdminRepo();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        textSharerProvider.overrideWithValue(sharer),
        adminChatRepositoryProvider.overrideWithValue(r),
      ],
      child: localizedApp(
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminReplyBubble(message: adminMsg(m)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (sharer, r);
}

/// Every Text and RichText on screen joined, so a line can be found whatever
/// widget splits it.
String screenText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    t.data ?? t.textSpan?.toPlainText() ?? '',
  for (final t in tester.widgetList<RichText>(find.byType(RichText)))
    t.text.toPlainText(),
].join('\n');

void main() {
  for (final (locale, l) in [
    (const Locale('en'), l10nEn),
    (const Locale('tr'), l10nTr),
  ]) {
    group('${locale.languageCode}:', () {
      testWidgets('fail and failRm show correct reason text', (tester) async {
        final kinds = ['fail', 'failRm'];
        final reasons = ['timeout', 'rejected', 'dispatch'];
        for (final k in kinds) {
          for (final r in reasons) {
            await pump(tester, {'k': k, 'r': r}, locale: locale);
            final expected = k == 'fail'
                ? l.adminFail(
                    r == 'timeout'
                        ? l.adminReasonTimeout
                        : r == 'rejected'
                        ? l.adminReasonRejected
                        : l.adminReasonDispatch,
                  )
                : l.adminFailRm(
                    r == 'timeout'
                        ? l.adminReasonTimeout
                        : r == 'rejected'
                        ? l.adminReasonRejected
                        : l.adminReasonDispatch,
                  );
            expect(screenText(tester), contains(expected), reason: '$k/$r');
          }
        }
      });

      testWidgets('weird-code shows raw code', (tester) async {
        final kinds = ['fail', 'failRm'];
        for (final k in kinds) {
          await pump(tester, {'k': k, 'r': 'weird-code'}, locale: locale);
          final expected = k == 'fail'
              ? l.adminFail('weird-code')
              : l.adminFailRm('weird-code');
          expect(
            screenText(tester),
            contains(expected),
            reason: '$k/weird-code',
          );
        }
      });

      testWidgets('fail with timeout does not show raw timeout', (
        tester,
      ) async {
        await pump(tester, {'k': 'fail', 'r': 'timeout'}, locale: locale);
        expect(screenText(tester), isNot(contains(l.adminFail('timeout'))));
      });
    });
  }

  test('the reason strings are three different words in each language', () {
    for (final l in [l10nEn, l10nTr]) {
      expect({
        l.adminReasonTimeout,
        l.adminReasonRejected,
        l.adminReasonDispatch,
      }, hasLength(3));
    }
  });
}
