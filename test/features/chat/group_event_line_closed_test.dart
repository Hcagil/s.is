// GroupEventLine for the closed kind: "X closed the group", in English and
// Turkish, with "Someone" when the name is not in the roster.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/presentation/group_event_line.dart';
import 'package:sis/l10n/app_localizations.dart';

Future<void> show(
  WidgetTester t,
  Map<String, String> names, {
  Locale locale = const Locale('en'),
}) => t.pumpWidget(
  MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: GroupEventLine(
        GroupEvent(
          id: 'e1',
          conversationId: 'g1',
          kind: GroupEventKind.closed,
          subjectId: 'u9',
          actorId: 'u9',
          createdAt: DateTime.utc(2026, 11, 1),
        ),
        names: names,
      ),
    ),
  ),
);

void main() {
  testWidgets('names the admin who closed the group', (t) async {
    await show(t, {'u9': 'Ada'});
    expect(find.text('Ada closed the group'), findsOneWidget);
  });

  testWidgets('an unknown closer reads "Someone"', (t) async {
    await show(t, {});
    expect(find.text('Someone closed the group'), findsOneWidget);
  });

  testWidgets('Turkish line', (t) async {
    await show(t, {'u9': 'Ada'}, locale: const Locale('tr'));
    expect(find.text('Ada grubu kapattı'), findsOneWidget);
  });
}
