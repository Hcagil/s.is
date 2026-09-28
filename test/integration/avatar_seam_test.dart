@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart' show offlineMessage;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';

/// The controllers that set a picture, wired as main.dart wires them: the
/// Supabase repositories over one signed-in client, the chat repository and
/// attachmentCacheProvider sharing one cache, and the picture read back
/// through avatarBytesProvider -- by the member who set it and by another
/// member, each through their own app. The failure path of each connection
/// is a client whose host is unreachable.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (deniz, ece): signing in claims the active device.
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

class _MemoryCache implements AttachmentCache {
  final store = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String path) async => store[path];
  @override
  Future<void> write(String path, Uint8List bytes) async => store[path] = bytes;
  @override
  Future<void> remove(String path) async => store.remove(path);
  @override
  Future<void> clear() async => store.clear();
}

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

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

/// One member's app over [client], with main.dart's overrides.
class _App {
  _App(this.client) : cache = _MemoryCache() {
    final id = client.auth.currentUser!.id;
    container = ProviderContainer.test(
      overrides: [
        sessionControllerProvider.overrideWith(
          () => _SignedIn(Member(userId: id, displayName: id)),
        ),
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
      ],
    );
    container.listen(ownProfileProvider, (_, _) {});
    container.listen(conversationListProvider, (_, _) {});
  }

  final SupabaseClient client;
  final _MemoryCache cache;
  late final ProviderContainer container;

  String get id => client.auth.currentUser!.id;
  OwnProfileController get profile =>
      container.read(ownProfileProvider.notifier);
  ConversationListController get list =>
      container.read(conversationListProvider.notifier);

  Future<void> ready() async {
    await container.read(sessionControllerProvider.future);
    await container.read(ownProfileProvider.future);
    await container.read(conversationListProvider.future);
  }

  String? get ownPath =>
      container.read(ownProfileProvider).requireValue.avatarPath;

  Future<Conversation> row(String id) async {
    await list.refresh();
    return container
        .read(conversationListProvider)
        .requireValue
        .singleWhere((c) => c.id == id);
  }

  /// The picture as a screen gets it.
  Future<Uint8List> picture(String path) {
    final sub = container.listen(avatarBytesProvider(path), (_, _) {});
    addTearDown(sub.close);
    return container.read(avatarBytesProvider(path).future);
  }

  Future<List<String>> objects(String folder) async => [
    for (final f in await client.storage.from('avatars').list(path: folder))
      '$folder/${f.name}',
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient denizClient, eceClient, deadClient;

  setUpAll(() async {
    denizClient = await _signedIn('deniz@integration.test');
    eceClient = await _signedIn('ece@integration.test');
    deadClient = await deadButSignedIn(denizClient);
  });

  // Every test starts with deniz pictureless and his folder empty.
  setUp(() async {
    final repo = SupabaseProfileRepository(denizClient);
    final p = (await repo.load()) as Ok<OwnProfile>;
    if (p.value.avatarPath case final path?) await repo.removeAvatar(path);
    final folder = 'profile/${denizClient.auth.currentUser!.id}';
    final left = [
      for (final f
          in await denizClient.storage.from('avatars').list(path: folder))
        '$folder/${f.name}',
    ];
    if (left.isNotEmpty) await denizClient.storage.from('avatars').remove(left);
  });

  tearDownAll(() async {
    await denizClient.dispose();
    await eceClient.dispose();
    await deadClient.dispose();
  });

  test('your own picture: set, seen by another member, replaced, removed -- '
      'through OwnProfileController as production wires it', () async {
    final deniz = _App(denizClient);
    final ece = _App(eceClient);
    addTearDown(deniz.container.dispose);
    addTearDown(ece.container.dispose);
    await deniz.ready();
    await ece.ready();

    final set = await deniz.profile.setAvatar(_jpeg(1));
    expect(set, isA<Ok<OwnProfile>>());
    final p1 = deniz.ownPath!;
    expect(p1, startsWith('profile/${deniz.id}/'));
    expect(await deniz.picture(p1), _jpeg(1).bytes);

    // ece finds it where the member list and the 1:1 carry it.
    final seen = (await ece.container.read(yourPeopleProvider.future))
        .singleWhere((m) => m.userId == deniz.id)
        .avatarPath;
    expect(seen, p1);
    expect(await ece.picture(p1), _jpeg(1).bytes);
    expect(
      ece.cache.store[p1],
      _jpeg(1).bytes,
      reason: 'not kept on ece\'s phone',
    );

    await deniz.profile.setAvatar(_jpeg(2));
    final p2 = deniz.ownPath!;
    expect(p2, isNot(p1));
    expect(await deniz.objects('profile/${deniz.id}'), [p2]);
    expect(await ece.picture(p2), _jpeg(2).bytes);

    final removed = await deniz.profile.removeAvatar();
    expect(removed, isA<Ok<OwnProfile>>());
    expect(deniz.ownPath, isNull);
    expect(await deniz.objects('profile/${deniz.id}'), isEmpty);
  });

  test('a group\'s picture: set by one member, seen and replaced by the '
      'other, cleared -- through ConversationListController', () async {
    final deniz = _App(denizClient);
    final ece = _App(eceClient);
    addTearDown(deniz.container.dispose);
    addTearDown(ece.container.dispose);
    await deniz.ready();
    await ece.ready();

    final started = await deniz.list.startGroup(
      title: 'seam pictures',
      memberIds: [ece.id],
    );
    final group = (started as Ok<String>).value;

    expect(await deniz.list.setGroupAvatar(group, _jpeg(10)), isA<Ok<void>>());
    await pumpEventQueue();
    final g1 = deniz.container
        .read(conversationListProvider)
        .requireValue
        .singleWhere((c) => c.id == group)
        .avatarPath;
    expect(g1, startsWith('group/$group/'), reason: 'the list did not re-read');
    expect((await ece.row(group)).avatarPath, g1);
    expect(await ece.picture(g1!), _jpeg(10).bytes);

    expect(await ece.list.setGroupAvatar(group, _jpeg(11)), isA<Ok<void>>());
    final g2 = (await deniz.row(group)).avatarPath!;
    expect(g2, isNot(g1));
    expect(await deniz.objects('group/$group'), [g2]);
    expect(await deniz.picture(g2), _jpeg(11).bytes);

    expect(await deniz.list.setGroupAvatar(group, null), isA<Ok<void>>());
    expect((await ece.row(group)).avatarPath, isNull);
    expect(await deniz.objects('group/$group'), isEmpty);

    final direct = await deniz.list.startWith(ece.id);
    final refused = await deniz.list.setGroupAvatar(
      (direct as Ok<String>).value,
      _jpeg(12),
    );
    expect(refused, isA<Err<void>>());
  });

  test('offline: each controller says so in plain words and keeps what it '
      'had', () async {
    final live = _App(denizClient);
    addTearDown(live.container.dispose);
    await live.ready();
    await live.profile.setAvatar(_jpeg(20));
    final kept = live.ownPath!;

    // The same member, the network gone.
    final dead = _App(deadClient);
    addTearDown(dead.container.dispose);
    final set = await dead.profile.setAvatar(_jpeg(21));
    expect(set, isA<Err<OwnProfile>>());
    expect((set as Err).failure.message, offlineMessage);
    final cleared = await dead.list.setGroupAvatar(
      '00000000-0000-0000-0000-000000000000',
      _jpeg(22),
    );
    expect(cleared, isA<Err<void>>());
    expect((cleared as Err).failure.message, offlineMessage);

    final now = (await SupabaseProfileRepository(denizClient).load()) as Ok;
    expect((now.value as OwnProfile).avatarPath, kept);
    expect(await live.objects('profile/${live.id}'), [kept]);
    await live.profile.removeAvatar();
  });
}
