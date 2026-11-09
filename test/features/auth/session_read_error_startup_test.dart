// Cold start where the phone's secure storage throws on the sign-in session
// read (security gate F1). Contract: the throw leaves the real
// Supabase.initialize (the session storage is SecureSessionStorage, as
// main.dart passes it), main.dart's start-up catch mounts SisApp with
// StartupFailure.bootstrap, and SisApp shows StartupFailedScreen before any
// session controller or session-end wipe listener is built. So the start
// never reaches SignedOut, and the message-store file and both chat keys
// (sis.store.key, sis.olm.pickle.key) stay where they are. Written from the
// contract, against the plugin's real method channel (SecureChannelFake).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/core/startup_failure.dart';
import 'package:sis/features/appearance/application/appearance_controller.dart';
import 'package:sis/features/appearance/data/picker_wallpaper_photos.dart';
import 'package:sis/features/appearance/data/shared_prefs_appearance_store.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/secure_session_storage.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/auth/presentation/status_screens.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/external_picker_channel.dart';
import 'package:sis/features/chat/data/store/store_location.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../support/secure_channel_fake.dart';

const _sessionKey = 'sis.supabase.session';
const _storeKey = 'sis.store.key';
const _pickleKey = 'sis.olm.pickle.key';
const _config = RuntimeConfig(
  supabaseUrl: 'http://127.0.0.1:54321',
  supabasePublishableKey: 'publishable-test',
  googleWebClientId: 'client-test',
);

/// Every value the session controller takes, built or updated.
final class _Seen extends ProviderObserver {
  final sessions = <Object?>[];
  void _note(ProviderObserverContext c, Object? v) {
    if (c.provider == sessionControllerProvider && v is AsyncValue) {
      if (v.hasValue) sessions.add(v.value);
    }
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      _note(context, value);
  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) => _note(context, newValue);
}

void main() {
  testWidgets('a thrown session read on a cold start: the start-up failure '
      'screen, never SignedOut, the store file and both keys kept', (t) async {
    final kc = SecureChannelFake()..install();
    SharedPreferences.setMockInitialValues({});
    kc.put(null, _sessionKey, '{"access_token":"tok-1"}');
    kc.put(null, _storeKey, 'store-key-value');
    kc.put(null, _pickleKey, 'pickle-key-value');
    // Only the session entry is broken: the chat keys still read fine, so a
    // wipe would find and delete them.
    kc.failRead = (_, key) => key == _sessionKey;

    final tmp = await t.runAsync(
      () => Directory.systemTemp.createTemp('sis-f1-'),
    );
    addTearDown(() => tmp!.delete(recursive: true));
    final store = (await t.runAsync(
      () => storeFile(supportDir: () async => tmp!),
    ))!;
    await t.runAsync(() => store.writeAsBytes([1, 2, 3, 4]));

    // main.dart's start, the part that reads the session: the real
    // Supabase.initialize with main's auth options.
    Object? initError;
    await t.runAsync(() async {
      try {
        await Supabase.initialize(
          url: _config.supabaseUrl,
          publishableKey: _config.supabasePublishableKey,
          authOptions: const FlutterAuthClientOptions(
            authFlowType: AuthFlowType.pkce,
            localStorage: SecureSessionStorage(),
          ),
        );
      } catch (e) {
        initError = e;
      }
    });
    addTearDown(() async {
      try {
        await Supabase.instance.dispose();
      } catch (_) {}
    });
    expect(
      initError,
      isNotNull,
      reason:
          'Supabase.initialize succeeded on a broken session read: '
          'the start goes on with no session, which is SignedOut',
    );

    // main.dart's catch: SisApp with the appearance overrides and the
    // bootstrap failure, nothing else.
    final seen = _Seen();
    const appearanceStore = SharedPrefsAppearanceStore();
    final initial = (await t.runAsync(appearanceStore.load))!;
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appearanceStoreProvider.overrideWithValue(appearanceStore),
          initialAppearanceProvider.overrideWithValue(initial),
          wallpaperPhotosProvider.overrideWithValue(
            const PickerWallpaperPhotos(ExternalPickerChannel()),
          ),
          startupErrorProvider.overrideWithValue(StartupFailure.bootstrap),
          // Not overridden in main's catch: a release build has it compiled
          // in (complete, or main never reaches Supabase.initialize).
          runtimeConfigProvider.overrideWithValue(_config),
        ],
        observers: [seen],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
    // Real time too: anything the session controller awaits outside the
    // fake clock (platform hops, HTTP) gets the chance to settle.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump(const Duration(seconds: 10));
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump(const Duration(seconds: 70));

    expect(find.byType(StartupFailedScreen), findsOneWidget);
    final c = ProviderScope.containerOf(t.element(find.byType(SisApp)));
    expect(
      seen.sessions.whereType<SignedOut>(),
      isEmpty,
      reason: 'session states seen: ${seen.sessions}',
    );
    expect(
      c.exists(chatListSnapshotOwnerProvider),
      isFalse,
      reason: 'the session-end wipe listener was built',
    );
    expect(kc.changes, isEmpty, reason: 'secure storage was written/deleted');
    expect(kc.get(null, _sessionKey), isNotNull);
    expect(kc.get(null, _storeKey), 'store-key-value');
    expect(kc.get(null, _pickleKey), 'pickle-key-value');
    expect(await t.runAsync(store.exists), isTrue, reason: 'store file gone');
    expect(t.takeException(), isNull);
    // The binding checks this before tear-downs run (the fake resets it there).
    debugDefaultTargetPlatformOverride = null;
  });

  test('main.dart: Supabase.initialize runs inside the try whose catch '
      'mounts SisApp with StartupFailure.bootstrap', () {
    final src = File('lib/main.dart').readAsStringSync();
    final init = src.indexOf('Supabase.initialize(');
    expect(init, greaterThan(0));
    final tryAt = src.lastIndexOf('try {', init);
    expect(tryAt, greaterThan(0));
    expect(
      src.substring(tryAt, init),
      isNot(contains('} catch')),
      reason: 'initialize is not inside that try',
    );
    final catchAt = src.indexOf('} catch (', init);
    expect(catchAt, greaterThan(init));
    final failAt = src.indexOf(
      'startupErrorProvider.overrideWithValue(StartupFailure.bootstrap)',
      catchAt,
    );
    expect(failAt, greaterThan(catchAt));
    expect(
      src.substring(catchAt + 1, failAt),
      isNot(contains('} catch')),
      reason: 'the bootstrap failure is mounted by a later catch',
    );
  });
}
