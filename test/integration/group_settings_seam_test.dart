@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/group_controller.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_group_settings_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/group_settings_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// Group settings and delete group, wired as main.dart wires them: GroupController
/// over the Supabase chat and group-settings repositories of one signed-in
/// client, each member in their own app. The server truth is read with the
/// service key; the live group_changed nudge travels the real `chats:<uid>`
/// topic; the picture and photo clean-up goes through the real Storage API,
/// whose avatars_remove policy is checked from both sides. A dead host is the
/// failure path of each connection.
///
/// Requires the local stack and SUPABASE_TEST_SERVICE_KEY (see
/// test/support/service_key.dart). Uses its own seeded accounts (pace, quill,
/// rush): signing in claims the active device.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

final _jpegHead = base64Decode(
  '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////'
  '////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBAB'
  'AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=',
);
PickedImage _jpeg(int tag) => PickedImage(
  bytes: Uint8List.fromList([..._jpegHead, tag, 0xFF, 0xD9]),
  contentType: 'image/jpeg',
  extension: 'jpg',
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

T _ok<T>(Result<T> r, [String what = '']) {
  if (r case Err(:final failure)) fail('$what refused: ${failure.message}');
  return (r as Ok<T>).value;
}

String _nonce() => DateTime.now().microsecondsSinceEpoch.toString();

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

/// One member's app over [client], with main.dart's overrides, listening as
/// the chat list does (the list and the group-changes listener).
class _App {
  _App(this.client, {String? id}) {
    final me = id ?? client.auth.currentUser!.id;
    container = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        sessionControllerProvider.overrideWith(
          () => _SignedIn(Member(userId: me, displayName: me)),
        ),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
        groupSettingsRepositoryProvider.overrideWithValue(
          SupabaseGroupSettingsRepository(client),
        ),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(client),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(client),
        ),
      ],
    );
    container.listen(conversationListProvider, (_, _) {});
    container.listen(groupChangesListenerProvider, (_, _) {});
  }

  final SupabaseClient client;
  late final ProviderContainer container;

  GroupController get groups => container.read(groupControllerProvider);

  Future<void> ready() async {
    await container.read(sessionControllerProvider.future);
    await container.read(conversationListProvider.future);
  }

  Future<void> refresh() =>
      container.read(conversationListProvider.notifier).refresh();

  bool lists(String id) => container
      .read(conversationListProvider)
      .requireValue
      .any((c) => c.id == id);

  /// The settings a screen shows for [id], kept alive like an open page.
  GroupSettings settings(String id) {
    final sub = container.listen(groupSettingsProvider(id), (_, _) {});
    addTearDown(sub.close);
    return container.read(groupSettingsProvider(id));
  }

  Set<String> get deleted => container.read(deletedGroupsProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient pace, quill, rush, service;

  String idOf(SupabaseClient c) => c.auth.currentUser!.id;

  setUpAll(() async {
    pace = await _signedIn('pace@integration.test');
    quill = await _signedIn('quill@integration.test');
    rush = await _signedIn('rush@integration.test');
    service = SupabaseClient(_url, serviceKey());
    // pace reaches quill and rush (stored, so a quick rerun may hit RLMT1).
    try {
      await findByTag(pace, [quill, rush]);
    } on PostgrestException catch (e) {
      if (e.code != 'RLMT1') rethrow;
    }
  });

  tearDownAll(() async {
    for (final c in [pace, quill, rush, service]) {
      await c.dispose();
    }
  });

  Future<String> newGroup() async => _ok(
    await SupabaseChatRepository(pace).startGroupConversation(
      title: 'gs ${_nonce()}',
      memberIds: [idOf(quill), idOf(rush)],
    ),
    'start group',
  );

  Future<Map<String, dynamic>?> row(String g) async => service
      .from('conversations')
      .select(
        'avatar_path, members_can_set_avatar, members_can_add, '
        'new_members_see_history',
      )
      .eq('id', g)
      .maybeSingle();

  Future<bool> exists(String bucket, String path) async {
    final slash = path.lastIndexOf('/');
    final files = await service.storage
        .from(bucket)
        .list(
          path: path.substring(0, slash),
          searchOptions: SearchOptions(search: path.substring(slash + 1)),
        );
    return files.any((f) => f.name == path.substring(slash + 1));
  }

  /// pace sets [g]'s picture; its stored path.
  Future<String> picture(String g, int tag) async {
    _ok(
      await SupabaseChatRepository(pace).setGroupAvatar(g, _jpeg(tag)),
      'set picture',
    );
    return (await row(g))!['avatar_path'] as String;
  }

  /// [who] sends a photo into [g]; its attachment path.
  Future<String> photo(SupabaseClient who, String g, int tag) async => _ok(
    await SupabaseChatRepository(who)
        .sendImage(conversationId: g, image: _jpeg(tag)),
    'send photo',
  ).attachmentPath!;

  test('settings: the admin\'s change reaches the server and, live, another '
      'member\'s screen; a member is refused and rolled back', () async {
    final g = await newGroup();
    final paceApp = _App(pace);
    final quillApp = _App(quill);
    addTearDown(paceApp.container.dispose);
    addTearDown(quillApp.container.dispose);
    await paceApp.ready();
    await quillApp.ready();
    expect(quillApp.settings(g), isA<GroupSettings>());
    expect(quillApp.settings(g).membersCanAdd, isTrue, reason: 'new default');
    // Let both chats:<uid> channels come up before the change.
    await Future<void>.delayed(const Duration(seconds: 2));

    final r = await paceApp.groups.setSettings(g, membersCanAdd: false);
    expect(r, isA<Ok<void>>());
    expect(await row(g), {
      'avatar_path': null,
      'members_can_set_avatar': false,
      'members_can_add': false,
      'new_members_see_history': false, // new default (rule 16)
    }, reason: 'only the one switch changed on the server');
    expect(paceApp.settings(g).membersCanAdd, isFalse);

    // No refresh: only the group_changed nudge can bring this.
    await _until(
      () => !quillApp.settings(g).membersCanAdd,
      'quill sees the new setting live',
    );

    final refused = await quillApp.groups.setSettings(
      g,
      newMembersSeeHistory: true,
    );
    expect(refused, isA<Err<void>>());
    expect((refused as Err<void>).failure, isA<DeniedFailure>());
    expect(
      quillApp.settings(g).newMembersSeeHistory,
      isFalse,
      reason: 'the refused switch is rolled back',
    );
    expect((await row(g))!['new_members_see_history'], isFalse);
  });

  test('delete: the server refuses delete-for-everyone to a member and to '
      'the admin (rule 17); the group, its picture and photos stay', () async {
    final g = await newGroup();
    final pic = await picture(g, 1);
    final shot = await photo(quill, g, 2);
    addTearDown(() async {
      await service.storage.from('avatars').remove([pic]);
      await service.storage.from('attachments').remove([shot]);
    });

    final paceApp = _App(pace);
    final quillApp = _App(quill);
    addTearDown(paceApp.container.dispose);
    addTearDown(quillApp.container.dispose);
    await paceApp.ready();
    await quillApp.ready();
    expect(quillApp.lists(g), isTrue);

    for (final app in [quillApp, paceApp]) {
      final refused = await app.groups.deleteGroup(g);
      expect(refused, isA<Err<void>>());
      expect((refused as Err<void>).failure, isA<DeniedFailure>());
    }
    expect(await row(g), isNotNull, reason: 'a refused delete removed it');
    expect(quillApp.deleted, isNot(contains(g)));
    expect(paceApp.deleted, isNot(contains(g)));
    expect(await exists('avatars', pic), isTrue, reason: 'picture removed');
    expect(await exists('attachments', shot), isTrue, reason: 'photo removed');
  });

  test('Storage clean-up rules on the real Storage API: the refused '
      'delete_group records nothing, so nobody may remove a group\'s '
      'objects through the delete path', () async {
    final g = await newGroup();
    final shot = await photo(pace, g, 5);
    final quillProfile = 'profile/${idOf(quill)}/qa-${_nonce()}.jpg';
    await service.storage
        .from('avatars')
        .uploadBinary(
          quillProfile,
          _jpeg(6).bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
    addTearDown(() async {
      await service.storage.from('avatars').remove([quillProfile]);
      await service.storage.from('attachments').remove([shot]);
    });

    await expectLater(
      pace.rpc('delete_group', params: {'conversation': g}),
      throwsA(
        isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
      ),
    );

    Future<void> tryRemove(SupabaseClient who, String bucket, String p) async {
      try {
        await who.storage.from(bucket).remove([p]);
      } on StorageException {
        // A refusal may come back as an error or as an empty result.
      }
    }

    await tryRemove(quill, 'attachments', shot);
    expect(await exists('attachments', shot), isTrue, reason: 'a member');
    await tryRemove(pace, 'attachments', shot);
    expect(await exists('attachments', shot), isTrue, reason: 'the admin');
    await tryRemove(pace, 'avatars', quillProfile);
    expect(await exists('avatars', quillProfile), isTrue, reason: 'profile');
    // A live group's own picture path is not checked: its admin may remove
    // it through the picture policy (group_settings_test.sql covers that).
  });

  test('offline: a settings change and a delete fail with a reason, the '
      'switch rolls back and the group stays', () async {
    final g = await newGroup();
    // Away from every default, so a group missing from the list (which reads
    // as the defaults) cannot pass for a rollback.
    _ok(
      await SupabaseGroupSettingsRepository(pace).setSettings(
        g,
        membersCanSetAvatar: true,
        membersCanAdd: false,
        newMembersSeeHistory: false,
      ),
      'settings',
    );
    final dead = await deadButSignedIn(pace);
    addTearDown(dead.dispose);
    final live = _App(pace);
    addTearDown(live.container.dispose);
    await live.ready();
    // The dead app starts from the list the live one read.
    final app = _App(dead, id: idOf(pace));
    addTearDown(app.container.dispose);
    // Its own first load (offline) settles first, so it cannot overwrite the
    // list handed over below.
    try {
      await app.ready();
    } on Object {
      // Offline: the load fails, as it would on the phone.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    app.container.read(conversationListProvider.notifier).state = live.container
        .read(conversationListProvider);
    expect(app.lists(g), isTrue);

    expect(app.settings(g).membersCanAdd, isFalse);
    final pending = app.groups.setSettings(g, membersCanAdd: true);
    expect(app.settings(g).membersCanAdd, isTrue, reason: 'not optimistic');
    final r = await pending;
    expect(r, isA<Err<void>>());
    expect(
      (r as Err<void>).failure,
      isNot(isA<DeniedFailure>()),
      reason: 'refused before it ever tried the network',
    );
    expect(app.lists(g), isTrue, reason: 'the group left the list');
    final after = app.settings(g);
    expect(after.membersCanAdd, isFalse, reason: 'not rolled back');
    expect(after.membersCanSetAvatar, isTrue, reason: 'another switch moved');
    expect(after.newMembersSeeHistory, isFalse, reason: 'another moved');

    final d = await app.groups.deleteGroup(g);
    expect(d, isA<Err<void>>());
    expect(app.deleted, isNot(contains(g)));
    expect(await row(g), isNotNull);

    final changes = await SupabaseGroupSettingsRepository(dead)
        .groupChanges()
        .timeout(const Duration(seconds: 20));
    expect(changes, isA<Result<Stream<GroupChange>>>(), reason: 'it threw');
  });
}
