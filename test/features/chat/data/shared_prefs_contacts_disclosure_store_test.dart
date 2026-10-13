// SharedPrefsContactsDisclosureStore against shared_preferences' own
// in-memory test store: not accepted on a fresh phone; accepted after
// accept(), also for a new instance (the next app start).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/shared_prefs_contacts_disclosure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fresh phone has not accepted the disclosure', () async {
    SharedPreferences.setMockInitialValues({});
    expect(
      await const SharedPrefsContactsDisclosureStore().accepted(),
      isFalse,
    );
  });

  test('accept is remembered across app starts', () async {
    SharedPreferences.setMockInitialValues({});
    await const SharedPrefsContactsDisclosureStore().accept();
    expect(await const SharedPrefsContactsDisclosureStore().accepted(), isTrue);
  });
}
