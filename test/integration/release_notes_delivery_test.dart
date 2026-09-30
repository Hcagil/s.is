@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/update/data/supabase_release_notes_delivery.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/service_key.dart';

/// SupabaseReleaseNotesDelivery against the real local stack: the RPC it
/// calls, the parameter it names, what it remembers on the device and when.
/// Written from the contract (docs/DECISIONS.md, 2026-09-30):
///
///   deliver(userId) reads the installed build from PackageInfo, skips when
///   `release_notes_served_build_<userId>` already holds a build >= it
///   (Ok(false)), else calls deliver_release_notes(installed_build) and, only
///   on success, stores the build (Ok(true)). Any failure is Err and stores
///   nothing, so the next start tries again.
///
/// A skip is proven over a dead host: a call that should have been skipped
/// but was made fails instead of returning Ok(false).
///
/// Builds are numbered from the clock, so a rerun without a reset
/// still asks for newer builds than whit was last served. Requires
/// `docker compose run --rm supabase start`; whit is seeded for this file.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

void installed(int build) => PackageInfo.setMockInitialValues(
  appName: 'SIS',
  packageName: 'com.esd.sis',
  version: '0.27.0',
  buildNumber: '$build',
  buildSignature: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient whit, service;
  late String uid;
  late String prefKey;
  // Tenths of a second since 2023-11: every run starts above every build
  // an earlier run served (each uses fewer than ten), and it fits a
  // Postgres integer. ponytail: overflows in 2030; move the offset then.
  final base =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1700000000) * 10;
  final notes = <int>[];

  Future<void> note(int build, String text) async {
    await service.from('release_notes').insert({'build': build, 'note': text});
    notes.add(build);
  }

  /// whit's notes from SIS with exactly [body], read as whit.
  Future<int> delivered(String body) async {
    final sys = await whit
        .from('conversations')
        .select('id')
        .eq('system', true);
    if (sys.isEmpty) return 0;
    expect(sys, hasLength(1), reason: 'one system chat per member');
    final rows = await whit
        .from('messages')
        .select('id')
        .eq('conversation_id', sys.single['id'] as String)
        .eq('body', body);
    return rows.length;
  }

  Future<Object?> stored() async =>
      (await SharedPreferences.getInstance()).get(prefKey);

  setUpAll(() async {
    service = _client(serviceKey());
    whit = await _signedIn('whit@integration.test');
    uid = whit.auth.currentUser!.id;
    prefKey = 'release_notes_served_build_$uid';
    // whit's delivery state now stands at `base`: every later build is new.
    await whit.rpc('deliver_release_notes', params: {'installed_build': base});
  });

  tearDownAll(() async {
    if (notes.isNotEmpty) {
      await service.from('release_notes').delete().inFilter('build', notes);
    }
    await whit.dispose();
    await service.dispose();
  });

  test('a newer build: the RPC runs, the note arrives once, and the build is '
      'remembered for this member', () async {
    final b = base + 1;
    await note(b, 'whit note $b');
    installed(b);
    SharedPreferences.setMockInitialValues({});

    final r = await SupabaseReleaseNotesDelivery(whit).deliver(uid);

    expect(r, isA<Ok<bool>>());
    expect((r as Ok<bool>).value, isTrue, reason: 'the RPC succeeded');
    expect(await delivered('whit note $b'), 1);
    expect('${await stored()}', '$b', reason: 'the served build is stored');
  });

  test('the build already stored is skipped without a call', () async {
    installed(base + 1);
    SharedPreferences.setMockInitialValues({prefKey: base + 1});
    final dead = await deadButSignedIn(whit);
    addTearDown(dead.dispose);

    final r = await SupabaseReleaseNotesDelivery(dead).deliver(uid);

    expect(r, isA<Ok<bool>>(), reason: 'a call was made: $r');
    expect((r as Ok<bool>).value, isFalse);
  });

  test('a stored build above the installed one is skipped too', () async {
    installed(base + 1);
    SharedPreferences.setMockInitialValues({prefKey: base + 50});
    final dead = await deadButSignedIn(whit);
    addTearDown(dead.dispose);

    final r = await SupabaseReleaseNotesDelivery(dead).deliver(uid);

    expect(r, isA<Ok<bool>>(), reason: 'a call was made: $r');
    expect((r as Ok<bool>).value, isFalse);
    expect('${await stored()}', '${base + 50}', reason: 'never lowered');
  });

  test('another member\'s stored build does not skip this one', () async {
    installed(base + 1);
    SharedPreferences.setMockInitialValues({
      'release_notes_served_build_someone-else': base + 50,
    });
    final dead = await deadButSignedIn(whit);
    addTearDown(dead.dispose);

    final r = await SupabaseReleaseNotesDelivery(dead).deliver(uid);

    expect(r, isA<Err<bool>>(), reason: 'whit was not asked for: $r');
    expect(await stored(), isNull);
  });

  test(
    'offline: Err, nothing remembered, and the next start delivers',
    () async {
      final b = base + 3;
      await note(b, 'whit note $b');
      installed(b);
      SharedPreferences.setMockInitialValues({prefKey: base + 1});
      final dead = await deadButSignedIn(whit);
      addTearDown(dead.dispose);

      final offline = await SupabaseReleaseNotesDelivery(dead).deliver(uid);

      expect(offline, isA<Err<bool>>());
      expect(
        '${await stored()}',
        '${base + 1}',
        reason: 'a failure stores nothing',
      );
      expect(await delivered('whit note $b'), 0);

      final online = await SupabaseReleaseNotesDelivery(whit).deliver(uid);

      expect(online, isA<Ok<bool>>());
      expect((online as Ok<bool>).value, isTrue);
      expect(await delivered('whit note $b'), 1);
      expect('${await stored()}', '$b');
    },
  );

  test('a server refusal is Err and stores nothing', () async {
    final b = base + 4;
    installed(b);
    SharedPreferences.setMockInitialValues({});
    // No session: deliver_release_notes needs app access and refuses.
    final anon = _client(_key);
    addTearDown(anon.dispose);

    final r = await SupabaseReleaseNotesDelivery(anon).deliver(uid);

    expect(r, isA<Err<bool>>());
    expect(await stored(), isNull);
  });

  test('parallel RPCs deliver each note exactly once', () async {
    final b = base + 6;
    await note(base + 5, 'whit note ${base + 5}');
    await note(b, 'whit note $b');

    final counts = await Future.wait([
      for (var i = 0; i < 8; i++)
        whit.rpc<int>('deliver_release_notes', params: {'installed_build': b}),
    ]);

    expect(counts.fold<int>(0, (a, n) => a + n), 2, reason: '$counts');
    expect(await delivered('whit note ${base + 5}'), 1);
    expect(await delivered('whit note $b'), 1);
  });

  test('two starts at once through the class deliver the note once', () async {
    final b = base + 7;
    await note(b, 'whit note $b');
    installed(b);
    SharedPreferences.setMockInitialValues({});

    final rs = await Future.wait([
      SupabaseReleaseNotesDelivery(whit).deliver(uid),
      SupabaseReleaseNotesDelivery(whit).deliver(uid),
      SupabaseReleaseNotesDelivery(whit).deliver(uid),
    ]);

    expect(rs, everyElement(isA<Ok<bool>>()));
    expect(await delivered('whit note $b'), 1);
    expect('${await stored()}', '$b');
  });
}
