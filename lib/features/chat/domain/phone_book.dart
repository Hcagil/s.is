import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'message.dart';
import 'shared_contact.dart';

/// What access the member granted to the phone book.
enum PhoneBookAccess {
  /// The member allowed reading contacts, including iOS limited access.
  granted,

  /// The member refused; asking again shows the system prompt.
  denied,

  /// The member denied access on an earlier ask too: the system will not
  /// prompt again, so the only way forward is the app's settings page.
  permanentlyDenied,
}

/// One contact on the phone, by the platform's id; its details are fetched on
/// demand.
final class PhoneBookEntry {
  const PhoneBookEntry({
    required this.id,
    required this.name,
    required this.phone,
  });

  final String id;
  final String name;
  final String phone;
}

/// One contact on the phone with the email addresses it holds; for Find
/// people. Never stored, never logged.
final class PhoneBookPerson {
  const PhoneBookPerson({
    required this.id,
    required this.name,
    required this.emails,
  });

  final String id;
  final String name;
  final List<String> emails;
}

/// SHA-256 hex of the trimmed, lower-cased [email] as UTF-8: the only form
/// of a contact's address that leaves the phone. No dot or plus folding.
String hashContactEmail(String email) =>
    sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

/// Whether this member accepted the "Find people from your contacts"
/// disclosure on this phone, kept locally.
abstract interface class ContactsDisclosureStore {
  Future<bool> accepted();

  Future<void> accept();
}

/// The phone's own contacts, for the Send a contact picker.
///
/// Its own boundary because reading contacts is a platform capability that
/// needs the member's permission.
abstract interface class PhoneBook {
  /// Asks for permission the first time; afterwards answers without asking
  /// again.
  Future<PhoneBookAccess> requestAccess();

  /// Contacts that have a phone number, sorted by name, one entry per contact;
  /// empty without access.
  Future<List<PhoneBookEntry>> entries();

  /// Every contact with its email addresses (may be empty), sorted by name;
  /// empty without access.
  Future<List<PhoneBookPerson>> people();

  /// Opens this app's page in the phone's settings, for when access is
  /// [PhoneBookAccess.permanentlyDenied] and no prompt will be shown again.
  Future<void> openSettings();

  /// Opens the phone's own add-contact screen prefilled with the name and
  /// number; the member saves or cancels there; no permission needed.
  Future<void> addToPhone(SharedContact contact);
}

/// Filter [all] contacts by [query], case-insensitively matching names and
/// phone numbers (digits only).
List<PhoneBookEntry> filterPhoneBook(List<PhoneBookEntry> all, String query) {
  final q = query.trim();
  if (q.isEmpty) return all;

  String digitsOf(String s) => s.replaceAll(RegExp(r'\D'), '');
  final qDigits = digitsOf(q);
  final qContainsDigits = qDigits.isNotEmpty;

  return all.where((e) {
    final nameMatch = foldSearch(e.name).contains(foldSearch(q));
    if (nameMatch) return true;
    if (!qContainsDigits) return false;
    return digitsOf(e.phone).contains(qDigits);
  }).toList();
}
