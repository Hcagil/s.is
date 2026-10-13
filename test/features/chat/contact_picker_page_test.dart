// The Send a contact picker through showContactPicker, written from the
// contract: permission asked on open, search by name or number, empty and
// no-match texts, single pick, Allow access / Open settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';
import 'package:sis/features/chat/presentation/contact_picker_page.dart';

import '../../support/chat_launcher.dart';
import '../../support/contact_fakes.dart';

Finder k(String key) => find.byKey(ValueKey(key));
const ann = PhoneBookEntry(id: 'a', name: 'Ann Lee', phone: '+90 555 111 2233');
const bob = PhoneBookEntry(id: 'b', name: 'Bob Stone', phone: '0212 444 5566');

Future<List<SharedContact?>> open(
  WidgetTester t,
  FakePhoneBook book, {
  Locale? locale,
}) async {
  final picked = <SharedContact?>[];
  await pumpLauncher(
    t,
    (context, ref) async {
      picked.add(await showContactPicker(context));
    },
    phoneBook: book,
    locale: locale,
  );
  await t.pumpAndSettle();
  return picked;
}

void main() {
  group('ContactPickerPage', () {
    testWidgets('opens and lists both contacts by name', (
      WidgetTester t,
    ) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await open(t, book);
      expect(k('contact-picker-page'), findsOneWidget);
      expect(k('contact-a'), findsOneWidget);
      expect(k('contact-b'), findsOneWidget);
      expect(find.text('Ann Lee'), findsOneWidget);
    });

    testWidgets('permission is asked once when the list opens', (
      WidgetTester t,
    ) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await pumpLauncher(
        t,
        (context, ref) => showContactPicker(context),
        phoneBook: book,
        tap: false,
      );
      expect(book.accessCalls, 0);
      await t.tap(find.byKey(const ValueKey('launch')));
      await t.pumpAndSettle();
      expect(book.accessCalls, 1);
    });

    testWidgets('search by name', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await open(t, book);
      await t.enterText(k('contact-search'), 'bob');
      await t.pumpAndSettle();
      expect(k('contact-b'), findsOneWidget);
      expect(k('contact-a'), findsNothing);
    });

    testWidgets('search by number digits', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await open(t, book);
      await t.enterText(k('contact-search'), '5551112');
      await t.pumpAndSettle();
      expect(k('contact-a'), findsOneWidget);
      expect(k('contact-b'), findsNothing);
    });

    testWidgets('no match shows message and no rows', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await open(t, book);
      await t.enterText(k('contact-search'), 'zzz');
      await t.pumpAndSettle();
      expect(find.text('No contact matches your search'), findsOneWidget);
      expect(k('contact-a'), findsNothing);
      expect(k('contact-b'), findsNothing);
    });

    testWidgets('empty phone book shows empty list message', (
      WidgetTester t,
    ) async {
      final book = FakePhoneBook(contacts: []);
      await open(t, book);
      expect(find.text('No contacts with a phone number'), findsOneWidget);
    });

    testWidgets('Send without a pick does not pop', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      await pumpLauncher(t, (context, ref) async {
        await showContactPicker(context);
      }, phoneBook: book);
      await t.pumpAndSettle();
      await t.tap(k('contact-send'));
      await t.pumpAndSettle();
      expect(k('contact-picker-page'), findsOneWidget);
    });

    testWidgets('single pick, Send returns it', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      final picked = <SharedContact?>[];
      await pumpLauncher(t, (context, ref) async {
        picked.add(await showContactPicker(context));
      }, phoneBook: book);
      await t.pumpAndSettle();
      await t.tap(k('contact-a'));
      await t.pumpAndSettle();
      await t.tap(k('contact-b'));
      await t.pumpAndSettle();
      await t.tap(k('contact-send'));
      await t.pumpAndSettle();
      expect(k('contact-picker-page'), findsNothing);
      expect(picked.length, 1);
      expect(picked.first?.name, 'Bob Stone');
      expect(picked.first?.phone, '0212 444 5566');
    });

    testWidgets('backing out returns null', (WidgetTester t) async {
      final book = FakePhoneBook(contacts: [ann, bob]);
      final picked = <SharedContact?>[];
      await pumpLauncher(t, (context, ref) async {
        picked.add(await showContactPicker(context));
      }, phoneBook: book);
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(picked, [null]);
    });

    testWidgets('denied (not permanent) shows Allow access button', (
      WidgetTester t,
    ) async {
      final book = FakePhoneBook(
        access: PhoneBookAccess.denied,
        contacts: [ann, bob],
      );
      await open(t, book);
      expect(
        find.descendant(
          of: k('contact-allow'),
          matching: find.text('Allow access'),
        ),
        findsOneWidget,
      );
      expect(k('contact-a'), findsNothing);
      expect(k('contact-b'), findsNothing);
      book.access = PhoneBookAccess.granted;
      await t.tap(k('contact-allow'));
      await t.pumpAndSettle();
      expect(k('contact-a'), findsOneWidget);
      expect(k('contact-b'), findsOneWidget);
      expect(book.accessCalls, 2);
      expect(book.settingsCalls, 0);
    });

    testWidgets('permanently denied shows Open settings button', (
      WidgetTester t,
    ) async {
      final book = FakePhoneBook(
        access: PhoneBookAccess.permanentlyDenied,
        contacts: [ann, bob],
      );
      await open(t, book);
      expect(
        find.descendant(
          of: k('contact-allow'),
          matching: find.text('Open settings'),
        ),
        findsOneWidget,
      );
      await t.tap(k('contact-allow'));
      await t.pumpAndSettle();
      expect(book.settingsCalls, 1);
    });

    testWidgets('Turkish locale shows translated texts', (
      WidgetTester t,
    ) async {
      final bookDenied = FakePhoneBook(
        access: PhoneBookAccess.denied,
        contacts: [ann, bob],
      );
      await open(t, bookDenied, locale: const Locale('tr'));
      expect(
        find.descendant(
          of: k('contact-allow'),
          matching: find.text('Erişime izin ver'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Turkish empty list text', (WidgetTester t) async {
      final bookEmpty = FakePhoneBook(contacts: []);
      await open(t, bookEmpty, locale: const Locale('tr'));
      expect(find.text('Telefon numarası olan kişi yok'), findsOneWidget);
    });
  });
}
