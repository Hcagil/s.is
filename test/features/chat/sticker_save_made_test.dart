// StickerLibraryController.saveMade, written from the contract: encode the
// 512x512 RGBA, create the sticker from the WebP, put it in [albumId] and, if
// [favourite], in the favourites; returns null or the Failure. Encode null is
// StickerMakeFailure and nothing reaches the server; a failed create is
// returned as it is (STKS1 -> StickerLimitFailure) and adds nothing.
// Fakes only at the boundaries (StickerRepoFake, StickerEncoderFake).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/domain/sticker_maker.dart';

import '../../support/sticker_fakes.dart';

class _Me extends CurrentUserId {
  @override
  String? build() => 'u1';
}

final rgba = Uint8List(stickerSide * stickerSide * 4)..[0] = 9;
final webp = Uint8List.fromList([82, 73, 70, 70, 1, 2, 3]);

class Env {
  Env({StickerRepoFake? repo, StickerEncoderFake? encoder})
    : repo = repo ?? StickerRepoFake(),
      encoder = encoder ?? StickerEncoderFake(output: webp) {
    c = ProviderContainer(
      overrides: [
        stickerRepositoryProvider.overrideWithValue(this.repo),
        recentStickerStoreProvider.overrideWithValue(RecentStickerStoreFake()),
        stickerEncoderProvider.overrideWithValue(this.encoder),
        currentUserIdProvider.overrideWith(_Me.new),
      ],
    );
    c.listen(stickerLibraryProvider, (_, _) {});
  }
  final StickerRepoFake repo;
  final StickerEncoderFake encoder;
  late final ProviderContainer c;

  StickerLibraryController get lib => c.read(stickerLibraryProvider.notifier);
  StickerLibrary get state => c.read(stickerLibraryProvider);
  List<String> get changes => [
    for (final s in repo.calls)
      if (!{'albums', 'favourites'}.contains(s)) s,
  ];
}

Future<Env> env({StickerRepoFake? repo, StickerEncoderFake? encoder}) async {
  final e = Env(repo: repo, encoder: encoder);
  addTearDown(e.c.dispose);
  await e.lib.refresh();
  return e;
}

void main() {
  test('saves: encodes the pixels, creates from the WebP, adds to the album '
      'and the favourites, in that order', () async {
    final repo = StickerRepoFake()
      ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
    final e = await env(repo: repo);
    final f = await e.lib.saveMade(rgba, albumId: 'a1', favourite: true);
    expect(f, isNull);
    expect(e.encoder.inputs, [same(rgba)]);
    final [id] = repo.made.keys.toList();
    expect(repo.made[id], same(webp));
    expect(e.changes, [
      'create ${webp.length}',
      'addToAlbum a1 $id',
      'addFavourite $id',
    ]);
    expect(repo.albumList.single.stickerIds, [id]);
    expect(repo.favs, [id]);
    expect(e.state.albums.single.stickerIds, [id]);
    expect(e.state.favourites, [id]);
  });

  test('favourite false: in the album only', () async {
    final repo = StickerRepoFake()
      ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
    final e = await env(repo: repo);
    expect(await e.lib.saveMade(rgba, albumId: 'a1'), isNull);
    final [id] = repo.made.keys.toList();
    expect(e.changes, ['create ${webp.length}', 'addToAlbum a1 $id']);
    expect(repo.favs, isEmpty);
    expect(e.state.favourites, isEmpty);
    expect(e.state.albums.single.stickerIds, [id]);
  });

  test(
    'encode gives null: StickerMakeFailure, nothing reaches the server',
    () async {
      final repo = StickerRepoFake()
        ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
      final e = await env(
        repo: repo,
        encoder: StickerEncoderFake()..output = null,
      );
      final f = await e.lib.saveMade(rgba, albumId: 'a1', favourite: true);
      expect(f, isA<StickerMakeFailure>());
      expect(e.changes, isEmpty);
      expect(repo.made, isEmpty);
    },
  );

  test(
    '700 owned: StickerLimitFailure STKS1, no album or favourite change',
    () async {
      final repo = StickerRepoFake(owned: 700)
        ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
      final e = await env(repo: repo);
      final f = await e.lib.saveMade(rgba, albumId: 'a1', favourite: true);
      expect(f, isA<StickerLimitFailure>());
      expect((f as StickerLimitFailure).code, 'STKS1');
      expect(e.changes, ['create ${webp.length}']);
      expect(repo.albumList.single.stickerIds, isEmpty);
      expect(repo.favs, isEmpty);
    },
  );

  test(
    'create offline: the NetworkFailure comes back, nothing added',
    () async {
      final repo = StickerRepoFake()
        ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
      final e = await env(repo: repo);
      repo.offline = true;
      final f = await e.lib.saveMade(rgba, albumId: 'a1', favourite: true);
      expect(f, isA<NetworkFailure>());
      expect(e.changes, ['create ${webp.length}']);
    },
  );

  test('create denied: the DeniedFailure comes back, nothing added', () async {
    final repo = StickerRepoFake()
      ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
    final e = await env(repo: repo);
    repo.failNext = const DeniedFailure();
    final f = await e.lib.saveMade(rgba, albumId: 'a1', favourite: true);
    expect(f, isA<DeniedFailure>());
    expect(e.changes, ['create ${webp.length}']);
  });

  test('a full album (STKA2): that failure comes back', () async {
    final repo = StickerRepoFake()
      ..albumList.add(
        StickerAlbum(
          id: 'a1',
          name: 'Full',
          stickerIds: [for (var i = 0; i < maxAlbumStickers; i++) 's$i'],
        ),
      );
    final e = await env(repo: repo);
    final f = await e.lib.saveMade(rgba, albumId: 'a1');
    expect(f, isA<StickerLimitFailure>());
    expect((f as StickerLimitFailure).code, 'STKA2');
  });

  test('a slow encoder: create waits for its WebP', () async {
    final repo = StickerRepoFake()
      ..albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
    final e = await env(
      repo: repo,
      encoder: StickerEncoderFake(
        output: webp,
        latency: const Duration(milliseconds: 50),
      ),
    );
    expect(await e.lib.saveMade(rgba, albumId: 'a1'), isNull);
    expect(repo.made.values.single, same(webp));
  });
}
