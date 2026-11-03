// showMessageDeleteBox: count > 1 asks about "these messages", count 1 about
// "this message" (EN and TR). Written from the QA interface (t_a90e191cb2).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/presentation/message_delete_box.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/l10n.dart';

Future<void> _open(WidgetTester t, Locale locale, int? count) async {
  await t.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => count == null
              ? showMessageDeleteBox(context)
              : showMessageDeleteBox(context, count: count),
          child: const Text('go'),
        ),
      ),
    ),
  );
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  expect(find.byKey(const ValueKey('delete-card')), findsOneWidget);
}

void main() {
  test('the strings', () {
    expect(
      l10nEn.messageDeleteFewQuestion,
      'Are you sure you want to delete these messages?',
    );
    expect(
      l10nTr.messageDeleteFewQuestion,
      'Bu mesajları silmek istediğinizden emin misiniz?',
    );
  });

  for (final (locale, few, one) in [
    (
      const Locale('en'),
      'Are you sure you want to delete these messages?',
      l10nEn.messageDeleteQuestion,
    ),
    (
      const Locale('tr'),
      'Bu mesajları silmek istediğinizden emin misiniz?',
      l10nTr.messageDeleteQuestion,
    ),
  ]) {
    for (final n in [2, 3, 10]) {
      testWidgets('${locale.languageCode}: count $n -> few', (t) async {
        await _open(t, locale, n);
        expect(find.text(few), findsOneWidget);
        expect(find.text(one), findsNothing);
      });
    }
    for (final n in [null, 1]) {
      testWidgets('${locale.languageCode}: count ${n ?? "default"} -> single', (
        t,
      ) async {
        await _open(t, locale, n);
        expect(find.text(one), findsOneWidget);
        expect(find.text(few), findsNothing);
      });
    }
  }
}
