// iOS updates go through TestFlight, never Play (2026-09-29), written from the
// contract. The two platform channels the update repositories can reach are
// answered here: in_app_update's (a real iPhone has no handler for it, so any
// call is recorded as the MissingPluginException it would be on a device) and
// url_launcher's platform side, which records the URL and launch mode.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/data/play_update_repository.dart';
import 'package:sis/features/update/data/testflight_update_repository.dart';
import 'package:sis/features/update/domain/update_repository.dart';
import 'package:sis/features/update/domain/update_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../support/fakes.dart';
import '../../support/url_launcher_platform.dart';

const _inAppUpdate = MethodChannel('de.ffuf.in_app_update/methods');
const _testFlight = 'itms-beta://';

void info({String build = '105', String version = '0.6.0'}) =>
    PackageInfo.setMockInitialValues(
      appName: 'SIS',
      packageName: 'com.esd.sis',
      version: version,
      buildNumber: build,
      buildSignature: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every call that reached in_app_update's channel.
  late List<String> playCalls;
  late FakeUrlLauncherPlatform urls;

  setUp(() {
    playCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inAppUpdate, (call) async {
          playCalls.add(call.method);
          throw MissingPluginException(
            'No implementation found for '
            '${call.method} on channel ${_inAppUpdate.name}',
          );
        });
    UrlLauncherPlatform.instance = urls = FakeUrlLauncherPlatform();
    info();
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inAppUpdate, null),
  );

  // No network in unit tests: every request fails as it does offline.
  late SupabaseClient dead;
  setUp(
    () => dead = SupabaseClient(
      'http://supabase.test',
      'k',
      httpClient: MockClient(
        (_) async => throw http.ClientException('Failed host lookup'),
      ),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    ),
  );
  tearDown(() => dead.dispose());

  group('TestFlightUpdateRepository', () {
    late UpdateRepository repo;
    setUp(() => repo = TestFlightUpdateRepository(dead));

    test('checkForUpdate: nothing offered, nothing downloaded, Play never '
        'asked', () async {
      final r = await repo.checkForUpdate();

      expect(r, isA<Ok<PlayUpdateCheck>>(), reason: '$r');
      final check = (r as Ok<PlayUpdateCheck>).value;
      expect(check.offeredBuild, isNull);
      expect(check.downloaded, isFalse);
      expect(playCalls, isEmpty);
    });

    test('start/completeFlexibleUpdate reach no platform at all', () async {
      await repo.startFlexibleUpdate();
      await repo.completeFlexibleUpdate();

      expect(playCalls, isEmpty);
      expect(urls.launches, isEmpty);
    });

    test('startImmediateUpdate opens TestFlight, externally, once', () async {
      await repo.startImmediateUpdate();

      expect(playCalls, isEmpty);
      expect(urls.launches, [
        (url: _testFlight, mode: PreferredLaunchMode.externalApplication),
      ]);
    });

    test('openStoreListing opens TestFlight, externally, once', () async {
      await repo.openStoreListing();

      expect(playCalls, isEmpty);
      expect(urls.launches, [
        (url: _testFlight, mode: PreferredLaunchMode.externalApplication),
      ]);
    });

    test(
      'installedBuild / installedVersion read the bundle as on Android',
      () async {
        info(build: '217', version: '1.4.2');
        final play = PlayUpdateRepository(dead);

        expect(await repo.installedBuild(), 217);
        expect(await play.installedBuild(), 217);
        expect(await repo.installedVersion(), '1.4.2');
      },
    );

    test(
      'an unparsable build number never blocks: 1 << 30, as on Android',
      () async {
        info(build: 'not-a-number');

        expect(await repo.installedBuild(), 1 << 30);
        expect(await PlayUpdateRepository(dead).installedBuild(), 1 << 30);
      },
    );

    test('minSupportedBuild offline: an Err, as on Android', () async {
      final r = await repo.minSupportedBuild();
      expect(r, isA<Err<int>>());
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('PlayUpdateRepository.openStoreListing (Android, unchanged)', () {
    test('opens the Play app listing first', () async {
      await PlayUpdateRepository(dead).openStoreListing();

      expect(urls.launches.first.url, 'market://details?id=com.esd.sis');
      expect(urls.launches.map((l) => l.url), isNot(contains(_testFlight)));
    });

    test('no Play app -> then the web listing', () async {
      urls.handles = (url) => !url.startsWith('market:');
      await PlayUpdateRepository(dead).openStoreListing();

      final opened = urls.launches.map((l) => Uri.parse(l.url)).toList();
      expect(opened.first.toString(), 'market://details?id=com.esd.sis');
      expect(opened, hasLength(2));
      expect(opened.last.scheme, 'https');
      expect(opened.last.host, 'play.google.com');
      expect(opened.last.queryParameters['id'], 'com.esd.sis');
    });
  });

  group('UpdateController over the real TestFlightUpdateRepository', () {
    ProviderContainer make() => ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: 'https://x.supabase.co',
            supabasePublishableKey: 'k',
            googleWebClientId: 'c',
          ),
        ),
        authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
        updateRepositoryProvider.overrideWithValue(
          TestFlightUpdateRepository(dead),
        ),
      ],
    );

    test('settles idle: no banner, and Play is never called', () async {
      final c = make();
      await c.read(sessionControllerProvider.future);
      await Future<void>.delayed(Duration.zero);
      final s = await c.read(updateControllerProvider.future);

      expect(s, isA<UpdateIdle>());
      expect(playCalls, isEmpty, reason: 'in_app_update reached on iOS');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
