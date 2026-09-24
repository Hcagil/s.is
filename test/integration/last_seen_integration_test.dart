@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Last seen against the real stack: [SupabasePresenceRepository]'s two RPCs,
/// [SupabaseProfileRepository]'s share_last_seen column, and the REAL
/// providers wired as `main.dart` wires them, over two signed-in clients.
///
/// The unit tests prove the providers and screens react to what a fake says.
/// Only this suite shows the RPC names and parameters are the database's, a
/// timestamptz comes back as the right instant, and that the server — not the
/// app — makes last seen mutual and forgets a hidden member.
///
/// lars is the member who is seen, mona the one who looks (supabase/seed.sql);
/// the stranger signs up here and is never allowlisted.
///
/// Run it under TZ=JST-9 as well as UTC: a timestamptz parsed without its
/// offset is only wrong where local time is not UTC.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A host that accepts nothing: the honest form of "the connection failed".
const _deadUrl = 'http://127.0.0.1:1';

SupabaseClient _client([String url = _url]) => SupabaseClient(
  url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

/// The offline message, never the raw SDK error that produced it.
void expectOffline(String message) {
  expect(message, offlineMessage);
  for (final needle in [
    'Exception',
    'statusCode',
    'errno',
    'Failed host lookup',
  ]) {
    expect(
      message,
      isNot(contains(needle)),
      reason: 'raw error text reached the screen: $message',
    );
  }
}

Future<SupabaseClient> _signIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  return client;
}

Future<SupabaseClient> _signedIn(String email) async {
  final client = await _signIn(email);
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out after $timeout: $reason');
}

/// Within a minute of this machine's clock. The database runs on the same
/// host; an answer hours off is a time zone read wrong, not clock skew.
Matcher aboutNow() => predicate<DateTime?>(
  (t) =>
      t != null &&
      DateTime.now().difference(t).abs() < const Duration(minutes: 1),
  'within a minute of now',
);

DateTime? okValue(Result<DateTime?> r) {
  expect(r, isA<Ok<DateTime?>>(), reason: r is Err ? '$r' : '');
  return (r as Ok<DateTime?>).value;
}

class Account {
  Account(this.client);
  final SupabaseClient client;
  String get id => client.auth.currentUser!.id;
  SupabasePresenceRepository get presence => SupabasePresenceRepository(client);
  SupabaseProfileRepository get profile => SupabaseProfileRepository(client);
  final _containers = <ProviderContainer>[];

  /// The overrides `main.dart` installs, over this account's client.
  ProviderContainer container() {
    final c = ProviderContainer.test(
      overrides: [
        presenceRepositoryProvider.overrideWithValue(presence),
        profileRepositoryProvider.overrideWithValue(profile),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
      ],
    );
    c.listen(ownProfileProvider, (_, _) {});
    _containers.add(c);
    return c;
  }

  Future<void> shareLastSeen(bool on) async {
    final r = await profile.save(shareLastSeen: on);
    expect(r, isA<Ok<OwnProfile>>(), reason: 'could not set last seen: $r');
  }

  /// Nothing stored: off forgets, on again starts from null.
  Future<void> forget() async {
    await shareLastSeen(false);
    await shareLastSeen(true);
  }

  Future<void> reset() async {
    for (final c in _containers) {
      c.dispose();
    }
    _containers.clear();
    await client.removeAllChannels();
    await profile.save(
      sharePresence: true,
      shareTyping: true,
      shareLastSeen: true,
    );
  }
}

void main() {
  // Integration tests reach the network: flutter_test answers every HTTP
  // request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Account lars;
  late Account mona;
  final extra = <SupabaseClient>[];

  setUpAll(() async {
    lars = Account(await _signedIn('lars@integration.test'));
    mona = Account(await _signedIn('mona@integration.test'));
  });

  setUp(() async {
    await lars.reset();
    await mona.reset();
    await lars.forget();
  });

  tearDown(() async {
    await lars.reset();
    await mona.reset();
    for (final c in extra) {
      await c.removeAllChannels();
      await c.dispose();
    }
    extra.clear();
  });

  tearDownAll(() async {
    await lars.client.dispose();
    await mona.client.dispose();
  });

  group('SupabasePresenceRepository', () {
    test('a touch is what another member reads, as the same instant', () async {
      expect(
        okValue(await mona.presence.lastSeenOf(lars.id)),
        isNull,
        reason: 'setUp should have left lars with no time',
      );

      final touched = await lars.presence.touchLastSeen();
      expect(touched, isA<Ok<void>>(), reason: '$touched');

      final seen = okValue(await mona.presence.lastSeenOf(lars.id));
      expect(seen, aboutNow());

      // The very value the RPC returned, parsed with its offset.
      final raw = await mona.client.rpc(
        'last_seen_of',
        params: {'person': lars.id},
      );
      expect(raw, isA<String>());
      expect(
        seen!.isAtSameMomentAs(DateTime.parse(raw as String)),
        isTrue,
        reason: 'repository says $seen, the server said $raw',
      );
    });

    test('a later touch moves the time forward', () async {
      await lars.presence.touchLastSeen();
      final first = okValue(await mona.presence.lastSeenOf(lars.id))!;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await lars.presence.touchLastSeen();
      final second = okValue(await mona.presence.lastSeenOf(lars.id))!;
      expect(second.isAfter(first), isTrue, reason: '$first then $second');
    });

    test('someone the server has no time for is null', () async {
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), isNull);
      expect(
        okValue(
          await mona.presence.lastSeenOf(
            '00000000-0000-0000-0000-00000000dead',
          ),
        ),
        isNull,
      );
    });

    test('mutual: while mona hides hers she sees nobody\'s, and lars\'s '
        'time is still there when she shows it again', () async {
      await lars.presence.touchLastSeen();
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());

      await mona.shareLastSeen(false);
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), isNull);

      await mona.shareLastSeen(true);
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());
    });

    test('lars hiding his forgets it; showing it again does not bring it '
        'back, the next touch does', () async {
      await lars.presence.touchLastSeen();
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());

      await lars.shareLastSeen(false);
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), isNull);

      final ignored = await lars.presence.touchLastSeen();
      expect(
        ignored,
        isA<Ok<void>>(),
        reason: 'a hidden touch is not an error',
      );
      await lars.shareLastSeen(true);
      expect(
        okValue(await mona.presence.lastSeenOf(lars.id)),
        isNull,
        reason: 'the time came back, or the hidden touch was stored',
      );

      await lars.presence.touchLastSeen();
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());
    });

    test('mona cannot hide lars, nor erase his time', () async {
      await lars.presence.touchLastSeen();
      final rows = await mona.client
          .from('profiles')
          .update({'share_last_seen': false})
          .eq('user_id', lars.id)
          .select();
      expect(rows, isEmpty, reason: 'mona changed lars\'s profile');
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());
      expect(
        (await lars.profile.load() as Ok<OwnProfile>).value.shareLastSeen,
        isTrue,
      );
    });

    test('the table is not reachable over the API at all', () async {
      await lars.presence.touchLastSeen();
      await expectLater(
        mona.client.schema('app_private').from('last_seen').select(),
        throwsA(isA<PostgrestException>()),
      );
    });

    test(
      'a signed-in stranger: the touch is refused, and he sees nobody',
      () async {
        await lars.presence.touchLastSeen();
        final stranger = await _signIn('stranger-lastseen@integration.test');
        extra.add(stranger);
        expect(
          await stranger.rpc('activate_session'),
          isFalse,
          reason: 'the stranger fixture must not be allowlisted',
        );
        final repo = SupabasePresenceRepository(stranger);

        final touched = await repo.touchLastSeen();
        expect(touched, isA<Err<void>>());
        expect((touched as Err<void>).failure.message, isNotEmpty);
        expect(okValue(await repo.lastSeenOf(lars.id)), isNull);
        expect(
          okValue(
            await mona.presence.lastSeenOf(stranger.auth.currentUser!.id),
          ),
          isNull,
        );
      },
    );

    test('anon: neither call reveals or records anything', () async {
      await lars.presence.touchLastSeen();
      final anon = _client();
      extra.add(anon);
      final repo = SupabasePresenceRepository(anon);

      expect(await repo.touchLastSeen(), isA<Err<void>>());
      final seen = await repo.lastSeenOf(lars.id);
      expect(
        seen,
        anyOf(
          isA<Err<DateTime?>>(),
          isA<Ok<DateTime?>>().having((r) => r.value, 'value', isNull),
        ),
        reason: 'anon learned when lars was last seen',
      );
    });

    test('a broken connection fails both calls instead of throwing', () async {
      final dead = _client(_deadUrl);
      extra.add(dead);
      final repo = SupabasePresenceRepository(dead);
      final touched = await repo.touchLastSeen();
      expect(touched, isA<Err<void>>());
      expectOffline((touched as Err<void>).failure.message);
      final seen = await repo.lastSeenOf(lars.id);
      expect(seen, isA<Err<DateTime?>>());
      expectOffline((seen as Err<DateTime?>).failure.message);
    });
  });

  group('SupabaseProfileRepository', () {
    test('share_last_seen round-trips on its own', () async {
      final before = (await mona.profile.load() as Ok<OwnProfile>).value;
      expect(before.shareLastSeen, isTrue);

      final off = await mona.profile.save(shareLastSeen: false);
      expect((off as Ok<OwnProfile>).value.shareLastSeen, isFalse);
      final reloaded = (await mona.profile.load() as Ok<OwnProfile>).value;
      expect(reloaded.shareLastSeen, isFalse);
      expect(
        (
          reloaded.sharePresence,
          reloaded.shareTyping,
          reloaded.displayName,
          reloaded.tag,
        ),
        (
          before.sharePresence,
          before.shareTyping,
          before.displayName,
          before.tag,
        ),
        reason: 'saving last seen changed another field',
      );

      final on = await mona.profile.save(shareLastSeen: true);
      expect((on as Ok<OwnProfile>).value.shareLastSeen, isTrue);
      expect(
        (await mona.profile.load() as Ok<OwnProfile>).value.shareLastSeen,
        isTrue,
      );
    });

    test('saving another field leaves share_last_seen alone', () async {
      await mona.shareLastSeen(false);
      final r = await mona.profile.save(shareTyping: false);
      expect((r as Ok<OwnProfile>).value.shareLastSeen, isFalse);
      expect(
        (await mona.profile.load() as Ok<OwnProfile>).value.shareLastSeen,
        isFalse,
      );
    });
  });

  group('through the real providers', () {
    test('lars is reported seen and leaves; mona\'s lastSeenProvider picks it '
        'up, follows her own switch, and loses him when he hides', () async {
      // Both apps are open: lars announces himself, mona watches his header.
      final l = lars.container();
      l.listen(onlineMembersProvider, (_, _) {});
      final m = mona.container();
      m.listen(lastSeenProvider(lars.id), (_, _) {});
      m.listen(onlineMembersProvider, (_, _) {});
      await eventually(
        () => m.read(onlineMembersProvider),
        (s) => s.contains(lars.id),
        reason: 'mona never saw lars online',
      );

      // Lars's app reports him seen and closes.
      await l.read(lastSeenReporterProvider)();
      l.dispose();
      final seen = await eventually(
        () => m.read(lastSeenProvider(lars.id)).value,
        (t) => t != null,
        reason: 'lars went offline and mona never got his last seen',
      );
      expect(seen, aboutNow());

      // Mona hides her own: last seen is mutual.
      final off = await m
          .read(ownProfileProvider.notifier)
          .setSharing(lastSeen: false);
      expect(off, isA<Ok<OwnProfile>>());
      await eventually(
        () => m.read(lastSeenProvider(lars.id)),
        (s) => s.hasValue && s.value == null && !s.isLoading,
        reason: 'mona hid hers and still sees lars\'s',
      );

      await m.read(ownProfileProvider.notifier).setSharing(lastSeen: true);
      await eventually(
        () => m.read(lastSeenProvider(lars.id)).value,
        (t) => t != null && t.isAtSameMomentAs(seen!),
        reason: 'mona showed hers again and lars\'s time did not come back',
      );

      // Lars opens the app again, hides his last seen, and closes it.
      final l2 = lars.container();
      l2.listen(onlineMembersProvider, (_, _) {});
      await eventually(
        () => m.read(onlineMembersProvider),
        (s) => s.contains(lars.id),
        reason: 'mona never saw lars come back',
      );
      final hidden = await l2
          .read(ownProfileProvider.notifier)
          .setSharing(lastSeen: false);
      expect(hidden, isA<Ok<OwnProfile>>());
      l2.dispose();
      await eventually(
        () => m.read(lastSeenProvider(lars.id)),
        (s) => s.hasValue && s.value == null && !s.isLoading,
        reason: 'lars hid his last seen and mona still sees it',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the reporter over the real repository: a hidden member is not '
        'recorded, a shown one is', () async {
      final l = lars.container();
      await l.read(ownProfileProvider.future);
      await l.read(ownProfileProvider.notifier).setSharing(lastSeen: false);
      await l.read(lastSeenReporterProvider)();
      await l.read(ownProfileProvider.notifier).setSharing(lastSeen: true);
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), isNull);

      await l.read(lastSeenReporterProvider)();
      expect(okValue(await mona.presence.lastSeenOf(lars.id)), aboutNow());
    });

    test('the presence connection broken: the provider settles on null and '
        'the reporter does not throw', () async {
      // Only the presence repository's connection is dead; the profile is
      // real, so the failure under test is this seam and nothing upstream.
      final dead = _client(_deadUrl);
      extra.add(dead);
      final c = ProviderContainer.test(
        overrides: [
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(dead),
          ),
          profileRepositoryProvider.overrideWithValue(mona.profile),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(mona.client),
          ),
        ],
      );
      addTearDown(c.dispose);
      await lars.presence.touchLastSeen();
      c.listen(ownProfileProvider, (_, _) {});
      c.listen(lastSeenProvider(lars.id), (_, _) {});
      final s = await eventually(
        () => c.read(lastSeenProvider(lars.id)),
        (s) => !s.isLoading,
        reason: 'last seen never settled over a dead connection',
      );
      expect(s.hasError, isFalse, reason: 'a failure surfaced: ${s.error}');
      expect(s.value, isNull);
      await expectLater(c.read(lastSeenReporterProvider)(), completes);
    });
  });
}
