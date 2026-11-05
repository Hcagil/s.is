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
    'the stored copy is read back by a new repository, without the network',
    () async {
      expect(
        await SupabaseStaffRegistryRepository(member).cached(),
        isNull,
        reason: 'nothing is stored before the first answer',
      );
      await SupabaseStaffRegistryRepository(member).refresh();
      await member.auth.signOut(scope: SignOutScope.local);
      try {
        // A fresh repository on a signed-out client: only local storage can answer.
        final back = await SupabaseStaffRegistryRepository(member).cached();
        expect(back, isNotNull);
        expect(back!.chats.keys, ['staff_b']);
        expect(back.wordFor('staff_b', 'sales_total'), '/sales');
        expect(back.titleFor('staff_b', 'tr'), 'Ekip B');
      } finally {
        member = await _signIn('staffreg-member@sis.test');
      }
    },
  );

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
