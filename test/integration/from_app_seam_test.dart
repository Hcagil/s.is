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
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/reach.dart';

/// "From an app" on the real stack. The platform (the other app, reached
/// through Android's chooser) is the only fake: an [ExternalPickerFake] at
/// externalPickerProvider, exactly where main.dart mounts
/// ExternalPickerChannel. Everything behind it is real -- the composer,
/// MessagesController, SupabaseChatRepository, the bucket and the tables for
/// attachments; the whole app, the profile controller and
/// SupabaseProfileRepository for a picture. The failure path of the
/// repository connection is a signed-in client whose host is unreachable.
///
/// The native side (MainActivity.kt: the chooser, the copy, the downscale
/// and re-encode) is a platform wrapper, verified on a device
/// (docs/ARCHITECTURE.md rule 4), not here.
///
/// Requires a running local Supabase. Uses walt and xena (shared with
/// message_screen_seam_test) and ece (shared with person_picture_seam_test);
/// run with --concurrency=1 like the rest of the suite. ece ends
/// pictureless.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real 1x1 PNG; a tag byte after its end tells the copies apart.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
PickedImage _photo(int tag) => PickedImage(
  bytes: Uint8List.fromList([..._png, tag]),
  contentType: 'image/png',
  extension: 'png',
  preview: _png,
);

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
  return client;
}

String _uid(SupabaseClient c) => c.auth.currentUser!.id;

T _ok<T>(Result<T> r, String what) {
  if (r is Err<T>) fail('$what failed: ${r.failure.message}');
  return (r as Ok<T>).value;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
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
      Ok(Member(userId: client.auth.currentUser!.id, displayName: 'Ece'));
  @override
  Future<void> signOut() async {}
}

/// ece with no picture.
Future<void> _pictureless(SupabaseClient ece) async {
  final repo = SupabaseProfileRepository(ece);
  final p = _ok(await repo.load(), 'loading ece');
  if (p.avatarPath case final path?) await repo.removeAvatar(path);
}

void main() {
  // testWidgets installs a binding that answers every HTTP request with 400;
  // this suite talks to a real server.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

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

  /// Taps [k] once it is on screen and any transition has finished.
  Future<void> tapWhenShown(WidgetTester t, String k) async {
    await until(t, () => shows(byKey(k)), k);
    await t.pump(const Duration(seconds: 1));
    await t.tap(byKey(k));
    await t.pump();
  }

  group('attachments: composer -> MessagesController -> real repository', () {
    late SupabaseClient waltClient, xenaClient;
    late SupabaseChatRepository walt;
    late Member xena;
    late String conversationId;

    setUpAll(() async {
      waltClient = await _signedIn('walt@integration.test');
      xenaClient = await _signedIn('xena@integration.test');
      walt = SupabaseChatRepository(waltClient);
      xena = Member(userId: _uid(xenaClient), displayName: 'Xena');
      await findByTag(waltClient, [xenaClient]);
      conversationId = _ok(
        await walt.startDirectConversation(xena.userId),
        'the 1:1',
      );
    });

    tearDownAll(() async {
      await waltClient.dispose();
      await xenaClient.dispose();
    });

    /// Xena's screen over [chatClient], as main.dart wires it; photo access
    /// refused, so only "From an app" can send anything.
    Future<GalleryFake> mount(
      WidgetTester t,
      SupabaseClient chatClient,
      ExternalPickerFake picker,
    ) async {
      t.view.physicalSize = const Size(1080, 2340);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final gallery = GalleryFake(access: GalleryAccess.permanentlyDenied);
      final cache = AttachmentCacheFake();
      final container = ProviderContainer(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuth(session: true, member: xena),
          ),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(chatClient, cache: cache),
          ),
          attachmentCacheProvider.overrideWithValue(cache),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(xenaClient),
          ),
          galleryProvider.overrideWithValue(gallery),
          externalPickerProvider.overrideWithValue(picker),
          sessionControllerProvider.overrideWith(() => _SignedIn(xena)),
        ],
      );
      addTearDown(container.dispose);
      await t.runAsync(() => settled(container));
      container.read(openConversationProvider.notifier).open(conversationId);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: sisTheme(Brightness.light),
            home: const MessageScreen(title: 'Walt'),
          ),
        ),
      );
      await until(t, () => shows(byKey('composer-attach')), 'the composer');
      return gallery;
    }

    Future<Set<String>> ids() async => {
      for (final m in _ok(await walt.messages(conversationId), 'messages'))
        m.id,
    };

    Future<void> unmount(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => xenaClient.removeAllChannels());
      await t.runAsync(() => xenaClient.realtime.disconnect());
      await t.pump(const Duration(seconds: 61));
    }

    testWidgets('photos from an app arrive as real messages, one each, in '
        'order, the caption on the first only', (t) async {
      final before = (await t.runAsync(ids))!;
      final caption = 'from an app ${DateTime.now().microsecondsSinceEpoch}';
      final picker = ExternalPickerFake()
        ..offered = [_photo(1), _photo(2), _photo(3)];
      final gallery = await mount(t, xenaClient, picker);

      await t.enterText(byKey('composer-field'), caption);
      await t.pump();
      await tapWhenShown(t, 'composer-attach');
      await tapWhenShown(t, 'sheet-from-app');
      // 0.30.10: every pick lands on the preview page; its Send sends.
      await tapWhenShown(t, 'preview-send');

      var arrived = <Message>[];
      Future<void> poll() async {
        final all = _ok(await walt.messages(conversationId), 'messages');
        arrived = [
          for (final m in all)
            if (!before.contains(m.id)) m,
        ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }

      for (var i = 0; i < 100 && arrived.length < 3; i++) {
        await t.runAsync(poll);
        await t.pump(const Duration(milliseconds: 200));
      }
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await t.runAsync(poll);

      expect(arrived, hasLength(3), reason: 'one message per photo');
      expect(arrived.map((m) => m.senderId).toSet(), {xena.userId});
      expect([for (final m in arrived) m.body], [caption, '', '']);
      // 0.30.14: previews are read by id, not with the page.
      final previews = _ok(
        (await t.runAsync(
          () => walt.attachmentPreviews([for (final m in arrived) m.id]),
        ))!,
        'previews',
      );
      for (final (i, m) in arrived.indexed) {
        expect(m.attachmentPath, isNotNull);
        expect(previews[m.id], isNotNull, reason: 'photo ${i + 1} preview');
        final bytes = await t.runAsync(
          () => walt.attachmentBytes(m.attachmentPath!),
        );
        expect(
          listEquals(
            _ok(bytes!, 'reading photo ${i + 1}'),
            _photo(i + 1).bytes,
          ),
          isTrue,
          reason: 'photo ${i + 1} is not the one picked in that place',
        );
      }
      expect(gallery.accessRequests, 1, reason: 'only opening the sheet');
      expect(gallery.openSettingsCalls, 0);
      expect(find.byType(SisNotice), findsNothing);

      await unmount(t);
    }, timeout: const Timeout(Duration(seconds: 120)));

    testWidgets('offline, the first send fails: an error notice, nothing '
        'reaches the server, the rest are not tried', (t) async {
      final before = (await t.runAsync(ids))!;
      final dead = (await t.runAsync(() => deadButSignedIn(xenaClient)))!;
      addTearDown(dead.dispose);
      final picker = ExternalPickerFake()..offered = [_photo(4), _photo(5)];
      await mount(t, dead, picker);

      await tapWhenShown(t, 'composer-attach');
      await tapWhenShown(t, 'sheet-from-app');
      // 0.30.10: every pick lands on the preview page; its Send sends.
      await tapWhenShown(t, 'preview-send');
      await until(
        t,
        () => t
            .widgetList<SisNotice>(find.byType(SisNotice))
            .any((n) => n.isError),
        'an error notice',
      );

      final after = (await t.runAsync(ids))!;
      expect(after.difference(before), isEmpty);
      expect(
        find.textContaining('Only the first'),
        findsNothing,
        reason: 'nothing was capped',
      );

      await unmount(t);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group(
    'a picture: the whole app -> profile controller -> real repository',
    () {
      late SupabaseClient eceClient;

      setUpAll(() async {
        eceClient = await _signedIn('ece@integration.test');
        await eceClient
            .from('profiles')
            .update({'onboarding_done': true})
            .eq('user_id', _uid(eceClient));
        await _pictureless(eceClient);
      });

      tearDownAll(() async {
        await _pictureless(eceClient);
        await eceClient.dispose();
      });

      testWidgets('a picture from an app, framed and used on the crop screen, '
          'is stored and becomes the profile\'s picture, with photo access '
          'refused', (t) async {
        t.view.physicalSize = const Size(1080, 2340);
        t.view.devicePixelRatio = 2.625;
        addTearDown(t.view.reset);
        final profiles = SupabaseProfileRepository(eceClient);
        final chat = SupabaseChatRepository(eceClient);
        final gallery = GalleryFake(access: GalleryAccess.denied);
        final picker = ExternalPickerFake()
          ..picture = PickedImage(
            bytes: _jpeg,
            contentType: 'image/jpeg',
            extension: 'jpg',
          );
        final cache = AttachmentCacheFake();
        // The square the crop screen's "Use" makes: a byte after the
        // picked JPEG's end tells it apart from what the other app handed
        // back.
        final cropper = PictureCropperFake(
          output: Uint8List.fromList([..._jpeg, 7]),
        );

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
              authRepositoryProvider.overrideWithValue(_AccountAuth(eceClient)),
              updateRepositoryProvider.overrideWithValue(FakeUpdate()),
              chatRepositoryProvider.overrideWithValue(
                SupabaseChatRepository(eceClient, cache: cache),
              ),
              attachmentCacheProvider.overrideWithValue(cache),
              presenceRepositoryProvider.overrideWithValue(
                SupabasePresenceRepository(eceClient),
              ),
              profileRepositoryProvider.overrideWithValue(profiles),
              galleryProvider.overrideWithValue(gallery),
              externalPickerProvider.overrideWithValue(picker),
              pictureCropperProvider.overrideWithValue(cropper),
              pushSourceProvider.overrideWithValue(PushSourceFake()),
              pushRegistryProvider.overrideWithValue(PushRegistryFake()),
            ],
            child: const SisApp(),
          ),
        );

        Future<void> tap(String k) async {
          await until(t, () => shows(byKey(k)), k);
          await t.ensureVisible(byKey(k));
          await t.pump(const Duration(seconds: 1));
          await t.tap(byKey(k));
        }

        await tap('home-settings');
        await tap('settings-profile');
        await tap('profile-avatar-edit');
        await tap('avatar-library');
        await tap('sheet-from-app');
        await until(
          t,
          () =>
              shows(byKey('crop-use')) &&
              t
                      .getSemantics(byKey('crop-use'))
                      .getSemanticsData()
                      .flagsCollection
                      .isEnabled ==
                  Tristate.isTrue,
          'the crop screen offering Use',
        );
        await tap('crop-use');

        String? stored;
        for (var i = 0; i < 100 && stored == null; i++) {
          stored = await t.runAsync<String?>(
            () async => _ok(await profiles.load(), 'loading ece').avatarPath,
          );
          await t.pump(const Duration(milliseconds: 200));
        }

        expect(picker.pictureCalls, 1);
        expect(picker.attachmentCalls, 0);
        expect(
          cropper.calls.single.source,
          _jpeg,
          reason: 'the crop screen did not crop the picked photo',
        );
        expect(stored, startsWith('profile/${_uid(eceClient)}/'));
        final bytes = await t.runAsync(() => chat.avatarBytes(stored!));
        expect(
          listEquals(_ok(bytes!, 'reading the picture'), cropper.output),
          isTrue,
          reason: 'the stored picture is not the cropped square',
        );
        expect(gallery.accessRequests, 1, reason: 'only opening the sheet');
        expect(gallery.openSettingsCalls, 0);

        await t.pumpWidget(const SizedBox());
        await t.runAsync(() => eceClient.removeAllChannels());
        await t.runAsync(() => eceClient.realtime.disconnect());
        await t.pump(const Duration(seconds: 61));
      }, timeout: const Timeout(Duration(seconds: 120)));
    },
  );
}
