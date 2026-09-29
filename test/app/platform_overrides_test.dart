// The platform wiring as main.dart mounts it: `platformOverrides` is the
// function main() spreads into its ProviderScope, read here from a
// ProviderContainer. Which sign-in the auth repository does is proven by
// behaviour, through the same stand-ins as google_sign_in_nonce_test: each
// platform's Google SDK (iOS embeds a nonce even when handed none, Android
// does not) and GoTrue's nonce rules behind the real SupabaseClient.
//
// Not covered: that main() passes `defaultTargetPlatform` rather than a
// constant -- main() needs dart-defines, Supabase and Firebase to run.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/data/play_update_repository.dart';
import 'package:sis/features/update/data/testflight_update_repository.dart';
import 'package:sis/main.dart' show platformOverrides;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/google_sign_in_stand_ins.dart';
import '../support/url_launcher_platform.dart';

const _config = RuntimeConfig(
  supabaseUrl: 'http://supabase.test',
  supabasePublishableKey: 'publishable-key',
  googleWebClientId: googleWebClient,
);
const _inAppUpdate = MethodChannel('de.ffuf.in_app_update/methods');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoTrueStandIn gotrue;
  late SupabaseClient client;
  late FakeGooglePlatform google;
  late FakeUrlLauncherPlatform urls;
  late List<String> playCalls;

  setUp(() {
    gotrue = GoTrueStandIn();
    client = SupabaseClient(
      _config.supabaseUrl,
      _config.supabasePublishableKey,
      httpClient: gotrue.client,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    UrlLauncherPlatform.instance = urls = FakeUrlLauncherPlatform();
    playCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inAppUpdate, (call) async {
          playCalls.add(call.method);
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_inAppUpdate, null);
    await client.dispose();
  });

  /// The container as main() builds it for [platform], on a device whose
  /// Google SDK is iOS's or not.
  ProviderContainer mount(TargetPlatform platform) {
    GoogleSignInPlatform.instance = google = FakeGooglePlatform(
      ios: platform == TargetPlatform.iOS,
    );
    final overrides = platformOverrides(platform, client, _config);
    expect(overrides, hasLength(2));
    return ProviderContainer.test(overrides: overrides);
  }

  test('iOS: TestFlight updates; sign-in hashes a nonce into Google and '
      'sends the raw one to Supabase, which accepts it', () async {
    final c = mount(TargetPlatform.iOS);

    final update = c.read(updateRepositoryProvider);
    expect(update, isA<TestFlightUpdateRepository>());
    await update.openStoreListing();
    expect(urls.launches.single.url, 'itms-beta://');

    final r = await c.read(authRepositoryProvider).signInWithGoogle();
    expect(r, isA<Ok<void>>(), reason: '$r');
    final hashed = google.inits.single.nonce;
    expect(hashed, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(google.inits.single.serverClientId, googleWebClient);
    final raw = gotrue.grants.single['nonce'] as String;
    expect(sha256hex(raw), hashed);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    test(
      '${platform.name}: Play updates; sign-in sends no nonce anywhere',
      () async {
        final c = mount(platform);

        final update = c.read(updateRepositoryProvider);
        expect(update, isA<PlayUpdateRepository>());
        expect(update, isNot(isA<TestFlightUpdateRepository>()));
        await update.openStoreListing();
        expect(urls.launches.first.url, 'market://details?id=com.esd.sis');

        final r = await c.read(authRepositoryProvider).signInWithGoogle();
        expect(r, isA<Ok<void>>(), reason: '$r');
        expect(google.inits.single.nonce, isNull);
        expect(google.inits.single.serverClientId, googleWebClient);
        expect(gotrue.grants.single['nonce'], isNull);
      },
    );
  }

  test('iOS: the update check never reaches in_app_update', () async {
    final r = await mount(TargetPlatform.iOS)
        .read(updateRepositoryProvider)
        .checkForUpdate();
    expect(r, isA<Ok<Object?>>());
    expect(playCalls, isEmpty);
  });
}
