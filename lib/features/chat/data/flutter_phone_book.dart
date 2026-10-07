import 'dart:developer';

import 'package:flutter_contacts/flutter_contacts.dart';

import '../domain/phone_book.dart';
import '../domain/shared_contact.dart';

/// The phone's contacts through flutter_contacts. Thin on purpose
/// (ARCHITECTURE rule 4): verified on a device.
final class FlutterPhoneBook implements PhoneBook {
  const FlutterPhoneBook();

  @override
  Future<PhoneBookAccess> requestAccess() async {
    final s = await FlutterContacts.permissions.request(PermissionType.read);
    return switch (s) {
      PermissionStatus.granted ||
      PermissionStatus.limited => PhoneBookAccess.granted,
      PermissionStatus.permanentlyDenied ||
      PermissionStatus.restricted => PhoneBookAccess.permanentlyDenied,
      _ => PhoneBookAccess.denied,
    };
  }

  @override
  Future<List<PhoneBookEntry>> entries() async {
    try {
      final contacts = await FlutterContacts.getAll(
        properties: {ContactProperty.name, ContactProperty.phone},
      );
      final List<PhoneBookEntry> result = [];
      for (final c in contacts) {
        if (c.id == null || c.displayName == null || c.phones.isEmpty) continue;
        final displayName = c.displayName!.trim();
        if (displayName.isEmpty) continue;
        final usable = [
          for (final p in c.phones)
            if (p.number.trim().isNotEmpty) p,
        ];
        if (usable.isEmpty) continue;
        final shared = usable.firstWhere(
          (p) => p.isPrimary == true,
          orElse: () => usable.first,
        );
        final number = shared.number.trim();
        result.add(PhoneBookEntry(id: c.id!, name: displayName, phone: number));
      }
      result.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return result;
    } on Object catch (e) {
      log('contacts entries: $e', name: 'sis.data');
      return const [];
    }
  }

  @override
  Future<void> openSettings() => FlutterContacts.permissions.openSettings();

  @override
  Future<void> addToPhone(SharedContact contact) async {
    try {
      await FlutterContacts.native.showCreator(
        contact: Contact(
          name: Name(first: contact.name),
          phones: [Phone(number: contact.phone)],
        ),
      );
    } on Object catch (e) {
      log('contacts add: $e', name: 'sis.data');
    }
  }
}
