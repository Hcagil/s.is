// Make your own sticker (10b) in a real MessageScreen opened as production
// opens it, written from the contract and the approved mock
// (.private/mockups/sticker-maker, its click test): two start points (the
// panel's "+ New" tab with its small card, and an album's "Add", which opens
// the gallery directly); gallery -> square crop -> cut-out -> editor (text,
// draw) -> save. The cut-out step shows only when the phone can cut out;
// otherwise the "no support" notice and the editor at once. While the mask
// is pending the brush is disabled with a "preparing" hint; a null mask, or
// none within stickerCutoutTimeout, is the "unavailable" notice and the
// whole photo. Notices live 2 s on an overlay timer, so tests flush them.
// The pixels the save step hands to the encoder are the observable result:
// a cut-out leaves the background transparent, the whole image keeps it.
// Fakes only at the boundaries: gallery, cropper, cutter, encoder, repository.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/domain/sticker_maker.dart';
import 'package:sis/features/chat/presentation/sticker_album_page.dart';
import 'package:sis/features/chat/presentation/sticker_maker_flow.dart'
    show stickerCutoutTimeout;
import 'package:sis/l10n/app_localizations.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';
import '../../support/sticker_fakes.dart';

Finder k(String key) => find.byKey(ValueKey(key));

/// The phone's cut-out, from the contract: [supported] answers whether the
/// phone can cut out; [mask] answers [maskAnswer] (null = no subject / not
/// ready) once [release] is called, or at once when [held] is false.
class StickerCutterFake implements StickerCutter {
  StickerCutterFake({this.canCut = true, Uint8List? mask, this.held = false})
    : maskAnswer = mask ?? halfMask();
  bool canCut;
  Uint8List? maskAnswer;
  bool held;
  final maskCalls = <Uint8List>[];
  Completer<void>? _gate;

  /// Left half subject (255), right half background (0).
  static Uint8List halfMask() {
    final m = Uint8List(stickerSide * stickerSide);
    for (var y = 0; y < stickerSide; y++) {
      for (var x = 0; x < stickerSide ~/ 2; x++) {
        m[y * stickerSide + x] = 255;
      }
    }
    return m;
  }

  void release() => _gate?.complete();

  @override
  Future<bool> supported() async => canCut;

  @override
  Future<Uint8List?> mask(Uint8List jpeg) async {
    maskCalls.add(jpeg);
    if (held) {
      _gate = Completer<void>();
      await _gate!.future;
    }
    return maskAnswer;
  }
}

class Env {
  Env({
    StickerRepoFake? repo,
    StickerCutterFake? cutter,
    StickerEncoderFake? encoder,
  }) : repo = repo ?? (StickerRepoFake()..albumList.addAll(albums())),
       cutter = cutter ?? StickerCutterFake(),
       encoder = encoder ?? StickerEncoderFake();
  final StickerRepoFake repo;
  final StickerCutterFake cutter;
  final StickerEncoderFake encoder;
  final gallery = GalleryFake(
    photos: [for (var i = 0; i < 4; i++) GalleryPhoto('p$i')],
  );
  final cropper = PictureCropperFake(output: pngOf(640, 640, shade: 90));
  late ProviderContainer c;

  static List<StickerAlbum> albums() => [
    const StickerAlbum(id: 'a1', name: 'Mine'),
    StickerAlbum(
      id: 'a2',
      name: 'Cats',
      stickerIds: [for (var i = 0; i < maxAlbumStickers; i++) 's$i'],
    ),
    const StickerAlbum(id: 'a3', name: 'Dogs'),
  ];

  List<Override> get overrides => [
    stickerRepositoryProvider.overrideWithValue(repo),
    recentStickerStoreProvider.overrideWithValue(RecentStickerStoreFake()),
    stickerCutterProvider.overrideWithValue(cutter),
    stickerEncoderProvider.overrideWithValue(encoder),
    galleryProvider.overrideWithValue(gallery),
    pictureCropperProvider.overrideWithValue(cropper),
  ];

  /// The pixels handed to the encoder by the last save.
  Uint8List get saved => encoder.inputs.last;
  int alphaAt(int x, int y) => saved[(y * stickerSide + x) * 4 + 3];
}

/// Lets real work (image decoding, rendering) run outside the fake clock
/// until [done] holds.
Future<void> until(
  WidgetTester t,
  bool Function() done,
  String what, {
  int tries = 150,
}) async {
  for (var i = 0; i < tries; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
    if (done()) {
      await t.pump(const Duration(milliseconds: 400));
      return;
    }
  }
  fail('never: $what');
}

bool shown(String key) => k(key).hitTestable().evaluate().isNotEmpty;

final en = lookupAppLocalizations(const Locale('en'));

bool said(String text) => find.text(text).evaluate().isNotEmpty;

/// Lets a notice's 2 s overlay timer run out, so no timer outlives the test.
Future<void> flushNotice(WidgetTester t) => t.pump(const Duration(seconds: 3));

Future<void> tap(WidgetTester t, String key) async {
  await t.ensureVisible(k(key));
  await t.pump(const Duration(milliseconds: 50));
  await t.tap(k(key).hitTestable());
  await t.pump(const Duration(milliseconds: 50));
}

/// Tap [key], then wait until [next] is on screen.
Future<void> go(WidgetTester t, String key, String next) async {
  await tap(t, key);
  await until(t, () => shown(next), '$next after $key');
}

Future<Env> openChatWith(WidgetTester t, Env e) async {
  e.c = await openChat(t, overrides: e.overrides);
  await t.pumpAndSettle();
  return e;
}

Future<void> openPanel(WidgetTester t) async {
  await t.tap(k('composer-stickers'));
  await t.pumpAndSettle();
  expect(k('sticker-panel'), findsOneWidget);
}

/// The "+ New" tab (the fifth) brought into view and tapped.
Future<void> tapNew(WidgetTester t) async {
  final y = t.getCenter(k('sticker-tab-0').hitTestable()).dy;
  for (
    var n = 0;
    n < 10 && k('sticker-tab-4').hitTestable().evaluate().isEmpty;
    n++
  ) {
    await t.dragFrom(Offset(200, y), const Offset(-120, 0));
    await t.pumpAndSettle();
  }
  await tap(t, 'sticker-tab-4');
  await until(t, () => shown('maker-start-card'), 'the start card');
}

/// From the chat to the gallery through the panel's card.
Future<void> toGallery(WidgetTester t) async {
  await openPanel(t);
  await tapNew(t);
  await go(t, 'maker-use-photo', 'sticker-gallery-page');
}

/// Gallery photo -> crop screen -> Use.
Future<void> pickAndCrop(WidgetTester t, {String photo = 'p1'}) async {
  await until(t, () => shown('sticker-gallery-photo-$photo'), 'photo $photo');
  await tap(t, 'sticker-gallery-photo-$photo');
  await until(t, () {
    final use = k('crop-use').hitTestable().evaluate();
    if (use.isEmpty) return false;
    final w = use.first.widget;
    return w is! ButtonStyleButton || w.onPressed != null;
  }, 'the crop screen ready');
  await t.tap(k('crop-use'));
}

/// A finger stroke across the middle of the preview, between the fractions
/// [from] and [to] of its width.
Future<void> brush(WidgetTester t, {double from = 0.3, double to = 0.7}) async {
  await t.pump(const Duration(milliseconds: 400));
  final r = t.getRect(k('maker-preview').hitTestable().first);
  final g = await t.startGesture(Offset(r.left + r.width * from, r.center.dy));
  for (var i = 1; i <= 8; i++) {
    await g.moveBy(Offset(r.width * (to - from) / 8, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pump(const Duration(milliseconds: 100));
}

/// Editor -> save page -> Save into [album] -> the "saved" confirmation.
Future<void> saveTo(
  WidgetTester t,
  Env e,
  String album, {
  bool fav = false,
}) async {
  await go(t, 'maker-next', 'sticker-save-page');
  await tap(t, 'maker-album-$album');
  if (fav) await tap(t, 'maker-fav');
  final before = e.encoder.inputs.length;
  await tap(t, 'maker-save');
  await until(
    t,
    () => e.encoder.inputs.length > before && shown('maker-saved'),
    'saved',
  );
}

void main() {
  group('panel start', () {
    testWidgets(
      '"+ New" opens the small card; Cancel closes it, nothing else',
      (t) async {
        final e = await openChatWith(t, Env());
        await openPanel(t);
        await tapNew(t);
        expect(k('maker-use-photo'), findsOneWidget);
        await tap(t, 'maker-cancel-card');
        await t.pumpAndSettle();
        expect(k('maker-start-card'), findsNothing);
        expect(k('sticker-gallery-page'), findsNothing);
        expect(e.gallery.accessRequests, 0);
      },
    );

    testWidgets(
      'Use a photo -> gallery; back returns to the chat, nothing saved',
      (t) async {
        final e = await openChatWith(t, Env());
        await toGallery(t);
        await until(t, () => shown('sticker-gallery-photo-p0'), 'the grid');
        await osBack(t);
        await t.pumpAndSettle();
        expect(k('sticker-gallery-page'), findsNothing);
        expect(k('maker-start-card'), findsNothing);
        expect(e.repo.made, isEmpty);
      },
    );

    testWidgets(
      'the whole way: crop, cut-out, editor, save to an album and favourites',
      (t) async {
        final e = await openChatWith(t, Env());
        await toGallery(t);
        await pickAndCrop(t, photo: 'p2');
        await until(t, () => shown('sticker-cutout-page'), 'the cut-out step');
        expect(e.gallery.cropLoads, ['p2']);
        expect(e.cropper.calls, hasLength(1));
        await until(t, () => e.cutter.maskCalls.isNotEmpty, 'the mask asked');
        await tap(t, 'maker-mode-1');
        await go(t, 'maker-ok', 'sticker-editor-page');
        await saveTo(t, e, 'a3', fav: true);
        expect(e.saved.length, stickerSide * stickerSide * 4);
        expect(e.alphaAt(60, 256), 255, reason: 'the subject stays');
        expect(e.alphaAt(450, 256), 0, reason: 'the background is cut away');
        final [id] = e.repo.made.keys.toList();
        expect(e.repo.albumList.singleWhere((a) => a.id == 'a3').stickerIds, [
          id,
        ]);
        expect(e.repo.favs, [id]);
        expect(e.repo.made[id], e.encoder.output);
      },
    );

    testWidgets('Done after saving closes the maker back to the chat', (
      t,
    ) async {
      final e = await openChatWith(
        t,
        Env(cutter: StickerCutterFake(canCut: false)),
      );
      await toGallery(t);
      await pickAndCrop(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
      await saveTo(t, e, 'a1');
      await tap(t, 'maker-done');
      await t.pumpAndSettle();
      for (final page in [
        'sticker-save-page',
        'sticker-editor-page',
        'sticker-cutout-page',
        'sticker-gallery-page',
        'maker-start-card',
      ]) {
        expect(k(page), findsNothing, reason: page);
      }
      expect(k('composer-stickers'), findsOneWidget);
    });
  });

  group('album start', () {
    Future<Env> openAlbum(WidgetTester t, Env e) async {
      await pumpLauncher(
        t,
        (context, ref) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const StickerAlbumPage(albumId: 'a1', conversationId: 'c1'),
          ),
        ),
        overrides: e.overrides,
      );
      await until(t, () => shown('sticker-album-add'), 'the album page');
      return e;
    }

    testWidgets('Add opens the gallery directly, no start card', (t) async {
      final e = await openAlbum(t, Env());
      await go(t, 'sticker-album-add', 'sticker-gallery-page');
      expect(k('maker-start-card'), findsNothing);
      expect(e.gallery.accessRequests, greaterThan(0));
    });

    testWidgets('a sticker made from an album lands in that album', (t) async {
      final e = await openAlbum(
        t,
        Env(cutter: StickerCutterFake(canCut: false)),
      );
      await go(t, 'sticker-album-add', 'sticker-gallery-page');
      await pickAndCrop(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
      await go(t, 'maker-next', 'sticker-save-page');
      final before = e.encoder.inputs.length;
      await tap(t, 'maker-save');
      await until(
        t,
        () => e.encoder.inputs.length > before && shown('maker-saved'),
        'saved',
      );
      final [id] = e.repo.made.keys.toList();
      expect(e.repo.albumList.singleWhere((a) => a.id == 'a1').stickerIds, [
        id,
      ]);
      expect(
        e.repo.albumList.singleWhere((a) => a.id == 'a3').stickerIds,
        isEmpty,
      );
      expect(e.repo.favs, isEmpty);
      await flushNotice(t); // the no-support notice
    });
  });

  group('gallery', () {
    testWidgets('no photo access shows the Allow button, no photos', (t) async {
      final e = Env();
      e.gallery.access = GalleryAccess.denied;
      await openChatWith(t, e);
      await toGallery(t);
      await until(t, () => shown('sticker-gallery-allow'), 'the allow button');
      expect(k('sticker-gallery-photo-p0'), findsNothing);
    });

    testWidgets('back from the crop returns to the gallery', (t) async {
      final e = await openChatWith(t, Env());
      await toGallery(t);
      await until(t, () => shown('sticker-gallery-photo-p3'), 'the grid');
      await tap(t, 'sticker-gallery-photo-p3');
      await until(t, () => shown('crop-use'), 'the crop');
      await osBack(t);
      await until(t, () => shown('sticker-gallery-photo-p3'), 'the grid again');
      expect(e.cropper.calls, isEmpty);
      expect(e.cutter.maskCalls, isEmpty);
    });
  });

  group('cut-out', () {
    Future<Env> toCutout(WidgetTester t, Env e) async {
      await openChatWith(t, e);
      await toGallery(t);
      await pickAndCrop(t);
      await until(t, () => shown('sticker-cutout-page'), 'the cut-out step');
      await until(t, () => e.cutter.maskCalls.isNotEmpty, 'the mask asked');
      return e;
    }

    Future<void> finish(WidgetTester t, Env e) async {
      await go(t, 'maker-ok', 'sticker-editor-page');
      await saveTo(t, e, 'a1');
    }

    testWidgets(
      'a phone that cannot cut out: the no-support notice, straight to the editor, whole photo kept',
      (t) async {
        final e = await openChatWith(
          t,
          Env(cutter: StickerCutterFake(canCut: false)),
        );
        await toGallery(t);
        await pickAndCrop(t);
        await until(t, () => shown('sticker-editor-page'), 'the editor');
        expect(said(en.makerCutoutNoSupport), isTrue);
        expect(said(en.makerCutoutUnavailable), isFalse);
        expect(k('sticker-cutout-page'), findsNothing);
        expect(e.cutter.maskCalls, isEmpty);
        await flushNotice(t);
        await saveTo(t, e, 'a1');
        expect(e.alphaAt(60, 256), 255);
        expect(e.alphaAt(450, 256), 255);
      },
    );

    testWidgets('Whole image hides the brush tools; Cut-out shows them', (
      t,
    ) async {
      await toCutout(t, Env());
      await tap(t, 'maker-mode-0');
      for (final tool in [
        'maker-brush-0',
        'maker-brush-1',
        'maker-undo',
        'maker-reset',
      ]) {
        expect(shown(tool), isFalse, reason: '$tool in Whole image');
      }
      await tap(t, 'maker-mode-1');
      for (final tool in [
        'maker-brush-0',
        'maker-brush-1',
        'maker-undo',
        'maker-reset',
      ]) {
        expect(shown(tool), isTrue, reason: '$tool in Cut-out');
      }
    });

    testWidgets('Whole image keeps the background even with a mask', (t) async {
      final e = await toCutout(t, Env());
      await tap(t, 'maker-mode-0');
      await finish(t, e);
      expect(e.alphaAt(60, 256), 255);
      expect(e.alphaAt(450, 256), 255);
    });

    testWidgets('no mask: the unavailable notice, no brush, the whole photo', (
      t,
    ) async {
      final logs = <String?>[];
      final old = debugPrint;
      debugPrint = (m, {wrapWidth}) => logs.add(m);
      try {
        final e = await toCutout(
          t,
          Env(cutter: StickerCutterFake(mask: null)..maskAnswer = null),
        );
        await until(t, () => said(en.makerCutoutUnavailable), 'the notice');
        expect(said(en.makerCutoutNoSupport), isFalse);
        expect(find.byType(SnackBar), findsNothing);
        expect(logs, isEmpty, reason: 'the old debugPrint is gone: $logs');
        for (final tool in ['maker-brush-0', 'maker-brush-1', 'maker-undo']) {
          expect(
            shown(tool),
            isFalse,
            reason: 'Whole image is the result, $tool',
          );
        }
        expect(said(en.makerCutoutPreparing), isFalse);
        await flushNotice(t);
        await finish(t, e);
        expect(e.alphaAt(60, 256), 255);
        expect(
          e.alphaAt(450, 256),
          255,
          reason: 'nothing may be cut without a mask',
        );
      } finally {
        debugPrint = old;
      }
    });

    testWidgets(
      'pending mask: brush disabled with the preparing hint; enabled when it arrives',
      (t) async {
        final e = await toCutout(t, Env(cutter: StickerCutterFake(held: true)));
        expect(shown('maker-brush-0'), isTrue, reason: 'row stays, disabled');
        expect(said(en.makerCutoutPreparing), isTrue);
        expect(said(en.makerBrushHint), isFalse);
        // A Restore tap while pending must be ignored, so the stroke below
        // (over the background) stays Erase and changes nothing.
        await t.tap(k('maker-brush-1'), warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 100));
        e.cutter.release();
        await until(t, () => said(en.makerBrushHint), 'the brush hint');
        expect(said(en.makerCutoutPreparing), isFalse);
        expect(said(en.makerCutoutUnavailable), isFalse);
        await brush(t, from: 0.6, to: 0.9);
        await finish(t, e);
        expect(e.alphaAt(384, 256), 0, reason: 'the pending tap was ignored');
        expect(e.alphaAt(60, 256), 255, reason: 'the subject stays');
        await osBack(t); // save -> editor
        await until(t, () => shown('sticker-editor-page'), 'the editor');
        await osBack(t); // editor -> cut-out
        await until(t, () => shown('sticker-cutout-page'), 'the cut-out');
        await tap(t, 'maker-brush-1');
        await brush(t, from: 0.6, to: 0.9);
        await finish(t, e);
        expect(e.alphaAt(384, 256), 255, reason: 'Restore works once ready');
      },
    );

    testWidgets(
      'no mask within the timeout: the unavailable notice and the whole photo',
      (t) async {
        expect(stickerCutoutTimeout, const Duration(seconds: 20));
        final e = await toCutout(t, Env(cutter: StickerCutterFake(held: true)));
        await t.pump(const Duration(seconds: 18));
        expect(said(en.makerCutoutPreparing), isTrue, reason: 'still waiting');
        expect(said(en.makerCutoutUnavailable), isFalse);
        await t.pump(const Duration(seconds: 2));
        await t.pump();
        expect(said(en.makerCutoutUnavailable), isTrue);
        expect(said(en.makerCutoutPreparing), isFalse);
        expect(shown('maker-brush-0'), isFalse, reason: 'the brush row goes');
        await flushNotice(t);
        await finish(t, e);
        expect(e.alphaAt(60, 256), 255);
        expect(e.alphaAt(450, 256), 255, reason: 'the whole photo is kept');
      },
    );

    testWidgets(
      'Erase removes the subject under the stroke; Undo brings it back',
      (t) async {
        final e = await toCutout(t, Env());
        await tap(t, 'maker-mode-1');
        await tap(t, 'maker-brush-0');
        await brush(t, from: 0.1, to: 0.4);
        await finish(t, e);
        expect(e.alphaAt(128, 256), 0, reason: 'erased');
        expect(e.alphaAt(128, 60), 255, reason: 'outside the stroke');
        await osBack(t); // save -> editor
        await until(t, () => shown('sticker-editor-page'), 'the editor');
        await osBack(t); // editor -> cut-out
        await until(t, () => shown('sticker-cutout-page'), 'the cut-out');
        await tap(t, 'maker-undo');
        await finish(t, e);
        expect(e.alphaAt(128, 256), 255, reason: 'undo gave it back');
      },
    );

    testWidgets(
      'Restore brings back background under the stroke; Reset drops every stroke',
      (t) async {
        final e = await toCutout(t, Env());
        await tap(t, 'maker-mode-1');
        await tap(t, 'maker-brush-1');
        await brush(t, from: 0.6, to: 0.9);
        await finish(t, e);
        expect(e.alphaAt(384, 256), 255, reason: 'restored');
        expect(e.alphaAt(384, 60), 0, reason: 'outside the stroke');
        await osBack(t);
        await until(t, () => shown('sticker-editor-page'), 'the editor');
        await osBack(t);
        await until(t, () => shown('sticker-cutout-page'), 'the cut-out');
        await tap(t, 'maker-brush-0');
        await brush(t, from: 0.1, to: 0.4);
        await tap(t, 'maker-reset');
        await finish(t, e);
        expect(e.alphaAt(384, 256), 0, reason: 'restore stroke reset');
        expect(e.alphaAt(128, 256), 255, reason: 'erase stroke reset');
      },
    );

    testWidgets('switching Whole/Cut-out keeps strokes undoable', (t) async {
      final e = await toCutout(t, Env());
      await tap(t, 'maker-mode-1');
      await tap(t, 'maker-brush-0');
      await brush(t, from: 0.1, to: 0.4);
      await tap(t, 'maker-mode-0');
      await tap(t, 'maker-mode-1');
      await tap(t, 'maker-undo');
      await finish(t, e);
      expect(e.alphaAt(128, 256), 255);
    });
  });

  group('editor', () {
    Future<Env> toEditor(WidgetTester t) async {
      final e = await openChatWith(
        t,
        Env(cutter: StickerCutterFake(canCut: false)),
      );
      await toGallery(t);
      await pickAndCrop(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
      return e;
    }

    /// Pixels that differ from the plain photo saved first.
    int changed(Env e) {
      final a = e.encoder.inputs.first, b = e.encoder.inputs.last;
      var n = 0;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) n++;
      }
      return n;
    }

    /// Save once as a baseline, come back to the editor.
    Future<void> baseline(WidgetTester t, Env e) async {
      await saveTo(t, e, 'a1');
      await osBack(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
    }

    Future<void> resave(WidgetTester t, Env e) => saveTo(t, e, 'a3');

    testWidgets('text OK puts the text on the sticker', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      await go(t, 'maker-text', 'sticker-text-page');
      await t.enterText(k('maker-text-field'), 'Hi <3 & you');
      await tap(t, 'maker-font-2');
      await tap(t, 'maker-colour-1');
      await go(t, 'maker-ok', 'sticker-editor-page');
      await resave(t, e);
      expect(changed(e), greaterThan(0));
    });

    testWidgets('text Cancel drops the new text', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      await go(t, 'maker-text', 'sticker-text-page');
      await t.enterText(k('maker-text-field'), 'Gone');
      await go(t, 'maker-cancel', 'sticker-editor-page');
      await resave(t, e);
      expect(changed(e), 0);
    });

    testWidgets('text Delete removes the text', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      await go(t, 'maker-text', 'sticker-text-page');
      await t.enterText(k('maker-text-field'), 'A');
      await go(t, 'maker-ok', 'sticker-editor-page');
      await go(t, 'maker-text', 'sticker-text-page');
      await go(t, 'maker-delete', 'sticker-editor-page');
      await resave(t, e);
      expect(changed(e), 0);
    });

    testWidgets('draw OK keeps the line; Clear removes it', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      await go(t, 'maker-draw', 'sticker-draw-page');
      await tap(t, 'maker-width-2');
      await tap(t, 'maker-colour-2');
      await brush(t, from: 0.2, to: 0.8);
      await go(t, 'maker-ok', 'sticker-editor-page');
      await resave(t, e);
      final drawn = changed(e);
      expect(drawn, greaterThan(0));
      await osBack(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
      await go(t, 'maker-draw', 'sticker-draw-page');
      await tap(t, 'maker-clear');
      await go(t, 'maker-ok', 'sticker-editor-page');
      await resave(t, e);
      expect(changed(e), 0);
    });

    testWidgets('draw Cancel drops the new line', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      await go(t, 'maker-draw', 'sticker-draw-page');
      await brush(t, from: 0.2, to: 0.8);
      await go(t, 'maker-cancel', 'sticker-editor-page');
      await resave(t, e);
      expect(changed(e), 0);
    });

    testWidgets('a thick line changes more pixels than a thin one', (t) async {
      final e = await toEditor(t);
      await baseline(t, e);
      Future<int> line(String width) async {
        await go(t, 'maker-draw', 'sticker-draw-page');
        await tap(t, 'maker-clear');
        await tap(t, width);
        await brush(t, from: 0.2, to: 0.8);
        await go(t, 'maker-ok', 'sticker-editor-page');
        await resave(t, e);
        await osBack(t);
        await until(t, () => shown('sticker-editor-page'), 'the editor');
        return changed(e);
      }

      final thin = await line('maker-width-0');
      final thick = await line('maker-width-2');
      expect(thick, greaterThan(thin));
    });
  });

  group('save', () {
    Future<Env> toSave(WidgetTester t, Env e) async {
      await openChatWith(t, e);
      await toGallery(t);
      await pickAndCrop(t);
      await until(t, () => shown('sticker-editor-page'), 'the editor');
      await go(t, 'maker-next', 'sticker-save-page');
      return e;
    }

    Env plain({StickerRepoFake? repo, StickerEncoderFake? encoder}) => Env(
      repo: repo,
      cutter: StickerCutterFake(canCut: false),
      encoder: encoder,
    );

    testWidgets('a full album cannot be picked', (t) async {
      final e = await toSave(t, plain());
      await tap(t, 'maker-album-a3');
      await t.tap(k('maker-album-a2'), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 100));
      await tap(t, 'maker-save');
      await until(t, () => shown('maker-saved'), 'saved');
      final [id] = e.repo.made.keys.toList();
      expect(e.repo.albumList.singleWhere((a) => a.id == 'a3').stickerIds, [
        id,
      ]);
      expect(
        e.repo.albumList.singleWhere((a) => a.id == 'a2').stickerIds,
        isNot(contains(id)),
      );
      await flushNotice(t); // the no-support notice
    });

    testWidgets('New album adds an album, and stops at the album limit', (
      t,
    ) async {
      final e = await toSave(t, plain());
      for (var n = 3; n < maxStickerAlbums; n++) {
        await tap(t, 'maker-new-album');
        await until(
          t,
          () => find.text('Create').evaluate().isNotEmpty,
          'the name dialog',
        );
        await t.enterText(find.byType(TextField).last, 'Made $n');
        await t.tap(find.text('Create'));
        await until(
          t,
          () => e.repo.albumList.length == n + 1,
          'album ${n + 1}',
        );
      }
      expect(e.repo.albumList.last.name, 'Made 9');
      await t.tap(k('maker-new-album'), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 300));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(e.repo.albumList, hasLength(maxStickerAlbums));
      expect(
        find.text('Create'),
        findsNothing,
        reason: 'no name dialog at the limit',
      );
    });

    testWidgets('favourite off by default; the toggle turns it on and off', (
      t,
    ) async {
      final e = await toSave(t, plain());
      await tap(t, 'maker-album-a1');
      await tap(t, 'maker-fav');
      await tap(t, 'maker-fav');
      await tap(t, 'maker-save');
      await until(t, () => shown('maker-saved'), 'saved');
      expect(e.repo.made, hasLength(1));
      expect(e.repo.favs, isEmpty);
      await flushNotice(t); // the no-support notice
    });

    testWidgets(
      'an encoder that cannot fit the sticker: the failure notice, nothing saved',
      (t) async {
        final e = await toSave(
          t,
          plain(encoder: StickerEncoderFake()..output = null),
        );
        await tap(t, 'maker-album-a1');
        await tap(t, 'maker-save');
        await until(
          t,
          () => find
              .text('Could not save the sticker. Try again.')
              .evaluate()
              .isNotEmpty,
          'the notice',
        );
        expect(k('maker-saved'), findsNothing);
        expect(k('sticker-save-page'), findsOneWidget);
        expect(e.repo.made, isEmpty);
        expect(e.repo.calls.where((c) => c.startsWith('create')), isEmpty);
        await t.pump(const Duration(seconds: 10)); // the notice times out
      },
    );

    testWidgets(
      'at 700 owned stickers: the limit notice, nothing saved, can retry',
      (t) async {
        final repo = StickerRepoFake(owned: 700)
          ..albumList.addAll(Env.albums());
        await toSave(t, plain(repo: repo));
        await tap(t, 'maker-album-a1');
        await tap(t, 'maker-save');
        await until(
          t,
          () => find
              .text('You have reached the sticker limit.')
              .evaluate()
              .isNotEmpty,
          'the limit notice',
        );
        expect(k('maker-saved'), findsNothing);
        expect(repo.made, isEmpty);
        expect(
          repo.albumList.singleWhere((a) => a.id == 'a1').stickerIds,
          isEmpty,
        );
        repo.owned = 10;
        await tap(t, 'maker-save');
        await until(t, () => shown('maker-saved'), 'saved on retry');
        expect(repo.made, hasLength(1));
        await t.pump(const Duration(seconds: 10)); // the notice times out
      },
    );

    testWidgets('Save is not taken twice while the first is running', (
      t,
    ) async {
      final e = await toSave(
        t,
        plain(
          encoder: StickerEncoderFake(
            latency: const Duration(milliseconds: 400),
          ),
        ),
      );
      await tap(t, 'maker-album-a1');
      await t.tap(k('maker-save'));
      await t.pump(const Duration(milliseconds: 80)); // a quick second tap
      await t.tap(k('maker-save'), warnIfMissed: false);
      await until(t, () => shown('maker-saved'), 'saved');
      expect(e.repo.made, hasLength(1));
    });
  });
}
