// The phone's photo and picture cache is emptied whenever the session ends --
// signed out from anywhere, or Denied because the member's phone was replaced
// -- not only by the Settings sign-out button. And never while the member is
// still signed in: a cache emptied on every start would download everything
// again.
//
// Mounted as main.dart mounts it (SisApp, the real session controller and
// gate) with the real on-disk cache, FileAttachmentCache, over a temporary
// directory. Only the Google sign-in and the network repositories are fakes.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/file_attachment_cache.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';
import '../support/video_fakes.dart';

const ava = Member(userId: 'u1', displayName: 'Ava');
const picture = 'profile/ub/1.jpg';
const photo = 'c1/1.png';

late Directory root;
late FileAttachmentCache cache;

Widget app(FakeAuth auth) => ProviderScope(
  overrides: [
    ...videoOverrides(),
    runtimeConfigProvider.overrideWithValue(
      const RuntimeConfig(
        supabaseUrl: 'https://x.supabase.co',
        supabasePublishableKey: 'k',
        googleWebClientId: 'c',
      ),
    ),
    authRepositoryProvider.overrideWithValue(auth),
    updateRepositoryProvider.overrideWithValue(FakeUpdate()),
    chatRepositoryProvider.overrideWithValue(FakeChat()),
    presenceRepositoryProvider.overrideWithValue(PresenceFake()),
    profileRepositoryProvider.overrideWithValue(
      ProfileFake(
        profile: const OwnProfile(
          userId: 'u1',
          displayName: 'Ava',
          tag: 'ava',
          onboardingDone: true,
        ),
      ),
    ),
    pushSourceProvider.overrideWithValue(PushSourceFake()),
    pushRegistryProvider.overrideWithValue(PushRegistryFake()),
    attachmentCacheProvider.overrideWithValue(cache),
  ],
  child: const SisApp(),
);

/// Real disk work runs outside the test's fake clock.
Future<T?> disk<T>(WidgetTester t, Future<T> Function() f) => t.runAsync(f);

Future<void> settle(WidgetTester t) async {
  await t.pumpAndSettle();
  await disk(t, () => Future<void>.delayed(const Duration(milliseconds: 200)));
  await t.pumpAndSettle();
}

Future<bool> kept(WidgetTester t, String path) async =>
    await disk(t, () => cache.read(path)) != null;

/// The session-end clear runs on the real disk after the app reacts, so how
/// long it takes depends on the machine (a busy CI disk can exceed any fixed
/// wait). Poll until the entry is gone, bounded at about 5 s, pumping between
/// tries so the app's pending work can continue.
Future<bool> gone(WidgetTester t, String path) async {
  for (var i = 0; i < 100; i++) {
    if (!await kept(t, path)) return true;
    await disk(t, () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
  }
  return false;
}

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sis-cache');
    cache = FileAttachmentCache(root: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> seed(WidgetTester t) => disk(t, () async {
    await cache.write(picture, Uint8List.fromList([1, 2, 3]));
    await cache.write(photo, Uint8List.fromList([4, 5, 6]));
  });

  testWidgets('control: a signed-in member starting the app keeps the cache', (
    t,
  ) async {
    await seed(t);
    await t.pumpWidget(app(FakeAuth(session: true, member: ava)));
    await settle(t);
    expect(find.text('New chat'), findsOneWidget, reason: 'home did not open');
    expect(await kept(t, picture), isTrue, reason: 'emptied while signed in');
    expect(await kept(t, photo), isTrue);
  });

  testWidgets('the session ending outside the Settings button (e.g. expired '
      'or ended elsewhere) empties the cache', (t) async {
    await seed(t);
    final auth = FakeAuth(session: true, member: ava);
    await t.pumpWidget(app(auth));
    await settle(t);
    expect(await kept(t, picture), isTrue);

    auth.session = false;
    auth.changes.add(false);
    await settle(t);

    expect(auth.signOuts, 0, reason: 'nobody pressed sign out');
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(await gone(t, picture), isTrue, reason: 'a picture survived');
    expect(await gone(t, photo), isTrue, reason: 'a photo survived');
  });

  testWidgets('a phone replaced by another (Denied on start) empties the '
      'cache before anyone taps Sign out', (t) async {
    await seed(t);
    final auth = FakeAuth(session: true, member: ava)..allowed = false;
    await t.pumpWidget(app(auth));
    await settle(t);

    expect(find.textContaining('not currently approved'), findsOneWidget);
    expect(auth.signOuts, 0);
    expect(await gone(t, picture), isTrue, reason: 'a picture survived');
    expect(await gone(t, photo), isTrue, reason: 'a photo survived');
  });

  testWidgets('starting signed out empties what an earlier member left', (
    t,
  ) async {
    await seed(t);
    await t.pumpWidget(app(FakeAuth()));
    await settle(t);

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(await gone(t, picture), isTrue);
  });
}
