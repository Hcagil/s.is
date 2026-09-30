@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/release_notes_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/data/supabase_release_notes_delivery.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/service_key.dart';

/// The What's new connection as main.dart mounts it: SisApp, the real
/// SupabaseReleaseNotesDelivery over a signed-in client, the real chat
/// repository behind the list. The unit tests prove the controller over a
/// fake delivery and the delivery over the real RPC; only this proves the
/// app, started on a newer build, actually asks, that the SIS chat reaches
/// the list without a manual refresh, that the real repository marks it as
/// the system chat (no composer), and that a failed start neither blocks
/// the app nor loses the note for the next one.
///
/// Builds are numbered from the clock so a rerun without a reset still asks
/// for newer builds than wynn was last served. Requires
/// `docker compose run --rm supabase start`; wynn is seeded for this file.
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
  // Real timers: the real chat repository opens a Realtime channel (see
  // notification_settings_seam_test.dart).
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient wynn, service;
  late String uid, prefKey;
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

  Future<String?> systemChat() async {
    final rows = await wynn
        .from('conversations')
        .select('id')
        .eq('system', true);
    return rows.isEmpty ? null : rows.single['id'] as String;
  }

  Future<int> delivered(String body) async {
    final id = await systemChat();
    if (id == null) return 0;
    final rows = await wynn
        .from('messages')
        .select('id')
        .eq('conversation_id', id)
        .eq('body', body);
    return rows.length;
  }

  Future<Object?> stored() async =>
      (await SharedPreferences.getInstance()).get(prefKey);

  setUpAll(() async {
    service = _client(serviceKey());
    wynn = await _signedIn('wynn@integration.test');
    uid = wynn.auth.currentUser!.id;
    prefKey = 'release_notes_served_build_$uid';
    await wynn
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', uid);
    // No delivery before the first start: on a fresh stack (as in CI) the
    // app's own first call creates the SIS chat, so the list can only learn
    // of it by reloading -- Realtime says nothing about a new conversation.
  });

  tearDownAll(() async {
    if (notes.isNotEmpty) {
      await service.from('release_notes').delete().inFilter('build', notes);
    }
    await wynn.dispose();
    await service.dispose();
  });

  Finder byKey(String key) => find.byKey(ValueKey(key));

  Future<void> until(
    WidgetTester t,
    Future<bool> Function() ok,
    String what,
  ) async {
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      if (await t.runAsync(ok) ?? false) return;
    }
    fail('never happened: $what');
  }

  Future<void> settle(WidgetTester t, {int steps = 20}) async {
    for (var i = 0; i < steps; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
  }

  /// SisApp with main.dart's overrides; [delivery] is main.dart's
  /// SupabaseReleaseNotesDelivery, over [deliveryClient] (wynn's own client
  /// unless a test takes the network away from this one connection).
  Widget app({SupabaseClient? deliveryClient}) => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(
        const RuntimeConfig(
          supabaseUrl: _url,
          supabasePublishableKey: _key,
          googleWebClientId: 'c',
        ),
      ),
      // Google sign-in has nothing to run against locally; the session it
      // carries is wynn's real one.
      authRepositoryProvider.overrideWithValue(
        FakeAuth(
          session: true,
          member: Member(userId: uid, displayName: 'Wynn'),
        ),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(wynn)),
      presenceRepositoryProvider.overrideWithValue(
        SupabasePresenceRepository(wynn),
      ),
      profileRepositoryProvider.overrideWithValue(
        SupabaseProfileRepository(wynn),
      ),
      // Push has no device here; it is not the connection under test.
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      releaseNotesDeliveryProvider.overrideWithValue(
        SupabaseReleaseNotesDelivery(deliveryClient ?? wynn),
      ),
    ],
    child: const SisApp(),
  );

  Future<void> unmount(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => wynn.removeAllChannels());
    await t.runAsync(() => wynn.realtime.disconnect());
  }

  testWidgets(
    'a start on a newer build delivers the note, the SIS chat appears in the '
    'list by itself, and it opens read-only',
    (t) async {
      final b = base + 1;
      await note(b, 'wynn note $b');
      installed(b);
      SharedPreferences.setMockInitialValues({});

      await t.pumpWidget(app());
      await until(
        t,
        () async => await delivered('wynn note $b') == 1,
        'the note in the database',
      );
      final id = (await t.runAsync(systemChat))!;
      await until(
        t,
        () async => find
            .descendant(
              of: byKey('conversation-$id'),
              matching: find.text('wynn note $b'),
            )
            .evaluate()
            .isNotEmpty,
        'the SIS chat with the note in the list, without a refresh',
      );
      expect(
        find.descendant(
          of: byKey('conversation-$id'),
          matching: find.text('SIS'),
        ),
        findsOneWidget,
      );
      expect('${await t.runAsync(stored)}', '$b');

      await t.tap(byKey('conversation-$id'));
      await settle(t);
      expect(byKey('composer-system'), findsOneWidget);
      expect(byKey('composer-field'), findsNothing);

      await unmount(t);
      expect(await t.runAsync(() => delivered('wynn note $b')), 1);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  testWidgets(
    'offline at start: the app still opens, nothing is remembered, and the '
    'next start delivers the note once',
    (t) async {
      final b = base + 2;
      await note(b, 'wynn note $b');
      installed(b);
      SharedPreferences.setMockInitialValues({prefKey: base + 1});
      final dead = (await t.runAsync(() => deadButSignedIn(wynn)))!;
      addTearDown(dead.dispose);

      await t.pumpWidget(app(deliveryClient: dead));
      await settle(t);
      expect(find.text('New chat'), findsOneWidget, reason: 'home is open');
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'failures are silent',
      );
      expect('${await t.runAsync(stored)}', '${base + 1}');
      expect(await t.runAsync(() => delivered('wynn note $b')), 0);
      await unmount(t);

      await t.pumpWidget(app());
      await until(
        t,
        () async => await delivered('wynn note $b') == 1,
        'the note delivered on the next start',
      );
      await settle(t, steps: 5);
      expect('${await t.runAsync(stored)}', '$b');

      // A third start on the same build asks for nothing new.
      await unmount(t);
      await t.pumpWidget(app());
      await settle(t);
      expect(await t.runAsync(() => delivered('wynn note $b')), 1);
      await unmount(t);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
