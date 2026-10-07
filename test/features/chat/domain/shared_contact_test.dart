// SharedContact (clean, body, isSendable, tryParse, preview) and
// filterPhoneBook, written from the contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';

void main() {
  group('SharedContact', () {
    test('body is name + newline + phone', () {
      const contact = SharedContact(
        name: 'Ann Lee',
        phone: '+90 555 123 45 67',
      );
      expect(contact.body, equals('Ann Lee\n+90 555 123 45 67'));
    });

    test('cleanContactText collapses whitespace and control chars', () {
      expect(cleanContactText('  Ann \t\n  Lee \u0007 '), equals('Ann Lee'));
      expect(cleanContactText(''), equals(''));
    });

    test('SharedContact.clean trims and collapses whitespace', () {
      final cleaned = SharedContact.clean('  Ann\nLee ', ' +90\t555 ');
      expect(cleaned.name, equals('Ann Lee'));
      expect(cleaned.phone, equals('+90 555'));
      expect(cleaned.body, equals('Ann Lee\n+90 555'));
    });

    test('clean truncates name to 80 runes', () {
      final longName = 'é' * 100;
      final cleaned = SharedContact.clean(longName, '123');
      expect(cleaned.name.runes.length, equals(80));
    });

    test('isSendable checks name and phone constraints', () {
      const valid = SharedContact(name: 'Ann', phone: '123');
      const emptyName = SharedContact(name: '', phone: '123');
      const shortPhone = SharedContact(name: 'Ann', phone: '12');
      const exactMinPhone = SharedContact(name: 'Ann', phone: '123');
      final exactMaxPhone = SharedContact(name: 'Ann', phone: '1' * 32);
      final overMaxPhone = SharedContact(name: 'Ann', phone: '1' * 33);
      final maxName = SharedContact(name: 'é' * 80, phone: '123');
      final overMaxName = SharedContact(name: 'é' * 81, phone: '123');
      const nameWithControl = SharedContact(name: 'Ann\u0007', phone: '123');
      const phoneWithControl = SharedContact(name: 'Ann', phone: '123\n');

      expect(valid.isSendable, isTrue);
      expect(emptyName.isSendable, isFalse);
      expect(shortPhone.isSendable, isFalse);
      expect(exactMinPhone.isSendable, isTrue);
      expect(exactMaxPhone.isSendable, isTrue);
      expect(overMaxPhone.isSendable, isFalse);
      expect(maxName.isSendable, isTrue);
      expect(overMaxName.isSendable, isFalse);
      expect(nameWithControl.isSendable, isFalse);
      expect(phoneWithControl.isSendable, isFalse);
    });

    test('tryParse round trip', () {
      const original = SharedContact(name: 'Ann Lee', phone: '+90 555');
      final parsed = SharedContact.tryParse(original.body);
      expect(parsed, isNotNull);
      expect(parsed!.name, equals(original.name));
      expect(parsed.phone, equals(original.phone));
    });

    test('tryParse returns null for invalid bodies', () {
      expect(SharedContact.tryParse('just text'), isNull);
      expect(SharedContact.tryParse(''), isNull);
      expect(SharedContact.tryParse('\n123'), isNull);
      expect(SharedContact.tryParse('Ann\n'), isNull);
    });

    test('contactPreview formats preview line', () {
      const body = 'Ann Lee\n+90 555';
      final preview = contactPreview(body);
      expect(preview, equals('\u{1F464} Contact: Ann Lee'));
      expect(preview.startsWith(contactPreviewPrefix), isTrue);
    });
  });

  group('PhoneBook', () {
    const a = PhoneBookEntry(
      id: '1',
      name: 'Ann Lee',
      phone: '+90 555 111 2233',
    );
    const b = PhoneBookEntry(
      id: '2',
      name: 'Bob Stone',
      phone: '0212 444 5566',
    );
    const c = PhoneBookEntry(id: '3', name: 'annette', phone: '999');
    final all = [a, b, c];

    test('filterPhoneBook returns all for empty query', () {
      final result = filterPhoneBook(all, '');
      expect(result.map((e) => e.id).toList(), equals(['1', '2', '3']));
    });

    test('filterPhoneBook matches name substring case-insensitively', () {
      final result = filterPhoneBook(all, 'ann');
      expect(result.map((e) => e.id).toList(), equals(['1', '3']));
    });

    test('filterPhoneBook matches exact name part', () {
      final result = filterPhoneBook(all, 'LEE');
      expect(result.map((e) => e.id).toList(), equals(['1']));
    });

    test('filterPhoneBook matches digits only in phone', () {
      final result = filterPhoneBook(all, '5551112');
      expect(result.map((e) => e.id).toList(), equals(['1']));
    });

    test('filterPhoneBook ignores separators in query', () {
      final result = filterPhoneBook(all, '444-55');
      expect(result.map((e) => e.id).toList(), equals(['2']));
    });

    test('filterPhoneBook does not match query with no digits', () {
      final result = filterPhoneBook(all, 'zzz');
      expect(result.map((e) => e.id).toList(), equals([]));
    });

    test('filterPhoneBook preserves input order', () {
      final result = filterPhoneBook(all, 'ann');
      expect(result.map((e) => e.id).toList(), equals(['1', '3']));
    });
  });
}
