// SharedPrefsContactsDisclosureStore against shared_preferences' own
// in-memory test store: the flag is per signed-in user under
// sis.contacts.disclosure.<uid>; no user (null or empty id) is never
// accepted and stores nothing; acceptance survives an app start.
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
    await SharedPrefsContactsDisclosureStore(() => 'u1').accept();
    expect(
      await SharedPrefsContactsDisclosureStore(() => 'u1').accepted(),
      isTrue,
    );
  });

  test(
    'second account on the same phone has not accepted after first accepted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store1 = SharedPrefsContactsDisclosureStore(() => 'u1');
      await store1.accept();
      expect(await store1.accepted(), isTrue);

      final store2 = SharedPrefsContactsDisclosureStore(() => 'u2');
      expect(await store2.accepted(), isFalse);
      expect(
        await store1.accepted(),
        isTrue,
        reason: 'u1 keeps its acceptance',
      );
    },
  );

  test('callback is read at call time', () async {
    SharedPreferences.setMockInitialValues({});
    var uid = 'u1';
    final store = SharedPrefsContactsDisclosureStore(() => uid);

    await store.accept(); // accepts for u1
    expect(await store.accepted(), isTrue);

    uid = 'u2';
    expect(await store.accepted(), isFalse);

    uid = 'u1';
    expect(await store.accepted(), isTrue);
  });

  test(
    'callback returns null or empty: accepted is false and nothing is stored',
    () async {
      SharedPreferences.setMockInitialValues({});
      final storeNull = SharedPrefsContactsDisclosureStore(() => null);
      expect(await storeNull.accepted(), isFalse);
      await storeNull.accept();
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().isEmpty, isTrue);

      SharedPreferences.setMockInitialValues({});
      final storeEmpty = SharedPrefsContactsDisclosureStore(() => '');
      expect(await storeEmpty.accepted(), isFalse);
      await storeEmpty.accept();
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().isEmpty, isTrue);
    },
  );

  test('pre-set value is read correctly', () async {
    SharedPreferences.setMockInitialValues({
      'sis.contacts.disclosure.u1': true,
    });
    final storeU1 = SharedPrefsContactsDisclosureStore(() => 'u1');
    expect(await storeU1.accepted(), isTrue);

    final storeU2 = SharedPrefsContactsDisclosureStore(() => 'u2');
    expect(await storeU2.accepted(), isFalse);
  });

  test(
    'after accept, a new instance with the same callback reports accepted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store1 = SharedPrefsContactsDisclosureStore(() => 'u1');
      await store1.accept();

      final store2 = SharedPrefsContactsDisclosureStore(() => 'u1');
      expect(await store2.accepted(), isTrue);
    },
  );

  test('stored prefs contain only the expected key', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SharedPrefsContactsDisclosureStore(() => 'u1');
    await store.accept();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().contains('sis.contacts.disclosure.u1'), isTrue);
    expect(prefs.getKeys().length, equals(1));
  });
}
