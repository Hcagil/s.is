import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/presentation/admin_answer_status.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Helper to build the widget under test inside a MaterialApp with the
/// required providers and theme.
Future<void> _pump(
  WidgetTester tester,
  AdminAnswer answer,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AdminAnswerStatusLine(answer: answer)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Builds an [AdminAnswer] with the given status and optional code.
AdminAnswer ans(
  AdminAnswerStatus status, {
  AdminAnswerCode? code,
  String kind = 'talk',
  String? conv = 'c:1',
}) {
  final message = <String, Object?>{
    'answer_id': 'a1',
    'kind': kind,
    'text': 'hello',
  };
  if (conv != null) message['conv'] = conv;
  return AdminAnswer(
    epoch: 1,
    upSeq: 1,
    message: message,
    sentAt: DateTime(2026),
    status: status,
    code: code,
  );
}

void main() {
  group('AdminAnswerStatusLine', () {
    late ProviderContainer container;
    late FakeAdminRepository repo;

    setUp(() {
      repo = FakeAdminRepository();
      container = ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(repo),
          adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
          adminSnapshotStoreProvider.overrideWithValue(
            FakeAdminSnapshotStore(),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    testWidgets('sending shows sending text, no buttons', (tester) async {
      final a = ans(AdminAnswerStatus.sending);
      await _pump(tester, a, container);
      final l = AppLocalizations.of(
        tester.element(find.byType(AdminAnswerStatusLine)),
      );
      expect(find.text(l.adminAnswerSending), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-answer-retry')), findsNothing);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);
    });

    testWidgets('sent hides the whole line', (tester) async {
      final a = ans(AdminAnswerStatus.sent);
      await _pump(tester, a, container);
      expect(find.byKey(const ValueKey('admin-answer-status')), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('notSentYet shows not sent yet text and retry', (tester) async {
      final a = ans(AdminAnswerStatus.notSentYet);
      await _pump(tester, a, container);
      final l = AppLocalizations.of(
        tester.element(find.byType(AdminAnswerStatusLine)),
      );
      expect(find.text(l.adminAnswerNotSentYet), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-answer-retry')), findsOneWidget);
      expect(find.text(l.adminAnswerRetry), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);
    });

    testWidgets('notSent + notOpen shows not sent, reason, retry', (
      tester,
    ) async {
      final a = ans(AdminAnswerStatus.notSent, code: AdminAnswerCode.notOpen);
      await _pump(tester, a, container);
      final l = AppLocalizations.of(
        tester.element(find.byType(AdminAnswerStatusLine)),
      );
      expect(find.text(l.adminAnswerNotSent), findsOneWidget);
      expect(find.text(l.adminReasonNotOpen), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-answer-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);
    });

    testWidgets('reasons show correct text', (tester) async {
      for (final code in AdminAnswerCode.values) {
        await _pump(
          tester,
          ans(AdminAnswerStatus.notSent, code: code),
          container,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(AdminAnswerStatusLine)),
        );
        final expected = switch (code) {
          AdminAnswerCode.deskOnly => l.adminReasonDeskOnly,
          AdminAnswerCode.unknownItem => l.adminReasonUnknownItem,
          AdminAnswerCode.convMissing => l.adminReasonConvMissing,
          AdminAnswerCode.notOpen => l.adminReasonNotOpen,
          AdminAnswerCode.badConv ||
          AdminAnswerCode.badRequest => l.adminReasonGeneric,
        };
        expect(find.text(expected), findsOneWidget);
      }
    });

    testWidgets('new-conv button visibility', (tester) async {
      // talk + convMissing + conv set
      var a = ans(AdminAnswerStatus.notSent, code: AdminAnswerCode.convMissing);
      await _pump(tester, a, container);
      expect(
        find.byKey(const ValueKey('admin-answer-new-conv')),
        findsOneWidget,
      );

      // question + convMissing (conv null)
      a = ans(
        AdminAnswerStatus.notSent,
        code: AdminAnswerCode.convMissing,
        kind: 'question',
        conv: null,
      );
      await _pump(tester, a, container);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);

      // question + convMissing (conv set)
      a = ans(
        AdminAnswerStatus.notSent,
        code: AdminAnswerCode.convMissing,
        kind: 'question',
        conv: 'c:1',
      );
      await _pump(tester, a, container);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);

      // talk + convMissing but conv null
      a = ans(
        AdminAnswerStatus.notSent,
        code: AdminAnswerCode.convMissing,
        conv: null,
      );
      await _pump(tester, a, container);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);

      // talk + notOpen
      a = ans(AdminAnswerStatus.notSent, code: AdminAnswerCode.notOpen);
      await _pump(tester, a, container);
      expect(find.byKey(const ValueKey('admin-answer-new-conv')), findsNothing);
    });

    testWidgets('tapping retry sends the message', (tester) async {
      final a = ans(AdminAnswerStatus.notSent, code: AdminAnswerCode.notOpen);
      container.listen(adminPanelsProvider, (_, _) {});
      await _pump(tester, a, container);
      await tester.tap(find.byKey(const ValueKey('admin-answer-retry')));
      await tester.pump();
      final sent = repo.sent.where((m) => m['kind'] == 'talk').toList();
      expect(sent.length, 1);
      expect(sent.first['text'], 'hello');
      expect(sent.first['conv'], 'c:1');
    });

    testWidgets('tapping new-conv sends without conv', (tester) async {
      final a = ans(
        AdminAnswerStatus.notSent,
        code: AdminAnswerCode.convMissing,
      );
      container.listen(adminPanelsProvider, (_, _) {});
      await _pump(tester, a, container);
      await tester.tap(find.byKey(const ValueKey('admin-answer-new-conv')));
      await tester.pump();
      final sent = repo.sent.where((m) => m['kind'] == 'talk').toList();
      expect(sent.length, 1);
      expect(sent.first['text'], 'hello');
      expect(sent.first.containsKey('conv'), false);
    });
  });
}
