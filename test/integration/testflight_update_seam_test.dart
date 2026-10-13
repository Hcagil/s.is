@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/data/testflight_update_repository.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fakes.dart';
import '../support/url_launcher_platform.dart';
import '../support/video_fakes.dart';

/// The iOS update seam: UpdateController over the real
/// TestFlightUpdateRepository, whose minimum comes from the real
/// `app_config` row of a running local Supabase, and whose store is the
/// url_launcher platform side. Only the session is a fake (FakeAuth), as
/// in update_controller_test.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo
/// (supabase/seed.sql); run with --concurrency=1 like the rest of the suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const _inAppUpdate = MethodChannel('de.ffuf.in_app_update/methods');

Future<SupabaseClient> signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

void installed(String build) => PackageInfo.setMockInitialValues(
  appName: 'SIS',
  packageName: 'com.esd.sis',
  version: '0.6.0',
  buildNumber: build,
  buildSignature: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient client;
  late FakeUrlLauncherPlatform urls;
  late List<String> playCalls;

  setUpAll(() async => client = await signedIn('cleo@integration.test'));
  tearDownAll(() => client.dispose());

  setUp(() {
    playCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inAppUpdate, (call) async {
          playCalls.add(call.method);
          throw MissingPluginException(call.method);
        });
    UrlLauncherPlatform.instance = urls = FakeUrlLauncherPlatform();
  });

  Future<(ProviderContainer, UpdateState)> settle() async {
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        runtimeConfigProvider.overrideWithValue(
          RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'c',
          ),
        ),
        authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
        updateRepositoryProvider.overrideWithValue(
          TestFlightUpdateRepository(client),
        ),
      ],
    );
    await c.read(sessionControllerProvider.future);
    await Future<void>.delayed(Duration.zero);
    return (c, await c.read(updateControllerProvider.future));
  }

  test('a current build: idle, no banner, Play never called', () async {
    installed('999999');

    final (_, s) = await settle();

    expect(s, isA<UpdateIdle>());
    expect(playCalls, isEmpty);
    expect(urls.launches, isEmpty);
  });

  test(
    'below the real minimum: required; Update now opens TestFlight',
    () async {
      final min = await TestFlightUpdateRepository(client).minSupportedBuild();
      expect(
        min,
        isA<Ok<int>>(),
        reason: min is Err<int> ? min.failure.message : '',
      );
      expect((min as Ok<int>).value, greaterThanOrEqualTo(1));
      installed('0');

      final (c, s) = await settle();
      expect(s, isA<UpdateRequired>());
      expect((s as UpdateRequired).minimum, min.value);

      await c.read(updateControllerProvider.notifier).updateNow();

      expect(playCalls, isEmpty, reason: 'in_app_update reached on iOS');
      expect(urls.launches, isNotEmpty);
      expect(urls.launches.last.url, 'itms-beta://');
      expect(urls.launches.last.mode, PreferredLaunchMode.externalApplication);
      expect(
        urls.launches.map((l) => l.url),
        everyElement('itms-beta://'),
        reason: 'a Play URL reached the iPhone',
      );
    },
  );
}
