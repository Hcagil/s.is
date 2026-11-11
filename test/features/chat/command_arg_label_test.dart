// This file tests StaffCommand argument flags, CommandRow UI rendering
// for tag/email arguments in both locales, and adminReplyText output.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/staff_registry.dart';
import 'package:sis/features/chat/presentation/command_list_row.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';

import '../../support/l10n.dart';

void main() {
  group('StaffCommand argument flags', () {
    test('takesTag and takesEmail flags', () {
      final tagCmd = StaffCommand('/tag', '', arg: 'tag');
      final emailCmd = StaffCommand('/email', '', arg: 'email');
      final emptyCmd = StaffCommand('/empty', '', arg: '');
      final xyzCmd = StaffCommand('/xyz', '', arg: 'xyz');

      expect(tagCmd.takesTag, isTrue);
      expect(tagCmd.takesEmail, isFalse);

      expect(emailCmd.takesEmail, isTrue);
      expect(emailCmd.takesTag, isFalse);

      expect(emptyCmd.takesTag, isFalse);
      expect(emptyCmd.takesEmail, isFalse);

      expect(xyzCmd.takesTag, isFalse);
      expect(xyzCmd.takesEmail, isFalse);
    });
  });

  group('CommandRow UI rendering', () {
    final locales = [Locale('en'), Locale('tr')];

    for (final locale in locales) {
      final l = locale.languageCode == 'en' ? l10nEn : l10nTr;
      group('locale ${locale.languageCode}', () {
        testWidgets('arg tag shows tag label only', (tester) async {
          final cmd = StaffCommand('/cmd', '', arg: 'tag');
          await tester.pumpWidget(
            localizedApp(
              locale: locale,
              home: Scaffold(
                body: CommandRow(command: cmd, onTap: () {}),
              ),
            ),
          );
          expect(
            find.textContaining(l.cmdArgTag, findRichText: true),
            findsOneWidget,
          );
          expect(
            find.textContaining(l.cmdArgEmail, findRichText: true),
            findsNothing,
          );
        });

        testWidgets('arg email shows email label only', (tester) async {
          final cmd = StaffCommand('/cmd', '', arg: 'email');
          await tester.pumpWidget(
            localizedApp(
              locale: locale,
              home: Scaffold(
                body: CommandRow(command: cmd, onTap: () {}),
              ),
            ),
          );
          expect(
            find.textContaining(l.cmdArgEmail, findRichText: true),
            findsOneWidget,
          );
          expect(
            find.textContaining(l.cmdArgTag, findRichText: true),
            findsNothing,
          );
        });

        testWidgets('arg empty shows no label', (tester) async {
          final cmd = StaffCommand('/cmd', '', arg: '');
          await tester.pumpWidget(
            localizedApp(
              locale: locale,
              home: Scaffold(
                body: CommandRow(command: cmd, onTap: () {}),
              ),
            ),
          );
          expect(
            find.textContaining(l.cmdArgTag, findRichText: true),
            findsNothing,
          );
          expect(
            find.textContaining(l.cmdArgEmail, findRichText: true),
            findsNothing,
          );
        });

        testWidgets('arg xyz shows no label', (tester) async {
          final cmd = StaffCommand('/cmd', '', arg: 'xyz');
          await tester.pumpWidget(
            localizedApp(
              locale: locale,
              home: Scaffold(
                body: CommandRow(command: cmd, onTap: () {}),
              ),
            ),
          );
          expect(
            find.textContaining(l.cmdArgTag, findRichText: true),
            findsNothing,
          );
          expect(
            find.textContaining(l.cmdArgEmail, findRichText: true),
            findsNothing,
          );
        });
      });
    }
  });

  group('adminReplyText output', () {
    final commands = [
      StaffCommand(
        '/addperson',
        '',
        arg: 'tag',
        helpEn: 'Add a person',
        helpTr: 'Kişi ekle',
      ),
      StaffCommand(
        '/addphone',
        '',
        arg: 'email',
        helpEn: 'Add a phone',
        helpTr: 'Telefon ekle',
      ),
      StaffCommand('/show', '', helpEn: 'Show all', helpTr: 'Hepsini göster'),
      StaffCommand('/odd', '', arg: 'xyz', helpEn: 'Odd one', helpTr: 'Garip'),
    ];

    final langs = [('en', l10nEn), ('tr', l10nTr)];

    for (final (lang, l) in langs) {
      test('adminReplyText for $lang', () {
        final text = adminReplyText(
          l,
          {'k': 'unk', 'help': true},
          commands: commands,
          lang: lang,
        )!;
        // /addperson
        expect(text.contains('/addperson ${l.cmdArgTag}'), isTrue);
        expect(text.contains('/addperson ${l.cmdArgEmail}'), isFalse);
        // /addphone
        expect(text.contains('/addphone ${l.cmdArgEmail}'), isTrue);
        expect(text.contains('/addphone ${l.cmdArgTag}'), isFalse);
        // /show and /odd no labels
        expect(text.contains('/show ${l.cmdArgTag}'), isFalse);
        expect(text.contains('/show ${l.cmdArgEmail}'), isFalse);
        expect(text.contains('/odd ${l.cmdArgTag}'), isFalse);
        expect(text.contains('/odd ${l.cmdArgEmail}'), isFalse);
        // command names present
        expect(text.contains('/show'), isTrue);
        expect(text.contains('/odd'), isTrue);
        // help text in correct language
        if (lang == 'en') {
          expect(text.contains('Add a person'), isTrue);
          expect(text.contains('Add a phone'), isTrue);
          expect(text.contains('Show all'), isTrue);
          expect(text.contains('Odd one'), isTrue);
        } else {
          expect(text.contains('Kişi ekle'), isTrue);
          expect(text.contains('Telefon ekle'), isTrue);
          expect(text.contains('Hepsini göster'), isTrue);
          expect(text.contains('Garip'), isTrue);
        }
      });
    }
  });
}
