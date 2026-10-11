@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/imcodec_sticker_encoder.dart';
import 'package:sis/features/chat/data/supabase_sticker_repository.dart';
import 'package:sis/features/chat/domain/sticker_maker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/service_key.dart';
import '../support/sticker_fakes.dart';

/// Making a sticker (10b) on the real local stack, written from the contract:
/// [SupabaseStickerRepository.create] asks create_sticker() for a row, then
/// uploads the WebP as `<id>.webp` to the private `stickers` bucket (at most
/// 100 KB, image/webp). STKS1 at 700 owned is StickerLimitFailure('STKS1').
/// When the upload fails the repository calls discard_sticker(id), so no row
/// is left behind, and returns the upload's error. Offline is a retryable
/// NetworkFailure. The seam: StickerLibraryController.saveMade with the real
/// encoder and the real repository puts the new sticker in the album and the
/// favourites.
///
/// Accounts priya and quinlan are shared with sticker_repository_test.dart;
/// run with --concurrency=1. Every row made here is removed at the end.
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

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok: $r');
  return (r as Ok<T>).value;
}

Failure _err<T>(Result<T> r) {
  expect(r, isA<Err<T>>(), reason: 'expected Err: $r');
  return (r as Err<T>).failure;
}

class _FixedUser extends CurrentUserId {
  _FixedUser(this.id);
  final String id;
  @override
  String? build() => id;
}

/// A 512x512 opaque RGBA image (no transparency): something the encoder fits.
Uint8List _opaqueRgba() {
  final b = Uint8List(stickerSide * stickerSide * 4);
  for (var i = 0; i < b.length; i += 4) {
    b[i] = 30;
    b[i + 1] = 160;
    b[i + 2] = 90;
    b[i + 3] = 255;
  }
  return b;
}

void main() {
  late SupabaseClient priyaClient, quinlanClient, service;
  late SupabaseStickerRepository priya, quinlan;
  late String priyaId;
  final webp = Uint8List.fromList(
    File('assets/stickers/starter_03.webp').readAsBytesSync(),
  );

  Future<List<String>> ownedBy(String userId) async => [
    for (final r
        in await service.from('stickers').select('id').eq('owner_id', userId))
      r['id'] as String,
  ];

  Future<List<String>> objects() async => [
    for (final o
        in await service.storage
            .from('stickers')
            .list(searchOptions: const SearchOptions(limit: 10000)))
      o.name,
  ];

  Future<void> removeOwned(String userId) async {
    final ids = await ownedBy(userId);
    if (ids.isEmpty) return;
    for (var i = 0; i < ids.length; i += 50) {
      final part = ids.sublist(i, (i + 50).clamp(0, ids.length));
      await service.storage.from('stickers').remove([
        for (final id in part) '$id.webp',
      ]);
      await service
          .from('sticker_album_items')
          .delete()
          .inFilter('sticker_id', part);
      await service
          .from('sticker_favourites')
          .delete()
          .inFilter('sticker_id', part);
      await service.from('stickers').delete().inFilter('id', part);
    }
  }

  Future<void> clearAlbums(SupabaseStickerRepository r) async {
    for (final a in _ok(await r.albums())) {
      _ok(await r.deleteAlbum(a.id));
    }
    for (final f in _ok(await r.favourites())) {
      _ok(await r.removeFavourite(f));
    }
  }

  setUpAll(() async {
    service = _client(serviceKey());
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    priyaId = priyaClient.auth.currentUser!.id;
    priya = SupabaseStickerRepository(priyaClient);
    quinlan = SupabaseStickerRepository(quinlanClient);
  });

  setUp(() async {
    await removeOwned(priyaId);
    await clearAlbums(priya);
  });

  tearDownAll(() async {
    await removeOwned(priyaId);
    await removeOwned(quinlanClient.auth.currentUser!.id);
    await clearAlbums(priya);
    for (final c in [priyaClient, quinlanClient, service]) {
      await c.dispose();
    }
  });

  test('create stores a row owned by the member and its <id>.webp', () async {
    final id = _ok(await priya.create(webp));
    expect(await ownedBy(priyaId), [id]);
    expect(await objects(), contains('$id.webp'));
    expect(_ok(await priya.image(id)), webp);
  });

  test('two creates give two different stickers', () async {
    final a = _ok(await priya.create(webp));
    final b = _ok(await priya.create(webp));
    expect(a, isNot(b));
    expect((await ownedBy(priyaId)).toSet(), {a, b});
  });

  test(
    'another member cannot read a made sticker that was never sent',
    () async {
      final id = _ok(await priya.create(webp));
      expect(await quinlan.image(id), isA<Err<Uint8List>>());
    },
  );

  test(
    'the 701st owned sticker is StickerLimitFailure STKS1, nothing left behind',
    () async {
      await service.from('stickers').insert([
        for (var i = 0; i < 699; i++) {'owner_id': priyaId},
      ]);
      _ok(await priya.create(webp)); // the 700th fits
      final before = await objects();
      final f = _err(await priya.create(webp));
      expect(f, isA<StickerLimitFailure>());
      expect((f as StickerLimitFailure).code, 'STKS1');
      expect((await ownedBy(priyaId)).length, 700);
      expect((await objects()).length, before.length);
    },
  );

  test(
    'a failed upload discards the row and returns the upload error',
    () async {
      // over the bucket's 100 KB limit: create_sticker() succeeds, the upload is refused
      final big = Uint8List(stickerMaxBytes + 4096)..setAll(0, webp);
      final before = await objects();
      final f = _err(await priya.create(big));
      expect(f, isNot(isA<StickerLimitFailure>()));
      expect(
        await ownedBy(priyaId),
        isEmpty,
        reason: 'the row was not discarded',
      );
      expect(await objects(), unorderedEquals(before));
      // and the member can still make one right after
      final id = _ok(await priya.create(webp));
      expect(await ownedBy(priyaId), [id]);
    },
  );

  test('offline is a retryable NetworkFailure and makes nothing', () async {
    final dead = await deadButSignedIn(priyaClient);
    final f = _err(await SupabaseStickerRepository(dead).create(webp));
    expect(f, isA<NetworkFailure>());
    expect((f as NetworkFailure).retryable, isTrue);
    expect(await ownedBy(priyaId), isEmpty);
    await dead.dispose();
  });

  test('seam: saveMade with the real encoder and repository fills album and favourites', () async {
    final album = _ok(await priya.createAlbum('Made'));
    final c = ProviderContainer(
      overrides: [
        stickerRepositoryProvider.overrideWithValue(priya),
        stickerEncoderProvider.overrideWithValue(const ImcodecStickerEncoder()),
        recentStickerStoreProvider.overrideWithValue(RecentStickerStoreFake()),
        currentUserIdProvider.overrideWith(() => _FixedUser(priyaId)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(stickerLibraryProvider, (_, _) {});
    final failure = await c
        .read(stickerLibraryProvider.notifier)
        .saveMade(_opaqueRgba(), albumId: album, favourite: true);
    expect(failure, isNull);
    final [id] = await ownedBy(priyaId);
    expect(_ok(await priya.albumStickers(album)), [id]);
    expect(_ok(await priya.favourites()), contains(id));
    final stored = _ok(await priya.image(id));
    expect(stored.length, lessThanOrEqualTo(stickerMaxBytes));
    expect(String.fromCharCodes(stored.sublist(8, 12)), 'WEBP');
    final lib = c.read(stickerLibraryProvider);
    expect(lib.favourites, contains(id));
    expect(
      lib.albums.singleWhere((a) => a.id == album).stickerIds,
      contains(id),
    );
  });

  test(
    'seam: saveMade at the cap returns StickerLimitFailure and adds nothing',
    () async {
      final album = _ok(await priya.createAlbum('Full'));
      await service.from('stickers').insert([
        for (var i = 0; i < 700; i++) {'owner_id': priyaId},
      ]);
      final c = ProviderContainer(
        overrides: [
          stickerRepositoryProvider.overrideWithValue(priya),
          stickerEncoderProvider.overrideWithValue(
            const ImcodecStickerEncoder(),
          ),
          recentStickerStoreProvider.overrideWithValue(
            RecentStickerStoreFake(),
          ),
          currentUserIdProvider.overrideWith(() => _FixedUser(priyaId)),
        ],
      );
      addTearDown(c.dispose);
      c.listen(stickerLibraryProvider, (_, _) {});
      final failure = await c
          .read(stickerLibraryProvider.notifier)
          .saveMade(_opaqueRgba(), albumId: album, favourite: true);
      expect(failure, isA<StickerLimitFailure>());
      expect(_ok(await priya.albumStickers(album)), isEmpty);
      expect(_ok(await priya.favourites()), isEmpty);
    },
  );
}
