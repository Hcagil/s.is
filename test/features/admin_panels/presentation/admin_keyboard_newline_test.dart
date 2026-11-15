import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';

import '../application/admin_fakes.dart';

import 'package:sis/features/admin_panels/presentation/admin_question_card.dart';
import 'package:sis/features/admin_panels/domain/admin_models.dart';
import 'package:sis/features/admin_panels/presentation/admin_talk_composer.dart';
import 'package:sis/l10n/app_localizations.dart';

/// Helper to build the widget under test inside a MaterialApp with the
/// required providers and theme.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: ProviderContainer(
        overrides: [
          adminPanelsRepositoryProvider.overrideWithValue(
            FakeAdminRepository(),
          ),
          adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
          adminSnapshotStoreProvider.overrideWithValue(
            FakeAdminSnapshotStore(),
          ),
        ],
      ),
      child: MaterialApp(
        theme: sisTheme(brightness),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Questions answer box', () {
    testWidgets('TextField has newline action and multiline type', (
      tester,
    ) async {
      final controller = TextEditingController();
      await _pump(
        tester,
        AdminQuestionCard(
          question: const AdminQuestion(
            id: 'Q-M-00001',
            text: 'Why?',
            ctx: '',
            kind: 'text',
            recommended: null,
            answers: [],
            waiting: false,
          ),
          waiting: false,
          selected: 0,
          controller: controller,
          onSelected: (_) {},
          onTextChanged: () {},
        ),
      );

      final box = find.byKey(const ValueKey('admin-question-text-Q-M-00001'));
      final textField = tester.widget<TextField>(box);
      expect(textField.textInputAction, TextInputAction.newline);
      expect(textField.keyboardType, TextInputType.multiline);
    });

    testWidgets('Newline action does not send, keeps focus', (tester) async {
      final controller = TextEditingController();
      int changes = 0;
      await _pump(
        tester,
        AdminQuestionCard(
          question: const AdminQuestion(
            id: 'Q-M-00001',
            text: 'Why?',
            ctx: '',
            kind: 'text',
            recommended: null,
            answers: [],
            waiting: false,
          ),
          waiting: false,
          selected: 0,
          controller: controller,
          onSelected: (_) {},
          onTextChanged: () => changes++,
        ),
      );

      final box = find.byKey(const ValueKey('admin-question-text-Q-M-00001'));
      await tester.showKeyboard(box);
      tester.testTextInput.enterText('line one');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();

      expect(controller.text, 'line one');
      expect(changes, 1);

      final editable = find.descendant(
        of: box,
        matching: find.byType(EditableText),
      );
      final focusNode = tester.widget<EditableText>(editable).focusNode;
      expect(FocusManager.instance.primaryFocus, focusNode);
    });
  });

  group('Talk composer', () {
    testWidgets('TextField has newline action and multiline type', (
      tester,
    ) async {
      await _pump(tester, const AdminTalkComposer());

      final input = find.byKey(const ValueKey('admin-talk-input'));
      final textField = tester.widget<TextField>(input);
      expect(textField.textInputAction, TextInputAction.newline);
      expect(textField.keyboardType, TextInputType.multiline);
    });

    testWidgets('Newline action does not send, keeps text', (tester) async {
      final repo = FakeAdminRepository();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ProviderContainer(
            overrides: [
              adminPanelsRepositoryProvider.overrideWithValue(repo),
              adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
              adminSnapshotStoreProvider.overrideWithValue(
                FakeAdminSnapshotStore(),
              ),
            ],
          ),
          child: MaterialApp(
            theme: sisTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: const AdminTalkComposer()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byKey(const ValueKey('admin-talk-input'));
      await tester.showKeyboard(input);
      tester.testTextInput.enterText('hello');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();

      expect(repo.sent.isEmpty, true);
      final textField = tester.widget<TextField>(input);
      expect(textField.controller!.text, 'hello');
    });

    testWidgets('Send button sends the text', (tester) async {
      final repo = FakeAdminRepository();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ProviderContainer(
            overrides: [
              adminPanelsRepositoryProvider.overrideWithValue(repo),
              adminUnlockProvider.overrideWithValue(FakeAdminUnlock()),
              adminSnapshotStoreProvider.overrideWithValue(
                FakeAdminSnapshotStore(),
              ),
            ],
          ),
          child: MaterialApp(
            theme: sisTheme(Brightness.light),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: const AdminTalkComposer()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byKey(const ValueKey('admin-talk-input'));
      final send = find.byKey(const ValueKey('admin-talk-send'));

      await tester.showKeyboard(input);
      tester.testTextInput.enterText('hello');
      await tester.pump();

      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(repo.sent.length, 1);
      expect(repo.sent.first['text'], 'hello');
    });
  });
}
