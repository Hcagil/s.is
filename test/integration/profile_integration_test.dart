@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/presentation/onboarding_screen.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/dead_host.dart';

/// Tags, names and onboarding through the real stack.
///
/// The unit and widget tests prove the controller and screens behave over a
/// fake repository. They cannot prove that the repository's columns and RPC
/// are the database's, that the unique index — not the availability check —
/// settles two members claiming one tag at once, or that what one member saves
/// is what another reads. Every provider here is wired as `main.dart` wires
/// it: [SupabaseProfileRepository] and [SupabaseChatRepository] over a client
/// signed in to a running local Supabase.
///
/// Also carries the rename coverage that lived in the group chat suite before
/// renaming moved out of the chat feature.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (vera, walt, xena): signing in claims the active device.
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

Future<SupabaseClient> signedIn(String email) async {
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

class Account {
  Account(this.client);
  final SupabaseClient client;
  String get userId => client.auth.currentUser!.id;

  /// The overrides `main.dart` installs, over this account's client.
  List<Override> get overrides => [
    profileRepositoryProvider.overrideWithValue(
      SupabaseProfileRepository(client),
    ),
    chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(client)),
  ];

  ProviderContainer container() {
    final c = ProviderContainer.test(overrides: overrides);
    c.listen(ownProfileProvider, (_, _) {});
    return c;
  }

  /// The profile as the database holds it now, through a fresh controller.
  Future<OwnProfile> reload() => container().read(ownProfileProvider.future);
}

/// A tag nobody holds: 3..20, starts with a letter.
String freshTag(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

String reasonOf<T>(Result<T> r) => r is Err<T> ? r.failure.message : '';

void main() {
  // Integration tests reach the network: flutter_test answers every HTTP
  // request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? veraClient;
  SupabaseClient? waltClient;
  SupabaseClient? xenaClient;
  SupabaseClient? deadClient;
  late Account vera;
  late Account walt;
  late Account xena;
  late Account offline;

  setUpAll(() async {
    veraClient = await signedIn('vera@integration.test');
    waltClient = await signedIn('walt@integration.test');
    xenaClient = await signedIn('xena@integration.test');
    deadClient = await deadButSignedIn(veraClient!);
    vera = Account(veraClient!);
    walt = Account(waltClient!);
    xena = Account(xenaClient!);
    offline = Account(deadClient!);
  });

  tearDownAll(() async {
    await veraClient?.dispose();
    await waltClient?.dispose();
    await xenaClient?.dispose();
    await deadClient?.dispose();
  });

  test('a member loads their own profile with a generated tag', () async {
    final p = await vera.reload();
    expect(p.userId, vera.userId);
    expect(p.displayName, isNotEmpty);
    expect(
      p.tag,
      matches(dbTagPattern),
      reason: 'sign-up did not give a well-formed tag',
    );
  });

  test('a member changes their tag; it sticks and is no longer free for '
      'anyone else', () async {
    final tag = freshTag('vt');
    final c = vera.container();
    await c.read(ownProfileProvider.future);

    final result = await c.read(ownProfileProvider.notifier).save(tag: tag);
    expect(result, isA<Ok<OwnProfile>>(), reason: reasonOf(result));
    expect(c.read(ownProfileProvider).requireValue.tag, tag);
    expect((await vera.reload()).tag, tag, reason: 'the save did not persist');

    final w = walt.container();
    await w.read(ownProfileProvider.future);
    final forWalt = await w.read(ownProfileProvider.notifier).checkTag(tag);
    expect(forWalt, isA<Ok<bool>>(), reason: reasonOf(forWalt));
    expect((forWalt as Ok<bool>).value, isFalse);

    final forVera = await c.read(ownProfileProvider.notifier).checkTag(tag);
    expect(
      (forVera as Ok<bool>).value,
      isTrue,
      reason: 'a member\'s own tag must count as available',
    );
  });

  test('availability: another member\'s current tag is taken, a new one is '
      'free, a malformed one is not', () async {
    final waltTag = (await walt.reload()).tag;
    final c = vera.container();
    await c.read(ownProfileProvider.future);
    final check = c.read(ownProfileProvider.notifier).checkTag;

    expect(((await check(waltTag)) as Ok<bool>).value, isFalse);
    expect(((await check(freshTag('free'))) as Ok<bool>).value, isTrue);
    expect(((await check('ab')) as Ok<bool>).value, isFalse);
  });

  test('two members claim one tag at once: one wins, the other gets the '
      'reason and keeps their tag', () async {
    final tag = freshTag('race');
    final v = vera.container();
    final w = walt.container();
    final before = (
      vera: (await v.read(ownProfileProvider.future)).tag,
      walt: (await w.read(ownProfileProvider.future)).tag,
    );

    // Both checks pass: the tag is free when each of them asks.
    expect(
      ((await v.read(ownProfileProvider.notifier).checkTag(tag)) as Ok<bool>)
          .value,
      isTrue,
    );
    expect(
      ((await w.read(ownProfileProvider.notifier).checkTag(tag)) as Ok<bool>)
          .value,
      isTrue,
    );

    final results = await Future.wait([
      v.read(ownProfileProvider.notifier).save(tag: tag),
      w.read(ownProfileProvider.notifier).save(tag: tag),
    ]);

    final wins = results.whereType<Ok<OwnProfile>>().toList();
    final losses = results.whereType<Err<OwnProfile>>().toList();
    expect(wins, hasLength(1), reason: 'the unique index let both through');
    expect(losses, hasLength(1));
    final failure = losses.single.failure;
    expect(failure, isA<ProviderFailure>());
    expect(failure.message, isNotEmpty);
    expect(
      failure.message,
      isNot(contains('PostgrestException')),
      reason: 'a raw exception is not a reason',
    );

    final veraWon = results.first is Ok<OwnProfile>;
    final (winner, loser, loserBefore) = veraWon
        ? (vera, w, before.walt)
        : (walt, v, before.vera);
    final loserAccount = veraWon ? walt : vera;
    expect((await winner.reload()).tag, tag);
    expect(
      (await loserAccount.reload()).tag,
      loserBefore,
      reason: 'the loser\'s tag changed anyway',
    );
    final loserState = loser.read(ownProfileProvider);
    expect(loserState.hasError, isFalse, reason: 'a refusal blanked the form');
    expect(loserState.requireValue.tag, loserBefore);
  });

  test(
    'a rename by one member is what another member reads, with the tag',
    () async {
      final name = 'Vera ${DateTime.now().microsecondsSinceEpoch}';
      final c = vera.container();
      await c.read(ownProfileProvider.future);

      final result = await c
          .read(ownProfileProvider.notifier)
          .save(displayName: name);
      expect(result, isA<Ok<OwnProfile>>(), reason: reasonOf(result));
      final veraTag = (result as Ok<OwnProfile>).value.tag;

      final members = await ProviderContainer.test(overrides: xena.overrides)
          .read(membersProvider.future);
      final seen = members.firstWhere(
        (m) => m.userId == vera.userId,
        orElse: () => fail('vera vanished from the member list'),
      );
      expect(
        seen.displayName,
        name,
        reason: 'another member reads the old name',
      );
      expect(seen.tag, veraTag, reason: 'the member list does not carry tags');
    },
  );

  test('an over-long name is refused and changes nothing', () async {
    final before = await vera.reload();
    final c = vera.container();
    await c.read(ownProfileProvider.future);

    final result = await c
        .read(ownProfileProvider.notifier)
        .save(displayName: 'z' * 81, tag: freshTag('long'));

    expect(result, isA<Err<OwnProfile>>());
    expect((result as Err<OwnProfile>).failure.message, isNotEmpty);
    final after = await vera.reload();
    expect(after.displayName, before.displayName);
    expect(after.tag, before.tag, reason: 'half a refused save landed');
  });

  test(
    'completing onboarding persists the flag and keeps name and tag',
    () async {
      await xena.client
          .from('profiles')
          .update({'onboarding_done': false})
          .eq('user_id', xena.userId);
      final before = await xena.reload();
      expect(before.onboardingDone, isFalse);

      final c = xena.container();
      await c.read(ownProfileProvider.future);
      final result = await c
          .read(ownProfileProvider.notifier)
          .completeOnboarding();
      expect(result, isA<Ok<OwnProfile>>(), reason: reasonOf(result));

      final after = await xena.reload();
      expect(after.onboardingDone, isTrue);
      expect(after.displayName, before.displayName);
      expect(after.tag, before.tag);
    },
  );

  test('a member cannot rename, retag or onboard anyone else', () async {
    final before = await walt.reload();

    final rows = await vera.client
        .from('profiles')
        .update({
          'display_name': 'Owned by vera',
          'tag': freshTag('owned'),
          'onboarding_done': !before.onboardingDone,
        })
        .eq('user_id', walt.userId)
        .select();

    expect(rows, isEmpty, reason: 'vera rewrote walt\'s profile');
    final after = await walt.reload();
    expect(
      (after.displayName, after.tag, after.onboardingDone),
      (before.displayName, before.tag, before.onboardingDone),
    );
  });

  test('no column but name, tag and the flag may be written', () async {
    await expectLater(
      vera.client
          .from('profiles')
          .update({'user_id': walt.userId})
          .eq('user_id', vera.userId),
      throwsA(isA<PostgrestException>()),
      reason: 'a member moved their profile to another account',
    );
    await expectLater(
      vera.client
          .from('profiles')
          .update({'created_at': DateTime(2000).toIso8601String()})
          .eq('user_id', vera.userId),
      throwsA(isA<PostgrestException>()),
    );
    expect((await vera.reload()).userId, vera.userId);
  });

  test('a broken connection: the load shows a reason, and save and check '
      'fail rather than answer', () async {
    final c = offline.container();
    await expectLater(c.read(ownProfileProvider.future), throwsA(anything));
    final state = c.read(ownProfileProvider);
    expect(state.hasError, isTrue);
    expect(
      state.error,
      isA<Failure>(),
      reason: 'a raw exception reached state',
    );
    expectOffline((state.error! as Failure).message);

    final repo = SupabaseProfileRepository(offline.client);
    final saved = await repo.save(displayName: 'Never arrives');
    expect(saved, isA<Err<OwnProfile>>());
    expectOffline((saved as Err<OwnProfile>).failure.message);

    final checked = await repo.isTagAvailable('free_tag');
    expect(
      checked,
      isA<Err<bool>>(),
      reason: 'a failed check must not read as "taken" or "free"',
    );
    expectOffline((checked as Err<bool>).failure.message);
  });

  // The session gate as production mounts it, over the real profile
  // repository. Google sign-in and the Play update API have nothing to run
  // against locally, so those two stay fakes; chat is not under test here.
  testWidgets('the gate walks a member who has not onboarded through '
      'onboarding, and skipping is remembered', (t) async {
    await t.runAsync(
      () => xena.client
          .from('profiles')
          .update({'onboarding_done': false})
          .eq('user_id', xena.userId),
    );
    final before = (await t.runAsync(xena.reload))!;
    // No stored last seen, so the one read below can only be this mount's.
    await t.runAsync(() async {
      final repo = SupabaseProfileRepository(xena.client);
      await repo.save(shareLastSeen: false);
      await repo.save(shareLastSeen: true);
    });
    Future<DateTime?> xenaLastSeen() async {
      final r = await t.runAsync(
        () => SupabasePresenceRepository(vera.client).lastSeenOf(xena.userId),
      );
      return (r! as Ok<DateTime?>).value;
    }

    expect(await xenaLastSeen(), isNull);

    Future<void> until(Finder f) async {
      for (var i = 0; i < 100; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
        if (f.evaluate().isNotEmpty) return;
      }
      fail('never appeared: $f');
    }

    Widget app() => ProviderScope(
      overrides: [
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
          SupabaseProfileRepository(xena.client),
        ),
        // main.dart installs it; home reports the member seen through it.
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(xena.client),
        ),
      ],
      child: const SisApp(),
    );

    await t.pumpWidget(app());
    await until(find.byType(OnboardingScreen));
    expect(find.text(before.tag), findsWidgets, reason: 'the generated tag');

    await t.tap(find.byKey(const ValueKey('onboarding-skip')));
    await until(find.text('New chat'));
    // The report is an HTTP call made from the widget's zone; give it real
    // time and frames to land.
    DateTime? seen;
    for (var i = 0; i < 50 && seen == null; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
      seen = await xenaLastSeen();
    }
    expect(
      seen,
      isNotNull,
      reason: 'home opened and never reported the member seen',
    );

    final after = (await t.runAsync(xena.reload))!;
    expect(after.onboardingDone, isTrue, reason: 'the skip was not saved');
    expect(after.tag, before.tag);

    // A fresh start goes straight home: the flag came from the database.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app());
    await until(find.text('New chat'));
    expect(find.byType(OnboardingScreen), findsNothing);

    // dart:io keeps an idle HTTP connection on a 15 s timer that was created
    // inside the test's fake clock; let it run out.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 16));
  });
}
