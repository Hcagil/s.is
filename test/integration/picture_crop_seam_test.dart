@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/person_avatar.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';

/// Setting a picture through the crop screen, on the real stack: the whole
/// app as main.dart mounts it, with only the platform pieces faked where
/// main.dart mounts the real ones -- the phone's gallery (GalleryFake at
/// galleryProvider), the other-app chooser (ExternalPickerFake) and the
/// native crop-and-encode (PictureCropperFake at pictureCropperProvider).
/// Everything behind "Use" is real: the profile and conversation-list
/// controllers, SupabaseProfileRepository / SupabaseChatRepository, the
/// avatars bucket and set_group_avatar. What must arrive in the bucket is
/// exactly the square the cropper made, and the app must then show it.
///
/// The native crop (MainActivity.kt `cropPicture`, PickedImageProcessor) is
/// a platform wrapper, verified on a device (docs/ARCHITECTURE.md rule 4);
/// NativePictureCropper's Dart side is covered at its channel boundary in
/// test/features/chat/native_picture_cropper_test.dart.
///
/// Requires a running local Supabase. Uses the seeded deniz (shared with
/// avatar_seam_test, which resets him) and ece (shared with
/// from_app_seam_test and person_picture_seam_test); run with
/// --concurrency=1 like the rest of the suite. deniz ends pictureless, the
/// group made here without a picture.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real, decodable 4x4 JPEG: the avatars bucket takes image/jpeg only.
final _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQY'
  'GBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYa'
  'KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAAR'
  'CAAEAAQDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA'
  'AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
  'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
  'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl'
  '5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA'
  'AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk'
  'NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
  'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
  '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDDooorwT84P//Z',
);

/// The cropper's square, told apart per test by a byte after the JPEG's end.
Uint8List _square(int tag) => Uint8List.fromList([..._jpeg, tag]);

Future<SupabaseClient> _signedIn(String email) async {
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
  expect(await client.rpc('activate_session'), isTrue);
  await client
      .from('profiles')
      .update({'onboarding_done': true})
      .eq('user_id', client.auth.currentUser!.id);
  return client;
}

String _uid(SupabaseClient c) => c.auth.currentUser!.id;

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

/// Google sign-in cannot run locally: the session is the account's real one.
class _AccountAuth implements AuthRepository {
  _AccountAuth(this.client);
  final SupabaseClient client;

  @override
  bool get hasSession => client.auth.currentSession != null;
  @override
  Stream<bool> get signedInChanges => const Stream.empty();
  @override
  Future<Result<void>> signInWithGoogle() async => const Ok(null);
  @override
  Future<Result<bool>> activateSession() async =>
      Ok(await client.rpc('activate_session') as bool);
  @override
  Future<Result<Member>> currentMember() async =>
      Ok(Member(userId: client.auth.currentUser!.id, displayName: 'Crop'));
  @override
  Future<void> signOut() async {}
}

Future<void> _pictureless(SupabaseClient c) async {
  final repo = SupabaseProfileRepository(c);
  final p = _ok(await repo.load(), 'loading the profile');
  if (p.avatarPath case final path?) await repo.removeAvatar(path);
}

void main() {
  // testWidgets installs a binding that answers every HTTP request with 400;
  // this suite talks to a real server.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient aClient, bClient;
  late String groupId;

  setUpAll(() async {
    aClient = await _signedIn('deniz@integration.test');
    bClient = await _signedIn('ece@integration.test');
    await findByTag(aClient, [bClient]);
    await _pictureless(aClient);
    groupId = _ok(
      await SupabaseChatRepository(
        aClient,
      ).startGroupConversation(title: 'crop seam', memberIds: [_uid(bClient)]),
      'the group',
    );
    // A message puts it at the top of ece's long list, on screen.
    _ok(
      await SupabaseChatRepository(
        aClient,
      ).send(id: randomMessageId(), conversationId: groupId, body: 'crop seam'),
      'the first message',
    );
  });

  tearDownAll(() async {
    await _pictureless(aClient);
    await SupabaseChatRepository(aClient).setGroupAvatar(groupId, null);
    await aClient.dispose();
    await bClient.dispose();
  });

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 150; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    fail('never happened: $what');
  }

  Finder byKey(String k) => find.byKey(ValueKey(k));
  bool shows(Finder f) => f.evaluate().isNotEmpty;

  Future<void> tap(WidgetTester t, String k) async {
    await until(t, () => shows(byKey(k)), k);
    await t.ensureVisible(byKey(k));
    await t.pump(const Duration(seconds: 1));
    await t.tap(byKey(k));
  }

  bool useOffered(WidgetTester t) =>
      shows(byKey('crop-use')) &&
      t
              .getSemantics(byKey('crop-use'))
              .getSemanticsData()
              .flagsCollection
              .isEnabled ==
          Tristate.isTrue;

  /// Whether the avatar circle under [site] paints exactly [bytes].
  bool showsPicture(Finder site, Uint8List bytes) {
    final avatar = find.descendant(
      of: site,
      matching: find.byType(PersonAvatar),
      matchRoot: true,
    );
    for (final e
        in find
            .descendant(of: avatar, matching: find.byType(Image))
            .evaluate()) {
      var p = (e.widget as Image).image;
      while (p is ResizeImage) {
        p = p.imageProvider;
      }
      if (p is MemoryImage && listEquals(p.bytes, bytes)) return true;
    }
    return false;
  }

  /// [client]'s whole app, as main.dart mounts it, with the platform
  /// pieces faked.
  Future<({GalleryFake gallery, PictureCropperFake cropper})> mount(
    WidgetTester t,
    SupabaseClient client,
    PictureCropperFake cropper,
  ) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.625;
    addTearDown(t.view.reset);
    final gallery = GalleryFake(photos: const [GalleryPhoto('p1')])
      ..thumbnails['p1'] = photoPng;
    final cache = AttachmentCacheFake();
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(
            const RuntimeConfig(
              supabaseUrl: _url,
              supabasePublishableKey: _key,
              googleWebClientId: 'c',
            ),
          ),
          authRepositoryProvider.overrideWithValue(_AccountAuth(client)),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(client, cache: cache),
          ),
          attachmentCacheProvider.overrideWithValue(cache),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(client),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(client),
          ),
          galleryProvider.overrideWithValue(gallery),
          externalPickerProvider.overrideWithValue(ExternalPickerFake()),
          pictureCropperProvider.overrideWithValue(cropper),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ],
        child: const SisApp(),
      ),
    );
    return (gallery: gallery, cropper: cropper);
  }

  Future<void> unmount(WidgetTester t, SupabaseClient client) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => client.removeAllChannels());
    await t.runAsync(() => client.realtime.disconnect());
    await t.pump(const Duration(seconds: 61));
  }

  /// The badge's sheet -> Choose photo -> the grid's photo -> the crop
  /// screen, ready to use.
  Future<void> chooseAndFrame(WidgetTester t, String badge) async {
    await tap(t, badge);
    await tap(t, 'avatar-library');
    await tap(t, 'sheet-photo-p1');
    await until(t, () => useOffered(t), 'the crop screen offering Use');
    await t.pump(const Duration(seconds: 1));
  }

  testWidgets('Settings > Profile > badge > Choose photo > crop > Use: the '
      'cropper\'s JPEG is stored under profile/<uid>/ and the picture shows', (
    t,
  ) async {
    final profiles = SupabaseProfileRepository(aClient);
    final square = _square(1);
    final app = await mount(t, aClient, PictureCropperFake(output: square));

    await tap(t, 'home-settings');
    await tap(t, 'settings-profile');
    await chooseAndFrame(t, 'profile-avatar-edit');
    expect(app.gallery.cropLoads, ['p1']);
    await t.tap(byKey('crop-use'));

    String? stored;
    for (var i = 0; i < 100 && stored == null; i++) {
      stored = await t.runAsync<String?>(
        () async => _ok(await profiles.load(), 'loading').avatarPath,
      );
      await t.pump(const Duration(milliseconds: 200));
    }

    final crop = app.cropper.calls.single;
    expect(crop.source, photoPng, reason: 'cropped something else');
    expect(stored, startsWith('profile/${_uid(aClient)}/'));
    final bytes = await t.runAsync(
      () => SupabaseChatRepository(aClient).avatarBytes(stored!),
    );
    expect(
      listEquals(_ok(bytes!, 'reading the picture'), square),
      isTrue,
      reason: 'the stored picture is not the cropper\'s square',
    );
    await until(
      t,
      () => showsPicture(byKey('profile-avatar'), square),
      'the new picture on the profile page',
    );
    expect(
      t.widgetList<SisNotice>(find.byType(SisNotice)).any((n) => n.isError),
      isFalse,
    );

    await unmount(t, aClient);
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('a crop that fails stores nothing on the server', (t) async {
    await t.runAsync(() => _pictureless(aClient));
    final profiles = SupabaseProfileRepository(aClient);
    final app = await mount(t, aClient, PictureCropperFake()..fails = true);

    await tap(t, 'home-settings');
    await tap(t, 'settings-profile');
    await chooseAndFrame(t, 'profile-avatar-edit');
    await t.tap(byKey('crop-use'));
    await until(
      t,
      () => t
          .widgetList<SisNotice>(find.byType(SisNotice))
          .any((n) => n.message == 'That photo could not be used.'),
      'the crop failure notice',
    );
    expect(app.cropper.calls, hasLength(1));
    // Nothing to wait for but time: give an upload that should not happen
    // three real seconds to show up.
    String? after;
    for (var i = 0; i < 15 && after == null; i++) {
      after = await t.runAsync<String?>(
        () async => _ok(await profiles.load(), 'loading').avatarPath,
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(after, isNull, reason: 'something was stored');
    final folder = 'profile/${_uid(aClient)}';
    final objects = await t.runAsync(
      () => aClient.storage.from('avatars').list(path: folder),
    );
    expect(objects, isEmpty);
    expect(
      t
          .widgetList<SisNotice>(find.byType(SisNotice))
          .where((n) => n.message == 'Profile picture updated'),
      isEmpty,
    );

    await unmount(t, aClient);
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('a member who did not create the group sets its picture: '
      'badge > crop > Use goes through set_group_avatar, the creator reads '
      'the cropper\'s square, and the page shows it', (t) async {
    final square = _square(2);
    final app = await mount(t, bClient, PictureCropperFake(output: square));

    await tap(t, 'conversation-$groupId');
    await tap(t, 'conversation-title');
    await chooseAndFrame(t, 'group-avatar-edit');
    await t.tap(byKey('crop-use'));

    final creator = SupabaseChatRepository(aClient);
    String? stored;
    for (var i = 0; i < 100 && stored == null; i++) {
      stored = await t.runAsync<String?>(() async {
        final all = _ok(await creator.conversations(), 'the list');
        return all.singleWhere((c) => c.id == groupId).avatarPath;
      });
      await t.pump(const Duration(milliseconds: 200));
    }

    expect(app.cropper.calls.single.source, photoPng);
    expect(stored, startsWith('group/$groupId/'));
    final bytes = await t.runAsync(() => creator.avatarBytes(stored!));
    expect(
      listEquals(_ok(bytes!, 'reading the group picture'), square),
      isTrue,
      reason: 'the stored group picture is not the cropper\'s square',
    );
    await until(
      t,
      () => showsPicture(byKey('group-avatar'), square),
      'the new picture on the group page',
    );

    await unmount(t, bClient);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
