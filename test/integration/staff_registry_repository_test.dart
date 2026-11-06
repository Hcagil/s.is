@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_staff_registry_repository.dart';
import 'package:sis/features/chat/domain/staff_registry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [SupabaseStaffRegistryRepository] against the real local stack: the real
/// staff_registry RPC (row-level answer per caller) and the stored copy the
/// first frame reads.
///
/// The member is a command admin, which no client can make: the runner
/// applies test/integration/fixtures/staff_registry.sql first (tool/ci_local.sh
/// `integration`, ci.yml "Repository integration tests"). It loads one
/// neutral staff_b command, /sales -> sales_total.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _seedPw = 'integration-password';
const _prefix = 'sis.staff.registry.';

Future<SupabaseClient> _signIn(String email) async {
  final c = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await c.auth.signInWithPassword(email: email, password: _seedPw);
  expect(await c.rpc('activate_session'), isTrue, reason: email);
  return c;
}

void main() {
  late SupabaseClient member;
  late SupabaseClient outsider;

  setUpAll(() async {
    member = await _signIn('staffreg-member@sis.test');
    outsider = await _signIn('staffreg-outsider@sis.test');
  });

  tearDownAll(() async {
    await member.dispose();
    await outsider.dispose();
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a member gets the rows of their own staff chat', () async {
    final r = await SupabaseStaffRegistryRepository(member).refresh();
    expect(r, isA<Ok<StaffRegistry>>(), reason: '$r');
    final reg = (r as Ok<StaffRegistry>).value;
    expect(reg.chats.keys, ['staff_b']);
    expect(reg.titleFor('staff_b', 'en'), 'Staff B');
    expect(reg.titleFor('staff_b', 'tr'), 'Ekip B');
    expect(
      [for (final c in reg.commandsFor('staff_b')) '${c.name}:${c.handler}'],
      ['/sales:sales_total'],
    );
    expect(reg.commandsFor('staff_b').single.help('tr'), 'toplam');
    expect(reg.hasHandler('staff_b', 'sales_total'), isTrue);
    expect(reg.commandsFor('staff_a'), isEmpty);
  });

  test(
    'the stored copy is read back by a new repository of the same account',
    () async {
      expect(
        await SupabaseStaffRegistryRepository(member).cached(),
        isNull,
        reason: 'nothing is stored before the first answer',
      );
      await SupabaseStaffRegistryRepository(member).refresh();
      final back = await SupabaseStaffRegistryRepository(member).cached();
      expect(back, isNotNull);
      expect(back!.chats.keys, ['staff_b']);
      expect(back.wordFor('staff_b', 'sales_total'), '/sales');
      expect(back.titleFor('staff_b', 'tr'), 'Ekip B');
    },
  );

  test('the copy is stored under the signed-in account\'s own key', () async {
    await SupabaseStaffRegistryRepository(member).refresh();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getKeys().where((k) => k.startsWith(_prefix)), [
      '$_prefix${member.auth.currentUser!.id}',
    ]);
  });

  test('account B never sees account A\'s stored copy', () async {
    await SupabaseStaffRegistryRepository(member).refresh();
    expect(await SupabaseStaffRegistryRepository(member).cached(), isNotNull);
    expect(await SupabaseStaffRegistryRepository(outsider).cached(), isNull);
  });

  test('signed out, nothing is read or written', () async {
    await SupabaseStaffRegistryRepository(member).refresh();
    // A real copy also sits under the keys a missing user id could produce.
    final prefs0 = await SharedPreferences.getInstance();
    final copy = prefs0.getString('$_prefix${member.auth.currentUser!.id}');
    expect(copy, isNotNull);
    for (final k in ['sis.staff.registry', _prefix, '${_prefix}null']) {
      await prefs0.setString(k, copy!);
    }
    await member.auth.signOut(scope: SignOutScope.local);
    try {
      final repo = SupabaseStaffRegistryRepository(member);
      expect(
        await repo.cached(),
        isNull,
        reason: 'a signed-out read sees no account\'s copy',
      );
      await repo.refresh();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final keys = prefs
          .getKeys()
          .where((k) => k.startsWith('sis.staff.registry'))
          .toList();
      expect(
        keys,
        hasLength(4),
        reason: 'a signed-out refresh writes no key: $keys',
      );
    } finally {
      member = await _signIn('staffreg-member@sis.test');
    }
  });

  test('clear after sign-out still removes every stored copy', () async {
    await SupabaseStaffRegistryRepository(member).refresh();
    await SupabaseStaffRegistryRepository(outsider).refresh();
    final memberId = member.auth.currentUser!.id;
    await member.auth.signOut(scope: SignOutScope.local);
    try {
      await SupabaseStaffRegistryRepository(member).clear();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getKeys().where((k) => k.startsWith(_prefix)), isEmpty);
    } finally {
      member = await _signIn('staffreg-member@sis.test');
    }
    expect(member.auth.currentUser!.id, memberId);
    expect(await SupabaseStaffRegistryRepository(member).cached(), isNull);
    expect(await SupabaseStaffRegistryRepository(outsider).cached(), isNull);
  });

  test('a non-member gets an empty registry (no error), and it replaces a stored one', () async {
    await SupabaseStaffRegistryRepository(member).refresh();
    final r = await SupabaseStaffRegistryRepository(outsider).refresh();
    expect(r, isA<Ok<StaffRegistry>>(), reason: '$r');
    expect((r as Ok<StaffRegistry>).value.chats, isEmpty);
    final back = await SupabaseStaffRegistryRepository(outsider).cached();
    expect(back?.chats ?? const {}, isEmpty);
  });

  test('clear forgets the stored registry', () async {
    final repo = SupabaseStaffRegistryRepository(member);
    await repo.refresh();
    expect(await repo.cached(), isNotNull);
    await repo.clear();
    expect(await repo.cached(), isNull);
  });
}
