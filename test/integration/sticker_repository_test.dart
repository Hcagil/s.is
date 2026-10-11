@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/data/supabase_sticker_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/reach.dart';
import '../support/service_key.dart';

/// Stickers (step 10a) on the real local stack, through
/// [SupabaseStickerRepository], written from the contract: albums and
/// favourites through their RPCs, the three server limits as
/// StickerLimitFailure('STKA1' | 'STKA2' | 'STKF1'), 42501 as DeniedFailure,
/// offline as a retryable NetworkFailure, sending with a client id (retry is
/// harmless), album cards, shared-album copy and favourites, and the image
/// bytes from the private `stickers` bucket. The seam to
/// [SupabaseChatRepository]: a sent sticker loads back with its id, its chat
/// preview reads the sticker line, and forward keeps it a sticker.
///
/// 10a has no upload, so owned stickers are service-key fixtures, removed at
/// the end. Accounts priya, quinlan, remy are shared with other suites; the
/// sticker state of priya and quinlan is cleared first (the limits are per
/// person). Run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

String _stamp(String what) => '$what${DateTime.now().microsecondsSinceEpoch}';

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok: $r');
  return (r as Ok<T>).value;
}

Failure _err<T>(Result<T> r) {
  expect(r, isA<Err<T>>(), reason: 'expected Err: $r');
  return (r as Err<T>).failure;
}

Future<String> _group(
  SupabaseClient owner,
  List<SupabaseClient> members,
  String title,
) async {
  final chat = SupabaseChatRepository(owner);
  final ids = [for (final m in members) m.auth.currentUser!.id];
  var r = await chat.startGroupConversation(title: title, memberIds: ids);
  if (r is Err<String>) {
    await findByTag(owner, members);
    r = await chat.startGroupConversation(title: title, memberIds: ids);
  }
  return _ok(r);
}

Future<void> _clear(SupabaseStickerRepository r) async {
  for (final a in _ok(await r.albums())) {
    _ok(await r.deleteAlbum(a.id));
  }
  for (final f in _ok(await r.favourites())) {
    _ok(await r.removeFavourite(f));
  }
}

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient, service;
  late SupabaseStickerRepository priya, quinlan, remy;
  late SupabaseChatRepository priyaChat, quinlanChat;
  late String club; // priya + quinlan
  late String other; // priya + quinlan, the forward target
  late String priyaId;
  final owned = <String>[]; // priya's fixture stickers
  final starter1 = starterStickerId(1);
  final starter2 = starterStickerId(2);
  final webp = Uint8List.fromList(
    File('assets/stickers/starter_03.webp').readAsBytesSync(),
  );

  Future<List<String>> ownStickers(int n, {bool upload = false}) async {
    final ids = [for (var i = 0; i < n; i++) randomMessageId()];
    await service.from('stickers').insert([
      for (final id in ids) {'id': id, 'owner_id': priyaId},
    ]);
    owned.addAll(ids);
    if (upload) {
      for (final id in ids) {
        await service.storage
            .from('stickers')
            .uploadBinary(
              '$id.webp',
              webp,
              fileOptions: const FileOptions(contentType: 'image/webp'),
            );
      }
    }
    return ids;
  }

  Future<Map<String, dynamic>> row(SupabaseClient c, String id) async => await c
      .from('messages')
      .select(
        'body, sticker_id, sticker_album, sticker_album_id, reply_to, forwarded',
      )
      .eq('id', id)
      .single();

  setUpAll(() async {
    service = _client(serviceKey());
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priyaId = priyaClient.auth.currentUser!.id;
    priya = SupabaseStickerRepository(priyaClient);
    quinlan = SupabaseStickerRepository(quinlanClient);
    remy = SupabaseStickerRepository(remyClient);
    priyaChat = SupabaseChatRepository(priyaClient);
    quinlanChat = SupabaseChatRepository(quinlanClient);
    await _clear(priya);
    await _clear(quinlan);
    club = await _group(priyaClient, [quinlanClient], _stamp('stickers '));
    other = await _group(priyaClient, [quinlanClient], _stamp('stickers o '));
  });

  tearDownAll(() async {
    await _clear(priya);
    await _clear(quinlan);
    for (final id in [club, other]) {
      await service.from('conversations').delete().eq('id', id);
    }
    if (owned.isNotEmpty) {
      await service.storage.from('stickers').remove([
        for (final id in owned) '$id.webp',
      ]);
      for (var i = 0; i < owned.length; i += 50) {
        final part = owned.sublist(i, (i + 50).clamp(0, owned.length));
        await service.from('stickers').delete().inFilter('id', part);
      }
    }
    for (final c in [priyaClient, quinlanClient, remyClient, service]) {
      await c.dispose();
    }
  });

  // the limits are per person: every test starts from no albums, no favourites
  tearDown(() async {
    await _clear(priya);
    await _clear(quinlan);
  });

  group('albums and favourites', () {
    test('create, add (oldest first), rename, list, remove, delete', () async {
      final id = _ok(await priya.createAlbum('Album'));
      _ok(await priya.addToAlbum(id, starter2));
      _ok(await priya.addToAlbum(id, starter1));
      expect(_ok(await priya.albumStickers(id)), [starter2, starter1]);
      _ok(await priya.renameAlbum(id, 'Renamed'));
      final albums = _ok(await priya.albums());
      final a = albums.singleWhere((x) => x.id == id);
      expect(a.name, 'Renamed');
      expect(a.stickerIds, [starter2, starter1]);
      _ok(await priya.removeFromAlbum(id, starter2));
      expect(_ok(await priya.albumStickers(id)), [starter1]);
      _ok(await priya.deleteAlbum(id));
      expect(_ok(await priya.albums()).where((x) => x.id == id), isEmpty);
    });

    test('albums lists oldest first', () async {
      final first = _ok(await priya.createAlbum('First'));
      final second = _ok(await priya.createAlbum('Second'));
      final ids = [for (final a in _ok(await priya.albums())) a.id];
      expect(ids.indexOf(first), lessThan(ids.indexOf(second)));
      _ok(await priya.deleteAlbum(first));
      _ok(await priya.deleteAlbum(second));
    });

    test('favourites: add, newest first, remove', () async {
      _ok(await priya.addFavourite(starter1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      _ok(await priya.addFavourite(starter2));
      expect(_ok(await priya.favourites()), [starter2, starter1]);
      _ok(await priya.removeFavourite(starter2));
      expect(_ok(await priya.favourites()), [starter1]);
      _ok(await priya.removeFavourite(starter1));
      expect(_ok(await priya.favourites()), isEmpty);
    });

    test('another member\'s album is DeniedFailure, never changed', () async {
      final id = _ok(await priya.createAlbum('Private'));
      _ok(await priya.addToAlbum(id, starter1));
      expect(_err(await quinlan.renameAlbum(id, 'Mine')), isA<DeniedFailure>());
      expect(
        _err(await quinlan.addToAlbum(id, starter2)),
        isA<DeniedFailure>(),
      );
      expect(
        _err(await quinlan.removeFromAlbum(id, starter1)),
        isA<DeniedFailure>(),
      );
      expect(_err(await quinlan.deleteAlbum(id)), isA<DeniedFailure>());
      expect(_err(await quinlan.albumStickers(id)), isA<DeniedFailure>());
      final a = _ok(await priya.albums()).singleWhere((x) => x.id == id);
      expect(a.name, 'Private');
      expect(a.stickerIds, [starter1]);
      _ok(await priya.deleteAlbum(id));
    });

    test('a sticker the member cannot read is DeniedFailure', () async {
      final [mine] = await ownStickers(1);
      expect(_err(await quinlan.addFavourite(mine)), isA<DeniedFailure>());
    });
  });

  group('the server limits', () {
    test('the 11th album is StickerLimitFailure STKA1', () async {
      final ids = [
        for (var i = 0; i < maxStickerAlbums; i++)
          _ok(await priya.createAlbum('L$i')),
      ];
      final f = _err(await priya.createAlbum('Eleventh'));
      expect(f, isA<StickerLimitFailure>());
      expect((f as StickerLimitFailure).code, 'STKA1');
      for (final id in ids) {
        _ok(await priya.deleteAlbum(id));
      }
    });

    test('the 51st sticker in an album is STKA2', () async {
      final ids = await ownStickers(maxAlbumStickers + 1);
      final album = _ok(await priya.createAlbum('Full'));
      for (final id in ids.take(maxAlbumStickers)) {
        _ok(await priya.addToAlbum(album, id));
      }
      final f = _err(await priya.addToAlbum(album, ids.last));
      expect(f, isA<StickerLimitFailure>());
      expect((f as StickerLimitFailure).code, 'STKA2');
      _ok(await priya.deleteAlbum(album));
    });

    test('the 201st favourite is STKF1', () async {
      final ids = await ownStickers(maxFavouriteStickers + 1);
      for (final id in ids.take(maxFavouriteStickers)) {
        _ok(await priya.addFavourite(id));
      }
      final f = _err(await priya.addFavourite(ids.last));
      expect(f, isA<StickerLimitFailure>());
      expect((f as StickerLimitFailure).code, 'STKF1');
      for (final id in ids) {
        await priya.removeFavourite(id);
      }
    });
  });

  group('sending', () {
    test(
      'a sticker: empty body, retry harmless, loads back as a sticker',
      () async {
        final id = randomMessageId();
        _ok(await priya.send(club, id, starter1));
        _ok(await priya.send(club, id, starter1));
        final r = await row(quinlanClient, id);
        expect(
          (r['body'], r['sticker_id'], r['forwarded']),
          ('', starter1, false),
        );
        final loaded = _ok(await quinlanChat.messages(club));
        expect(loaded.where((m) => m.id == id).single.stickerId, starter1);
        final convs = _ok(await quinlanChat.conversations());
        expect(
          convs.singleWhere((c) => c.id == club).lastMessage,
          stickerPreviewText,
        );
      },
    );

    test('reply and forward', () async {
      final text = _ok(
        await priyaChat.send(
          id: randomMessageId(),
          conversationId: club,
          body: 'hi',
        ),
      );
      final reply = randomMessageId();
      _ok(await quinlan.send(club, reply, starter2, replyTo: text.id));
      expect((await row(priyaClient, reply))['reply_to'], text.id);
      final fwd = randomMessageId();
      _ok(await quinlan.send(other, fwd, starter2, forwarded: true));
      expect((await row(priyaClient, fwd))['forwarded'], true);
    });

    test('ChatRepository.forward keeps a sticker a sticker', () async {
      final id = randomMessageId();
      _ok(await priya.send(club, id, starter1));
      final msg = _ok(await priyaChat.messages(club))
          .singleWhere((m) => m.id == id);
      _ok(await priyaChat.forward(msg, [other]));
      final got = _ok(await quinlanChat.messages(other))
          .where((m) => m.stickerId == starter1 && m.senderId == priyaId)
          .toList();
      expect(got, isNotEmpty);
      final r = await quinlanClient
          .from('messages')
          .select('forwarded, body')
          .eq('id', got.last.id)
          .single();
      expect((r['forwarded'], r['body']), (true, ''));
    });

    test('a non-member is DeniedFailure', () async {
      expect(
        _err(await remy.send(club, randomMessageId(), starter1)),
        isA<DeniedFailure>(),
      );
    });

    test('offline is a retryable NetworkFailure', () async {
      final dead = await deadButSignedIn(priyaClient);
      final off = SupabaseStickerRepository(dead);
      final f = _err(await off.send(club, randomMessageId(), starter1));
      expect(f, isA<NetworkFailure>());
      expect((f as NetworkFailure).retryable, isTrue);
      final g = _err(await off.createAlbum('Offline'));
      expect(g, isA<NetworkFailure>());
      await dead.dispose();
    });
  });

  group('album cards and images', () {
    test(
      'share an album; the other member previews, copies and favourites it',
      () async {
        final [mine] = await ownStickers(1, upload: true);
        final album = _ok(await priya.createAlbum('Card'));
        _ok(await priya.addToAlbum(album, mine));
        _ok(await priya.addToAlbum(album, starter1));
        final card = randomMessageId();
        _ok(await priya.sendAlbum(club, card, album));
        final r = await row(quinlanClient, card);
        expect(
          (r['body'], r['sticker_album'], r['sticker_album_id']),
          ('Card', true, album),
        );
        final loaded = _ok(await quinlanChat.messages(club))
            .singleWhere((m) => m.id == card);
        expect(
          (loaded.albumCard, loaded.albumId, loaded.body),
          (true, album, 'Card'),
        );
        final convs = _ok(await quinlanChat.conversations());
        expect(
          convs.singleWhere((c) => c.id == club).lastMessage,
          stickerAlbumPreviewText,
        );

        expect(_ok(await quinlan.albumStickers(album)), [mine, starter1]);
        expect(_ok(await quinlan.image(mine)), webp);
        final copy = _ok(await quinlan.addSharedAlbum(album));
        final q = _ok(await quinlan.albums()).singleWhere((a) => a.id == copy);
        expect(q.name, 'Card');
        expect(_ok(await quinlan.albumStickers(copy)), [mine, starter1]);
        expect(_ok(await quinlan.addSharedAlbumToFavourites(album)), 2);
        expect(_ok(await quinlan.favourites()).toSet(), {mine, starter1});
        expect(_err(await remy.addSharedAlbum(album)), isA<DeniedFailure>());
      },
    );

    test(
      'image: the owner reads it; another member only once it is sent',
      () async {
        final [mine] = await ownStickers(1, upload: true);
        expect(_ok(await priya.image(mine)), webp);
        expect(await quinlan.image(mine), isA<Err<Uint8List>>());
        _ok(await priya.send(club, randomMessageId(), mine));
        expect(_ok(await quinlan.image(mine)), webp);
        expect(await remy.image(mine), isA<Err<Uint8List>>());
      },
    );
  });
}
