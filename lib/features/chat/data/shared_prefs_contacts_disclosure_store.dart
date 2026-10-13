import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/phone_book.dart';

/// [ContactsDisclosureStore] over shared_preferences.
final class SharedPrefsContactsDisclosureStore
    implements ContactsDisclosureStore {
  /// Creates the store.
  const SharedPrefsContactsDisclosureStore();

  static const _key = 'sis.contacts.disclosure';

  @override
  Future<bool> accepted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (e) {
      log(
        'Loading contacts disclosure failed: ${e.runtimeType}',
        name: 'sis.contacts',
      );
      return false;
    }
  }

  @override
  Future<void> accept() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (e) {
      log(
        'Accepting contacts disclosure failed: ${e.runtimeType}',
        name: 'sis.contacts',
      );
    }
  }
}
