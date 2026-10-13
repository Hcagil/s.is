import 'dart:developer';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/phone_book.dart';

/// [ContactsDisclosureStore] over shared_preferences.
final class SharedPrefsContactsDisclosureStore
    implements ContactsDisclosureStore {
  /// Creates the store.
  const SharedPrefsContactsDisclosureStore([this._userId]);

  final String? Function()? _userId;

  String get _key => 'sis.contacts.disclosure.${_userId?.call() ?? ''}';

  // A signed-in check that finds no user must not share a flag across accounts.
  bool get _noUser => _userId != null && (_userId.call() ?? '').isEmpty;

  @override
  Future<bool> accepted() async {
    if (_noUser) return false;
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
    if (_noUser) return;
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
