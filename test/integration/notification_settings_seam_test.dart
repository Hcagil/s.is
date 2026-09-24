@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/data/supabase_notification_settings_repository.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/notifications/presentation/notification_pages.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

/// NotificationsScreen and MuteTile wired exactly as `main.dart` wires them,
/// over a real [SupabaseNotificationSettingsRepository], driven through the
/// UI and checked against the database with a second, independent read.
///
/// The unit and widget tests prove the controllers and screens behave over a
/// fake repository, and the repository test proves its query shaping. They
/// cannot prove that a tap on the real screen, through the real provider,
/// reaches the real table — a wrong provider override, or a controller that
/// updates its own state but never calls the repository, would still be
/// green everywhere else.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo (also used
/// by conversation_list_screen_seam_test.dart, play_update_repository, and
/// realtime_channels_test.dart) and ann (also used by
/// chat_repository_test.dart/realtime_warmup_test.dart): signing in claims
/// the active device, so run with --concurrency=1 like the rest of the
/// suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client(String url) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_url);
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

void main() {
  // Real timers, not the fake clock `TestWidgetsFlutterBinding.
  // ensureInitialized()` installs: the NotificationsScreen case mounts the
  // real chat repository too (the Muted section reads members and
  // conversations), which opens a real Realtime channel whose own timers
  // would otherwise make `pumpAndSettle()` spin forever waiting for a
  // heartbeat that a fake clock never advances on its own (see
  // conversation_list_screen_seam_test.dart).
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? cleoClient, annClient;
  late String annId;

  setUpAll(() async {
    cleoClient = await _signedIn('cleo@integration.test');
    annClient = await _signedIn('ann@integration.test');
    annId = annClient!.auth.currentUser!.id;
    await cleoClient!
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', cleoClient!.auth.currentUser!.id);
    // A clean starting mute list: `authenticated` may delete its own mutes.
    await cleoClient!
        .from('notification_mutes')
        .delete()
        .eq('user_id', cleoClient!.auth.currentUser!.id);
  });

  tearDownAll(() async {
    await cleoClient?.dispose();
    await annClient?.dispose();
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      if (ok()) return;
    }
    fail('never happened: $what');
  }

  /// A bounded real-time wait for an in-flight save to land, without
  /// `pumpAndSettle()`: once a real Realtime channel is open its own timers
  /// never stop scheduling frames, so `pumpAndSettle()` never returns.
  Future<void> settle(WidgetTester t, {int steps = 20}) async {
    for (var i = 0; i < steps; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
  }

  group('NotificationsScreen', () {
    Widget app() => ProviderScope(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'c',
          ),
        ),
        // Google sign-in has nothing to run against locally
        // (docs/ARCHITECTURE.md); the session it carries is cleo's real one.
        authRepositoryProvider.overrideWithValue(
          FakeAuth(
            session: true,
            member: Member(
              userId: cleoClient!.auth.currentUser!.id,
              displayName: 'Cleo',
            ),
          ),
        ),
        updateRepositoryProvider.overrideWithValue(FakeUpdate()),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(cleoClient!),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(cleoClient!),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(cleoClient!),
        ),
        // The one connection under test: notification settings, over the
        // real repository, exactly as main.dart wires it.
        notificationSettingsRepositoryProvider.overrideWithValue(
          SupabaseNotificationSettingsRepository(cleoClient!),
        ),
      ],
      child: const SisApp(),
    );

    testWidgets(
      'toggling the switch and picking a preview through the UI writes '
      'through to the database',
      (t) async {
        // A known starting point, written straight to the table.
        await SupabaseNotificationSettingsRepository(cleoClient!).save(
          const NotificationSettings(
            enabled: true,
            preview: NotificationPreview.full,
          ),
        );

        await t.pumpWidget(app());
        await until(
          t,
          () => byKey('home-settings').evaluate().isNotEmpty,
          'home',
        );
        await t.tap(byKey('home-settings'));
        await until(
          t,
          () => byKey('settings-notifications').evaluate().isNotEmpty,
          'settings',
        );
        await t.tap(byKey('settings-notifications'));
        await until(
          t,
          () => byKey('notif-enabled').evaluate().isNotEmpty,
          'the notifications screen',
        );

        await t.tap(byKey('notif-enabled'));
        await settle(t);

        final afterToggle = _ok(
          await SupabaseNotificationSettingsRepository(cleoClient!).load(),
          'load after toggling the switch',
        );
        expect(
          afterToggle.enabled,
          isFalse,
          reason: 'the switch on screen did not reach the database',
        );

        await t.ensureVisible(byKey('notif-preview-none'));
        await t.tap(byKey('notif-preview-none'));
        await settle(t);

        final afterPreview = _ok(
          await SupabaseNotificationSettingsRepository(cleoClient!).load(),
          'load after picking a preview',
        );
        expect(
          afterPreview.preview,
          NotificationPreview.none,
          reason: 'the radio pick on screen did not reach the database',
        );
        expect(
          afterPreview.enabled,
          isFalse,
          reason: 'picking a preview must not undo the earlier toggle',
        );

        // Let the real Realtime channel this mount opened wind down cleanly
        // before the test ends (see profile_pages_integration_test.dart).
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => cleoClient!.removeAllChannels());
        await t.runAsync(() => cleoClient!.realtime.disconnect());
        await t.pump(const Duration(seconds: 61));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('MuteTile', () {
    Widget app() => ProviderScope(
      overrides: [
        notificationSettingsRepositoryProvider.overrideWithValue(
          SupabaseNotificationSettingsRepository(cleoClient!),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MuteTile(kind: MuteKind.person, target: annId),
        ),
      ),
    );

    testWidgets(
      'muting and unmuting through the sheet writes through to the database',
      (t) async {
        Future<Result<List<Mute>>> fresh() =>
            SupabaseNotificationSettingsRepository(cleoClient!).mutes();

        await t.pumpWidget(app());
        await t.pumpAndSettle();
        expect(find.text('Mute notifications'), findsOneWidget);

        await t.tap(byKey('mute-tile'));
        await t.pumpAndSettle();
        await t.tap(byKey('mute-oneWeek'));
        await t.pumpAndSettle();

        final afterMute = _ok(await fresh(), 'mutes after muting');
        final row = afterMute.firstWhere(
          (m) => m.kind == MuteKind.person && m.target == annId,
          orElse: () => fail('the mute on screen never reached the database'),
        );
        expect(row.until, isNotNull, reason: '1 week is not "Always"');

        // The tile itself now reads back what the database holds, through a
        // fresh build of the same widget.
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(app());
        await t.pumpAndSettle();
        expect(find.text('Muted'), findsOneWidget);

        await t.tap(byKey('mute-tile'));
        await t.pumpAndSettle();
        await t.tap(byKey('mute-off'));
        await t.pumpAndSettle();

        final afterUnmute = _ok(await fresh(), 'mutes after unmuting');
        expect(
          afterUnmute.any(
            (m) => m.kind == MuteKind.person && m.target == annId,
          ),
          isFalse,
          reason: 'the unmute on screen never reached the database',
        );
      },
    );
  });
}
