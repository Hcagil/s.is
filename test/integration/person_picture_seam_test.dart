@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/profile_pages.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/profile/avatar_widgets_test.dart' show avatarIn, picturesIn;
import '../support/fakes.dart';

/// A person's page shows the picture its caller knows, on the real stack:
/// deniz sets a picture AFTER ece's app has read the member list, so ece's
/// membersProvider holds a snapshot without it. ece then reaches deniz's page
/// (b) from a group's Members tab -- the conversation's member read, fresh
/// from the real tables -- and (a) from their 1:1's header after the list
/// reloads -- the conversation list's row. Each time the page shows the
/// picture deniz set, downloaded from the real bucket.
///
/// The whole app as main.dart mounts it for ece; only Google sign-in (which
/// cannot run locally) and the phone's file cache are stand-ins. Requires a
/// running local Supabase. Accounts deniz and ece are shared with
/// avatar_seam_test (run with --concurrency=1); deniz ends pictureless.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real, decodable 4x4 JPEG: the avatars bucket takes image/jpeg only, and
/// the page decodes what it shows.
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
String _stamp(String what) => '$what ${DateTime.now().microsecondsSinceEpoch}';

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
      Ok(Member(userId: client.auth.currentUser!.id, displayName: 'Ece'));
  @override
  Future<void> signOut() async {}
}

/// deniz with no picture and nothing left in his folder.
Future<void> _pictureless(SupabaseClient deniz) async {
  final repo = SupabaseProfileRepository(deniz);
  final p = _ok(await repo.load(), 'loading deniz');
  if (p.avatarPath case final path?) await repo.removeAvatar(path);
  final folder = 'profile/${_uid(deniz)}';
  final left = [
    for (final f in await deniz.storage.from('avatars').list(path: folder))
      '$folder/${f.name}',
  ];
  if (left.isNotEmpty) await deniz.storage.from('avatars').remove(left);
}

void main() {
  // testWidgets installs a binding that answers every HTTP request with 400;
  // this suite talks to a real server.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient denizClient, eceClient;

  setUpAll(() async {
    denizClient = await _signedIn('deniz@integration.test');
    eceClient = await _signedIn('ece@integration.test');
    // Past onboarding, so her app opens on the list.
    await eceClient
        .from('profiles')
        .update({'onboarding_done': true})
        .eq('user_id', _uid(eceClient));
  });

  tearDownAll(() async {
    await _pictureless(denizClient);
    await denizClient.dispose();
    await eceClient.dispose();
  });

  testWidgets('a picture set after the member list was read shows on the '
      'person page from a group\'s Members row and from the 1:1 header', (
    t,
  ) async {
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    final denizId = _uid(denizClient);
    final ece = SupabaseChatRepository(eceClient);
    final deniz = SupabaseChatRepository(denizClient);
    final (group, direct) = (await t.runAsync(() async {
      await _pictureless(denizClient);
      final g = _ok(
        await ece.startGroupConversation(
          title: _stamp('person picture'),
          memberIds: [denizId],
        ),
        'creating the group',
      );
      final d = _ok(await ece.startDirectConversation(denizId), 'the 1:1');
      _ok(
        await deniz.send(
          id: randomMessageId(),
          conversationId: g,
          body: _stamp('g'),
        ),
        'send',
      );
      _ok(
        await deniz.send(
          id: randomMessageId(),
          conversationId: d,
          body: _stamp('d'),
        ),
        'send',
      );
      return (g, d);
    }))!;

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
          authRepositoryProvider.overrideWithValue(_AccountAuth(eceClient)),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            SupabaseChatRepository(eceClient, cache: cache),
          ),
          attachmentCacheProvider.overrideWithValue(cache),
          presenceRepositoryProvider.overrideWithValue(
            SupabasePresenceRepository(eceClient),
          ),
          profileRepositoryProvider.overrideWithValue(
            SupabaseProfileRepository(eceClient),
          ),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ],
        child: const SisApp(),
      ),
    );

    Future<void> until(bool Function() ok, String what) async {
      for (var i = 0; i < 150; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await t.pump(const Duration(milliseconds: 100));
        if (ok()) return;
      }
      final seen = [
        for (final e in find.byType(Text).evaluate())
          (e.widget as Text).data ?? '',
      ];
      fail('never happened: $what; on screen: ${seen.take(20).join(' | ')}');
    }

    Finder byKey(String k) => find.byKey(ValueKey(k));
    bool shows(Finder f) => f.evaluate().isNotEmpty;
    Future<void> tap(String k) async {
      await until(() => shows(byKey(k)), k);
      await t.ensureVisible(byKey(k));
      await t.pump(const Duration(seconds: 1)); // any transition finishes
      await t.tap(byKey(k));
    }

    final person = find.byType(PersonScreen);
    bool showsThePicture() =>
        shows(person) &&
        picturesIn(avatarIn(person)).any((b) => listEquals(b, _jpeg));

    await until(() => shows(byKey('conversation-$group')), 'the list');
    final container = ProviderScope.containerOf(t.element(find.byType(SisApp)));

    // ece's member list, read before deniz has a picture.
    container.listen(membersProvider, (_, _) {});
    String? denizInMembers() => container
        .read(membersProvider)
        .value
        ?.singleWhere((m) => m.userId == denizId)
        .avatarPath;
    await until(() => container.read(membersProvider).hasValue, 'members');
    expect(denizInMembers(), isNull);

    final path = (await t.runAsync(() async {
      final set = await SupabaseProfileRepository(denizClient).setAvatar(
        PickedImage(bytes: _jpeg, contentType: 'image/jpeg', extension: 'jpg'),
      );
      return _ok<OwnProfile>(set, 'deniz setting a picture').avatarPath;
    }))!;
    expect(path, startsWith('profile/$denizId/'));

    // (b) the group's page -> Members -> deniz.
    await tap('conversation-$group');
    await until(() => shows(find.byType(MessageScreen)), 'the group chat');
    await tap('conversation-title');
    await until(() => shows(find.byType(GroupScreen)), 'the group page');
    await tap('tab-members');
    await tap('group-member-$denizId');
    await until(() => shows(person), 'deniz\'s page');
    expect(
      denizInMembers(),
      isNull,
      reason:
          'the member list is no longer the stale snapshot: this path '
          'no longer shows that the caller\'s picture is used',
    );
    await until(showsThePicture, 'deniz\'s picture, from the Members row');

    Navigator.of(t.element(person)).popUntil((r) => r.isFirst);
    await until(() => !shows(find.byType(MessageScreen)), 'back to the list');

    // (a) the list reloads; the 1:1 header -> deniz.
    await t.runAsync(
      () => container.read(conversationListProvider.notifier).refresh(),
    );
    // The 1:1 tops the list (its message is the newest), but tapping the
    // group, second, ran ensureVisible, which aligns that row to the top
    // whenever the list can scroll: with ece's groups from earlier runs it
    // can, and the 1:1 is left offstage above it. Scroll back up to it, as
    // ece would.
    await until(() => shows(byKey('conversation-$group')), 'the list again');
    await t.scrollUntilVisible(
      byKey('conversation-$direct'),
      -100,
      scrollable: find
          .ancestor(
            // Any row in view: finders skip the ones scrolled away.
            of: find.byWidgetPredicate((w) {
              final k = w.key;
              return k is ValueKey<String> &&
                  RegExp(r'^conversation-[0-9a-f-]{36}$').hasMatch(k.value);
            }).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tap('conversation-$direct');
    await until(() => shows(find.byType(MessageScreen)), 'the 1:1');
    await tap('conversation-title');
    await until(() => shows(person), 'deniz\'s page');
    await until(showsThePicture, 'deniz\'s picture, from the 1:1 header');

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => eceClient.removeAllChannels());
    await t.runAsync(() => eceClient.realtime.disconnect());
    await t.pump(const Duration(seconds: 61));
  }, timeout: const Timeout(Duration(seconds: 120)));
}
