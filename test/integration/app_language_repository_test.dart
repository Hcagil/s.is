@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/appearance/domain/appearance_settings.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// `setAppLanguage` and the signed-in gate over a running local Supabase.
///
/// Written from the contract, not the code: the repository stores 'en' or
/// 'tr' in the caller's own profiles.app_language and refuses anything else,
/// or a signed-out client, with DeniedFailure before any request leaves. No
/// client can read the column back, so the stored value is read with the
/// service role. The gate writes the shown language at start and again when
/// Settings changes it.
///
/// Requires `docker compose run --rm supabase start` and
/// SUPABASE_TEST_SERVICE_KEY (see test/support/service_key.dart). Accounts:
/// al-ana and al-ben (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

/// Counts every request a client sends, and still sends it.
class _Counting extends http.BaseClient {
  final _inner = http.Client();
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _inner.send(request);
  }
}

SupabaseClient _client({http.Client? httpClient}) => SupabaseClient(
  _url,
  _key,
  httpClient: httpClient,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client();
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

/// The stored value, read as the server (no client may read it).
Future<String?> _stored(String userId) async {
  final admin = SupabaseClient(_url, serviceKey());
  final row = await admin
      .from('profiles')
      .select('app_language')
      .eq('user_id', userId)
      .single();
  return row['app_language'] as String?;
}

Future<void> _reset(String userId) async {
  final admin = SupabaseClient(_url, serviceKey());
  await admin
      .from('profiles')
      .update({'app_language': null})
      .eq('user_id', userId);
}

void main() {
  // flutter_test answers every HTTP request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient ana;
  late SupabaseClient ben;
  String id(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    ana = await _signedIn('al-ana@mail.test');
    ben = await _signedIn('al-ben@mail.test');
  });

  setUp(() async {
    await _reset(id(ana));
    await _reset(id(ben));
  });

  group('SupabaseProfileRepository.setAppLanguage', () {
    test('stores en, then tr, in the caller\'s own row', () async {
      final repo = SupabaseProfileRepository(ana);
      expect(await _stored(id(ana)), isNull, reason: 'fixture');

      expect(await repo.setAppLanguage('en'), isA<Ok<void>>());
      expect(await _stored(id(ana)), 'en');

      expect(await repo.setAppLanguage('tr'), isA<Ok<void>>());
      expect(await _stored(id(ana)), 'tr');
    });

    test('touches no other member\'s row', () async {
      expect(
        await SupabaseProfileRepository(ben).setAppLanguage('tr'),
        isA<Ok<void>>(),
      );
      expect(
        await SupabaseProfileRepository(ana).setAppLanguage('en'),
        isA<Ok<void>>(),
      );
      expect(await _stored(id(ben)), 'tr');
      expect(await _stored(id(ana)), 'en');
    });

    for (final bad in ['fr', 'EN', 'Tr', '', ' en', 'en-US']) {
      test('refuses "$bad" with DeniedFailure and no request', () async {
        final counting = _Counting();
        final client = _client(httpClient: counting);
        // A real, unexpired session, recovered locally (no request).
        await client.auth.recoverSession(
          jsonEncode(ana.auth.currentSession!.toJson()),
        );
        counting.requests.clear();

        final r = await SupabaseProfileRepository(client).setAppLanguage(bad);

        expect(r, isA<Err<void>>());
        expect((r as Err<void>).failure, isA<DeniedFailure>());
        expect(counting.requests, isEmpty, reason: 'a request was sent');
        expect(await _stored(id(ana)), isNull);
      });
    }

    test('a signed-out client is refused with no request', () async {
      final counting = _Counting();
      final client = _client(httpClient: counting);
      final r = await SupabaseProfileRepository(client).setAppLanguage('en');
      expect(r, isA<Err<void>>());
      expect((r as Err<void>).failure, isA<DeniedFailure>());
      expect(counting.requests, isEmpty, reason: 'a request was sent');
    });

    test(
      'the counting client does see a real write (the probe works)',
      () async {
        final counting = _Counting();
        final client = _client(httpClient: counting);
        await client.auth.recoverSession(
          jsonEncode(ana.auth.currentSession!.toJson()),
        );
        counting.requests.clear();
        expect(
          await SupabaseProfileRepository(client).setAppLanguage('en'),
          isA<Ok<void>>(),
        );
        expect(counting.requests, isNotEmpty);
        expect(await _stored(id(ana)), 'en');
      },
    );
  });

  testWidgets('the app writes the shown language at start and on a change '
      'in Settings', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);

    Future<String?> storedNow() => t.runAsync<String?>(() => _stored(id(ana)));
    Future<void> until(String? want) async {
      for (var i = 0; i < 100; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
        if (await storedNow() == want) return;
      }
      fail('app_language never became $want (is ${await storedNow()})');
    }

    // The overrides main.dart installs for these, over ana's client.
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: _url,
              supabasePublishableKey: _key,
              googleWebClientId: 'c',
            ),
          ),
          authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(FakeChat()),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(ana),
          ),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(ana),
          ),
          appearanceStoreProvider.overrideWithValue(
            const SharedPrefsAppearanceStore(),
          ),
          initialAppearanceProvider.overrideWithValue(
            const AppearanceSettings(language: AppLanguage.en),
          ),
        ],
        child: const SisApp(),
      ),
    );
    // Settings says English on a Turkish phone: en is what the app shows.
    await until('en');

    await ProviderScope.containerOf(t.element(find.byType(SisApp)))
        .read(appearanceProvider.notifier)
        .setLanguage(AppLanguage.system);
    // System on a Turkish phone: tr.
    await until('tr');

    // dart:io keeps an idle HTTP connection on a 15 s timer that was created
    // inside the test's fake clock; let it run out.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 16));
  });
}
