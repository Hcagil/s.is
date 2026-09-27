@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Profile and group pictures against the real stack: the private `avatars`
/// bucket and its policies, profiles.avatar_path, set_group_avatar(), and the
/// repositories' own query shaping -- upload, read by someone allowed, refusal
/// for someone who is not, replacement (a new path; the old object gone) and
/// removal.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// accounts (avi, bea, cem): signing in claims the active device.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real JPEG header; [tag] makes each picture's bytes distinct so a read
/// can tell which one it got.
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

/// Kept in memory so a test can see what the repository cached, and clear it
/// the way signing out does.
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

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

/// A real client whose connection to one endpoint can be cut on demand --
/// what a device sees when the network drops right after an upload. Storage
/// keeps working; only the RPC or the profiles table stops answering (the
/// request goes to a name the server does not have, and fails there).
class _Faulty extends SupabaseClient {
  _Faulty()
    : super(
        _url,
        _key,
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
      );

  bool rpcDown = false;
  bool profilesDown = false;

  @override
  PostgrestFilterBuilder<T> rpc<T>(
    String fn, {
    Map<String, dynamic>? params,
    dynamic get = false,
  }) => super.rpc(rpcDown ? '${fn}_unreachable' : fn, params: params, get: get);

  @override
  SupabaseQueryBuilder from(String table) => super.from(
    profilesDown && table == 'profiles' ? 'profiles_unreachable' : table,
  );
}

Future<SupabaseClient> _signedIn(
  String email, {
  bool activate = true,
  SupabaseClient? over,
}) async {
  final client = over ?? _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  if (activate) {
    expect(
      await client.rpc('activate_session'),
      isTrue,
      reason: 'activate_session refused an allowlisted user',
    );
  }
  return client;
}

/// Object names under [folder] in the avatars bucket, as [client] may list them.
Future<List<String>> _objects(SupabaseClient client, String folder) async {
  final files = await client.storage.from('avatars').list(path: folder);
  return [for (final f in files) '$folder/${f.name}'];
}

String _folder(String path) => path.substring(0, path.lastIndexOf('/'));

T _ok<T>(Result<T> r) {
  if (r case Err(:final failure)) fail('expected Ok, got $failure');
  return (r as Ok<T>).value;
}

Failure _err<T>(Result<T> r) {
  if (r case Ok(:final value)) fail('expected Err, got Ok($value)');
  return (r as Err<T>).failure;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient avi, bea, stranger, anon;
  late _Faulty cem;
  late String aviId, beaId;

  setUpAll(() async {
    avi = await _signedIn('avi@integration.test');
    bea = await _signedIn('bea@integration.test');
    cem = await _signedIn('cem@integration.test', over: _Faulty()) as _Faulty;
    // Signs in with Google-like ease but is on no allowlist.
    stranger = await _signedIn(
      'stranger-avatars@integration.test',
      activate: false,
    );
    anon = _client();
    aviId = avi.auth.currentUser!.id;
    beaId = bea.auth.currentUser!.id;
  });

  // Every test starts with avi pictureless and her folder empty, whatever an
  // earlier (possibly failed) test or run left behind.
  setUp(() async {
    final repo = SupabaseProfileRepository(avi);
    if (_ok(await repo.load()).avatarPath case final path?) {
      await repo.removeAvatar(path);
    }
    final left = await _objects(avi, 'profile/$aviId');
    if (left.isNotEmpty) await avi.storage.from('avatars').remove(left);
  });

  tearDownAll(() async {
    for (final c in [avi, bea, cem, stranger, anon]) {
      await c.dispose();
    }
  });

  test('own picture: upload -> an allowed viewer reads it everywhere it shows '
      '-> refused to those who may not -> replace (new path, old gone, no '
      'stale cache) -> remove (file deleted)', () async {
    final profiles = SupabaseProfileRepository(avi);
    final beaCache = _MemoryCache();
    final beaChat = SupabaseChatRepository(bea, cache: beaCache);

    // Upload.
    final first = _ok(await profiles.setAvatar(_jpeg(1)));
    final p1 = first.avatarPath!;
    expect(p1, startsWith('profile/$aviId/'));
    expect(
      _ok(await profiles.load()).avatarPath,
      p1,
      reason: 'the path did not persist on the profile row',
    );
    expect(await _objects(avi, 'profile/$aviId'), [p1]);

    // bea sees the path wherever avi appears: the member list, and the 1:1.
    final people = _ok(await beaChat.members());
    expect(people.singleWhere((m) => m.userId == aviId).avatarPath, p1);
    final direct = _ok(await beaChat.startDirectConversation(aviId));
    final row = _ok(await beaChat.conversations())
        .singleWhere((c) => c.id == direct);
    expect(row.other?.avatarPath, p1, reason: 'the 1:1 row carries no picture');
    expect(
      row.avatarPath,
      isNull,
      reason: 'a 1:1 never has a picture of its own',
    );

    // ... and reads the bytes that went up, kept on the phone after.
    expect(_ok(await beaChat.avatarBytes(p1)), _jpeg(1).bytes);
    expect(beaCache.store[p1], _jpeg(1).bytes, reason: 'not cached');

    // Refused: an account off the allowlist, and nobody signed in at all.
    expect(
      await SupabaseChatRepository(stranger).avatarBytes(p1),
      isA<Err<Uint8List>>(),
    );
    expect(
      await SupabaseChatRepository(anon).avatarBytes(p1),
      isA<Err<Uint8List>>(),
    );

    // Replace: a new path, the old object gone, the new bytes served even
    // though the old ones are still in bea's cache.
    final second = _ok(await profiles.setAvatar(_jpeg(2), previousPath: p1));
    final p2 = second.avatarPath!;
    expect(p2, startsWith('profile/$aviId/'));
    expect(p2, isNot(p1), reason: 'a reused path serves a stale cached copy');
    expect(await _objects(avi, 'profile/$aviId'), [
      p2,
    ], reason: 'the previous picture was not deleted');
    expect(_ok(await beaChat.avatarBytes(p2)), _jpeg(2).bytes);
    expect(
      await SupabaseChatRepository(bea).avatarBytes(p1),
      isA<Err<Uint8List>>(),
      reason: 'the old picture can still be downloaded',
    );

    // Remove.
    final removed = _ok(await profiles.removeAvatar(p2));
    expect(removed.avatarPath, isNull);
    expect(_ok(await profiles.load()).avatarPath, isNull);
    expect(await _objects(avi, 'profile/$aviId'), isEmpty);
    expect(
      _ok(await beaChat.members())
          .singleWhere((m) => m.userId == aviId)
          .avatarPath,
      isNull,
    );
  });

  test('pictures are read through the cache that signing out clears', () async {
    final profiles = SupabaseProfileRepository(avi);
    final path = _ok(await profiles.setAvatar(_jpeg(3))).avatarPath!;
    final cache = _MemoryCache();
    final beaChat = SupabaseChatRepository(bea, cache: cache);
    expect(_ok(await beaChat.avatarBytes(path)), _jpeg(3).bytes);

    // The stored file goes; the phone still has it -- from the cache.
    _ok(await profiles.removeAvatar(path));
    expect(
      _ok(await beaChat.avatarBytes(path)),
      _jpeg(3).bytes,
      reason: 'a second read went to the network instead of the cache',
    );

    // Signing out clears that cache (AttachmentCache.clear); nothing is left.
    await cache.clear();
    expect(await beaChat.avatarBytes(path), isA<Err<Uint8List>>());
  });

  test('the bucket refuses what is not a JPEG of at most 1 MB, and the '
      'profile keeps its picture', () async {
    final profiles = SupabaseProfileRepository(avi);
    final kept = _ok(await profiles.setAvatar(_jpeg(4))).avatarPath!;

    final png = PickedImage(
      bytes: _jpeg(5).bytes,
      contentType: 'image/png',
      extension: 'png',
    );
    _err(await profiles.setAvatar(png, previousPath: kept));
    final big = PickedImage(
      bytes: Uint8List(1024 * 1024 + 1),
      contentType: 'image/jpeg',
      extension: 'jpg',
    );
    final failure = _err(await profiles.setAvatar(big, previousPath: kept));
    for (final raw in ['Exception', 'statusCode', 'Instance of']) {
      expect(failure.message, isNot(contains(raw)));
    }

    expect(_ok(await profiles.load()).avatarPath, kept);
    expect(await _objects(avi, 'profile/$aviId'), [
      kept,
    ], reason: 'a refused upload must not delete the picture it would replace');
    _ok(await profiles.removeAvatar(kept));
  });

  test('group picture: any member sets it -> members read it, a non-member '
      'is refused -> another member replaces it (new path, old gone) -> a '
      'non-member cannot set it -> removed', () async {
    final aviChat = SupabaseChatRepository(avi);
    final beaChat = SupabaseChatRepository(bea);
    final cemChat = SupabaseChatRepository(cem);
    final group = _ok(
      await aviChat.startGroupConversation(
        title: 'pictures',
        memberIds: [beaId],
      ),
    );
    Future<Conversation> rowFor(SupabaseChatRepository r) async =>
        _ok(await r.conversations()).singleWhere((c) => c.id == group);

    _ok(await aviChat.setGroupAvatar(group, _jpeg(10)));
    final g1 = (await rowFor(beaChat)).avatarPath!;
    expect(g1, startsWith('group/$group/'));
    expect((await rowFor(aviChat)).avatarPath, g1);
    expect(_ok(await beaChat.avatarBytes(g1)), _jpeg(10).bytes);
    expect(
      await cemChat.avatarBytes(g1),
      isA<Err<Uint8List>>(),
      reason: 'a non-member downloaded a group picture',
    );

    // bea, not the creator, replaces it.
    _ok(await beaChat.setGroupAvatar(group, _jpeg(11), previousPath: g1));
    final g2 = (await rowFor(aviChat)).avatarPath!;
    expect(g2, startsWith('group/$group/'));
    expect(g2, isNot(g1));
    expect(_ok(await aviChat.avatarBytes(g2)), _jpeg(11).bytes);
    expect(await _objects(avi, _folder(g2)), [
      g2,
    ], reason: 'the previous group picture was not deleted');

    // cem is not in the group.
    final refused = _err(
      await cemChat.setGroupAvatar(group, _jpeg(12), previousPath: g2),
    );
    expect(refused, isA<DeniedFailure>());
    expect((await rowFor(aviChat)).avatarPath, g2);
    expect(await _objects(avi, _folder(g2)), [
      g2,
    ], reason: 'a refused non-member deleted or added a group picture');

    // Removed.
    _ok(await aviChat.setGroupAvatar(group, null, previousPath: g2));
    expect((await rowFor(beaChat)).avatarPath, isNull);
    expect(await _objects(avi, 'group/$group'), isEmpty);
  });

  test('a 1:1 never gets a picture of its own', () async {
    final aviChat = SupabaseChatRepository(avi);
    final direct = _ok(await aviChat.startDirectConversation(beaId));
    final refused = _err(await aviChat.setGroupAvatar(direct, _jpeg(20)));
    expect(refused, isA<DeniedFailure>());
    expect(
      await _objects(avi, 'group/$direct'),
      isEmpty,
      reason: 'a refused 1:1 picture was left in storage',
    );
    final row = _ok(await aviChat.conversations())
        .singleWhere((c) => c.id == direct);
    expect(row.avatarPath, isNull);
  });

  test('the group\'s previous picture deleted is the one the server had, '
      'not a stale path the caller passed', () async {
    final aviChat = SupabaseChatRepository(avi);
    final beaChat = SupabaseChatRepository(bea);
    final group = _ok(
      await aviChat.startGroupConversation(
        title: 'stale previous',
        memberIds: [beaId],
      ),
    );
    Future<String?> current() async =>
        _ok(await aviChat.conversations())
            .singleWhere((c) => c.id == group)
            .avatarPath;

    _ok(await aviChat.setGroupAvatar(group, _jpeg(30)));
    final p1 = (await current())!;
    _ok(await beaChat.setGroupAvatar(group, _jpeg(31), previousPath: p1));
    final p2 = (await current())!;

    // avi's screen still thinks p1 is current (it is long gone).
    _ok(await aviChat.setGroupAvatar(group, _jpeg(32), previousPath: p1));
    final p3 = (await current())!;
    expect(await _objects(avi, 'group/$group'), [
      p3,
    ], reason: 'the picture the server replaced ($p2) was left behind');

    // No previous path at all: the server's still goes.
    _ok(await aviChat.setGroupAvatar(group, null));
    expect(await _objects(avi, 'group/$group'), isEmpty);
  });

  test(
    'a group picture whose RPC never lands is not left in storage',
    () async {
      final cemChat = SupabaseChatRepository(cem);
      final group = _ok(
        await cemChat.startGroupConversation(
          title: 'rpc drops',
          memberIds: [beaId],
        ),
      );
      cem.rpcDown = true;
      try {
        _err(await cemChat.setGroupAvatar(group, _jpeg(40)));
      } finally {
        cem.rpcDown = false;
      }
      expect(
        await _objects(cem, 'group/$group'),
        isEmpty,
        reason:
            'the upload went up, the row never pointed at it, and it stayed',
      );
      final row = _ok(await cemChat.conversations())
          .singleWhere((c) => c.id == group);
      expect(row.avatarPath, isNull);
    },
  );

  test('an own picture whose profile update never lands is not left in '
      'storage, and the profile keeps its picture', () async {
    final profiles = SupabaseProfileRepository(cem);
    final cemId = cem.auth.currentUser!.id;
    if (_ok(await profiles.load()).avatarPath case final p?) {
      _ok(await profiles.removeAvatar(p));
    }
    final left = await _objects(cem, 'profile/$cemId');
    if (left.isNotEmpty) await cem.storage.from('avatars').remove(left);
    final kept = _ok(await profiles.setAvatar(_jpeg(50))).avatarPath!;

    cem.profilesDown = true;
    try {
      _err(await profiles.setAvatar(_jpeg(51), previousPath: kept));
    } finally {
      cem.profilesDown = false;
    }
    expect(await _objects(cem, 'profile/$cemId'), [
      kept,
    ], reason: 'an orphan was left, or the kept picture was deleted');
    expect(_ok(await profiles.load()).avatarPath, kept);
    _ok(await profiles.removeAvatar(kept));
  });
}
