@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/notifications/data/supabase_notification_settings_repository.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [SupabaseNotificationSettingsRepository] against a real local Supabase:
/// query shaping and row-level security over `notification_settings` and
/// `notification_mutes` (supabase/migrations/20260924120000_notification_settings.sql).
/// The unit tests prove the controllers over a fake; they cannot prove the
/// column names, the upsert conflict target, or that a mute naming a
/// conversation the caller is not in is refused by the database rather than
/// by the client.
///
/// Requires `docker compose run --rm supabase start`. Reuses cleo, ann and
/// ines (supabase/seed.sql; cleo and ann also used by
/// conversation_list_screen_seam_test.dart and
/// chat_repository_test.dart/realtime_warmup_test.dart, ines by
/// profile_pages_integration_test.dart): signing in claims the active
/// device, so run with --concurrency=1 like the rest of the suite.
///
/// `authenticated` has no delete grant on `notification_settings`
/// (deliberately: the app never deletes this row, only upserts it), so a
/// row this suite saves stays saved across reruns. The "defaults" test below
/// therefore never saves for ines, and never will: she exists only to prove
/// what an account that has never saved reads back as.
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

String _uid(SupabaseClient c) => c.auth.currentUser!.id;

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

/// A random id that is neither a real conversation nor a real account: the
/// honest form of "not a member" / "not allowlisted" that needs no fixture.
/// A well-formed (if not strictly version-4) uuid: Postgres rejects a
/// malformed one with 22P02 before RLS is ever consulted, which is not the
/// refusal under test here.
final _random = Random();
String _randomId() {
  String hex(int digits) => List.generate(
    digits,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();
  return '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? cleoClient, annClient, inesClient, anonClient;
  late SupabaseNotificationSettingsRepository cleo;
  late SupabaseNotificationSettingsRepository ann;
  late SupabaseNotificationSettingsRepository ines;
  late SupabaseNotificationSettingsRepository signedOut;
  late String cleoId, annId;
  late String sharedConversation;

  setUpAll(() async {
    cleoClient = await _signedIn('cleo@integration.test');
    annClient = await _signedIn('ann@integration.test');
    inesClient = await _signedIn('ines@integration.test');
    // Reaches the real, reachable server, but carries no session: the
    // `anon` role every table here has `revoke all` from.
    anonClient = _client(_url);
    cleo = SupabaseNotificationSettingsRepository(cleoClient!);
    ann = SupabaseNotificationSettingsRepository(annClient!);
    ines = SupabaseNotificationSettingsRepository(inesClient!);
    signedOut = SupabaseNotificationSettingsRepository(anonClient!);
    cleoId = _uid(cleoClient!);
    annId = _uid(annClient!);

    // A conversation cleo is really a member of, for the "in it" mute case.
    sharedConversation = _ok(
      await SupabaseChatRepository(cleoClient!).startDirectConversation(annId),
      'starting a conversation',
    );

    // Mutes may be cleared between runs (`authenticated` holds delete on
    // `notification_mutes`); settings may not (see the note above).
    await cleoClient!.from('notification_mutes').delete().eq('user_id', cleoId);
    await annClient!.from('notification_mutes').delete().eq('user_id', annId);
  });

  tearDownAll(() async {
    await cleoClient?.dispose();
    await annClient?.dispose();
    await inesClient?.dispose();
    await anonClient?.dispose();
  });

  group('settings', () {
    test('nothing saved yet reads as the defaults', () async {
      final settings = _ok(await ines.load(), 'load');
      expect(settings, const NotificationSettings());
    });

    test('save then load round-trips, and a second save replaces it (the '
        'upsert does not conflict on the row already existing)', () async {
      _ok(
        await cleo.save(
          const NotificationSettings(
            enabled: false,
            preview: NotificationPreview.sender,
          ),
        ),
        'first save',
      );
      expect(
        _ok(await cleo.load(), 'load after first save'),
        const NotificationSettings(
          enabled: false,
          preview: NotificationPreview.sender,
        ),
      );

      _ok(
        await cleo.save(
          const NotificationSettings(
            enabled: true,
            preview: NotificationPreview.none,
          ),
        ),
        'second save',
      );
      expect(
        _ok(await cleo.load(), 'load after second save'),
        const NotificationSettings(
          enabled: true,
          preview: NotificationPreview.none,
        ),
      );
    });

    test('one account\'s settings are private to it', () async {
      await cleo.save(
        const NotificationSettings(
          enabled: false,
          preview: NotificationPreview.none,
        ),
      );
      await ann.save(const NotificationSettings());
      final cleoNow = _ok(await cleo.load(), 'cleo load');
      final annNow = _ok(await ann.load(), 'ann load');
      expect(cleoNow.enabled, isFalse);
      expect(annNow, const NotificationSettings());
    });
  });

  group('mutes', () {
    test('muting a conversation the member is in works, and shows up in '
        'mutes()', () async {
      final result = await cleo.mute(
        MuteKind.conversation,
        sharedConversation,
        null,
      );
      expect(result, isA<Ok<void>>(), reason: reasonOf(result));
      final mutes = _ok(await cleo.mutes(), 'mutes');
      final row = mutes.firstWhere((m) => m.target == sharedConversation);
      expect(row.kind, MuteKind.conversation);
      expect(row.until, isNull);
    });

    test(
      'muting a conversation the member is NOT in is refused as DeniedFailure',
      () async {
        final result = await cleo.mute(
          MuteKind.conversation,
          _randomId(),
          null,
        );
        expect(result, isA<Err<void>>());
        expect(
          (result as Err<void>).failure,
          isA<DeniedFailure>(),
          reason:
              'a mute row must not become a way to probe ids (see the '
              'migration\'s policy comment): a refused mute must read the '
              'same, "Not allowed", whether the target does not exist, is '
              'not a member, or is not allowlisted',
        );
      },
    );

    test('muting another allowlisted person works', () async {
      final result = await cleo.mute(MuteKind.person, annId, null);
      expect(result, isA<Ok<void>>(), reason: reasonOf(result));
      final mutes = _ok(await cleo.mutes(), 'mutes');
      expect(
        mutes.where((m) => m.kind == MuteKind.person && m.target == annId),
        hasLength(1),
      );
    });

    test('muting yourself as a person is refused', () async {
      final result = await cleo.mute(MuteKind.person, cleoId, null);
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
    });

    test('muting someone not allowlisted is refused', () async {
      final result = await cleo.mute(MuteKind.person, _randomId(), null);
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
    });

    test(
      're-muting the same target replaces the until, not a second row',
      () async {
        final until = DateTime.now().add(const Duration(hours: 8)).toUtc();
        await cleo.mute(MuteKind.person, annId, until);
        var mutes = _ok(await cleo.mutes(), 'mutes after first mute');
        expect(
          mutes.where((m) => m.kind == MuteKind.person && m.target == annId),
          hasLength(1),
        );

        await cleo.mute(MuteKind.person, annId, null); // now "always"
        mutes = _ok(await cleo.mutes(), 'mutes after re-mute');
        final rows = mutes
            .where((m) => m.kind == MuteKind.person && m.target == annId)
            .toList();
        expect(rows, hasLength(1), reason: 're-muting must replace, not add');
        expect(rows.single.until, isNull);
      },
    );

    test('unmute removes the row', () async {
      await cleo.mute(MuteKind.person, annId, null);
      expect(
        _ok(
          await cleo.mutes(),
          'mutes',
        ).any((m) => m.kind == MuteKind.person && m.target == annId),
        isTrue,
        reason: 'setup',
      );

      final result = await cleo.unmute(MuteKind.person, annId);
      expect(result, isA<Ok<void>>(), reason: reasonOf(result));
      expect(
        _ok(
          await cleo.mutes(),
          'mutes after unmute',
        ).any((m) => m.kind == MuteKind.person && m.target == annId),
        isFalse,
      );
    });

    test('one account\'s mutes are private to it', () async {
      await cleo.mute(MuteKind.person, annId, null);
      final annMutes = _ok(await ann.mutes(), 'ann mutes');
      expect(
        annMutes.where((m) => m.kind == MuteKind.person && m.target == annId),
        isEmpty,
        reason: 'ann must not see cleo\'s mute naming her',
      );
    });
  });

  group('signed out', () {
    test('load, save, mutes, mute and unmute all answer DeniedFailure, '
        'never a throw', () async {
      expect(
        ((await signedOut.load()) as Err<NotificationSettings>).failure,
        isA<DeniedFailure>(),
      );
      expect(
        ((await signedOut.save(
          const NotificationSettings(),
        )) as Err<void>).failure,
        isA<DeniedFailure>(),
      );
      expect(
        ((await signedOut.mutes()) as Err<List<Mute>>).failure,
        isA<DeniedFailure>(),
      );
      expect(
        ((await signedOut.mute(
          MuteKind.person,
          annId,
          null,
        )) as Err<void>).failure,
        isA<DeniedFailure>(),
      );
      expect(
        ((await signedOut.unmute(MuteKind.person, annId)) as Err<void>).failure,
        isA<DeniedFailure>(),
      );
    });
  });
}

String reasonOf<T>(Result<T> r) => r is Err<T> ? r.failure.message : '';
