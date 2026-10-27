// The big photo view a tapped grid photo opens, written from its contract,
// never from its widgets:
//
//  - showAttachmentPreview(context, photos:, picked:, initial:, caption:)
//    opens on photos[initial] and swipes through all of them; it resolves
//    with (images, caption) on Send, or null on back.
//  - Title preview-count reads "n / total". The tick (preview-tick, labelled
//    attachTickSelect / attachTickSelected) toggles the shared PhotoTicks.
//  - preview-crop opens the free crop screen: Done keeps the cropped picture
//    and ticks the photo; Cancel changes nothing.
//  - One caption field (preview-caption), prefilled. preview-send carries a
//    count badge (preview-badge) and sends the ticked photos, or the viewed
//    photo when none is ticked. preview-thumbs shows the ticked photos only.
//  - The route fades and grows; it never pushes in sideways. Neither does
//    the free crop screen's.
//  - The background follows the theme; the page opts out of swipe-back.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';
import 'package:sis/features/chat/presentation/free_crop_screen.dart';
import 'package:sis/features/chat/presentation/photo_ticks.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/attach_flow.dart' show key, previewCaption;
import '../../support/chat_launcher.dart'
    show osBack, phoneView, platforms, screenHeight, screenWidth, stroke;
import '../../support/crop_fakes.dart';
import '../../support/fakes.dart';

typedef Sent = ({List<PickedImage> images, String caption});

/// Per photo id: what load() gives (to send) and what loadForCrop() gives.
final sendable = <String, PickedImage>{};
final croppable = <String, PickedImage>{};
late PickedImage cutA;
late PickedImage cutB;

List<GalleryPhoto> lib(int n) => [
  for (var i = 0; i < n; i++) GalleryPhoto('p$i'),
];

class Host {
  Host(
    this.n, {
    this.initial = 0,
    this.caption = '',
    List<String> ticked = const [],
    this.dark = false,
    RendererFake? renderer,
  }) : renderer = renderer ?? RendererFake(answer: cutA) {
    for (final p in photos) {
      gallery.loadResults[p.id] = sendable[p.id];
      gallery.cropSources[p.id] = croppable[p.id];
    }
    for (final id in ticked) {
      picked.value = [...picked.value, GalleryPhoto(id)];
    }
  }

  final int n;
  final int initial;
  final String caption;
  final bool dark;
  final RendererFake renderer;
  late final photos = lib(n);
  late final gallery = GalleryFake(photos: photos);
  final picked = PhotoTicks();
  Sent? result;
  bool resolved = false;

  Widget app() => ProviderScope(
    overrides: [
      galleryProvider.overrideWithValue(gallery),
      photoCropRendererProvider.overrideWithValue(renderer),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(dark ? Brightness.dark : Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await showAttachmentPreview(
                  context,
                  photos: photos,
                  picked: picked,
                  initial: initial,
                  caption: caption,
                );
                resolved = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  List<String> get tickedIds => [for (final p in picked.value) p.id];
}

/// Lets real image decodes and the fake gallery's answers land.
Future<void> real(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

Future<Host> open(WidgetTester t, Host h) async {
  phoneView(t);
  await t.pumpWidget(h.app());
  await t.tap(key('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 16));
  expect(key('preview-page'), findsOneWidget, reason: 'not there at once');
  await t.pumpAndSettle();
  await real(t);
  return h;
}

String count(WidgetTester t) => find
    .descendant(
      of: key('preview-count'),
      matching: find.byType(RichText),
      matchRoot: true,
    )
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join()
    .replaceAll(RegExp(r'\s'), ''); // "2 / 3" read as "2/3"

/// How many thumbnails the strip shows.
int thumbs() => find
    .byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('preview-thumb-'),
    )
    .evaluate()
    .length;

Future<void> page(WidgetTester t, {required bool forward}) async {
  await t.fling(key('preview-pager'), Offset(forward ? -400 : 400, 0), 1000);
  await t.pumpAndSettle();
  await real(t);
}

Future<void> send(WidgetTester t) async {
  await t.tap(key('preview-send'));
  await t.pumpAndSettle();
  await real(t);
}

Future<void> openCrop(WidgetTester t) async {
  await t.tap(key('preview-crop'));
  await t.pumpAndSettle();
  await real(t);
  expect(key('crop-free-done'), findsOneWidget, reason: 'crop screen not open');
}

Future<void> cropDone(WidgetTester t) async {
  await openCrop(t);
  await t.tap(key('crop-free-done'));
  await t.pump(const Duration(milliseconds: 60));
  await t.pumpAndSettle();
  await real(t);
}

void expectTickLabel(WidgetTester t, String label) =>
    expect(t.getSemantics(key('preview-tick')), isSemantics(label: label));

void main() {
  setUpAll(() async {
    for (var i = 0; i < 4; i++) {
      // Distinct sizes, so every picture is a different set of bytes.
      sendable['p$i'] = PickedImage(
        bytes: await png(100 + 10 * i, 80),
        contentType: 'image/png',
        extension: 'png',
      );
      croppable['p$i'] = PickedImage(
        bytes: await png(200 + 10 * i, 160),
        contentType: 'image/png',
        extension: 'png',
      );
    }
    cutA = PickedImage(
      bytes: await png(30, 30),
      contentType: 'image/png',
      extension: 'png',
    );
    cutB = PickedImage(
      bytes: await png(40, 30),
      contentType: 'image/png',
      extension: 'png',
    );
  });

  Uint8List bytesOf(String id) => sendable[id]!.bytes;

  /// The photo [id]'s picture, from either of the gallery's reads.
  bool isOf(PickedImage p, String id) =>
      identical(p.bytes, sendable[id]!.bytes) ||
      identical(p.bytes, croppable[id]!.bytes) ||
      identical(p, sendable[id]) ||
      identical(p, croppable[id]);

  group('paging', () {
    testWidgets('opens on the tapped photo, titled "n / total"; a swipe '
        'moves through every grid photo', (t) async {
      await open(t, Host(3, initial: 1));
      expect(count(t), '2/3');

      await page(t, forward: false);
      expect(count(t), '1/3');
      await page(t, forward: true);
      await page(t, forward: true);
      expect(count(t), '3/3');
    });

    testWidgets('opened on the last photo of four', (t) async {
      await open(t, Host(4, initial: 3));
      expect(count(t), '4/4');
    });
  });

  group('ticks are the grid\'s ticks', () {
    testWidgets('the tick toggles the shared PhotoTicks and its label says '
        'which', (t) async {
      final sem = t.ensureSemantics();
      final h = await open(t, Host(3, initial: 1));
      final unticked = AppLocalizations.of(t.element(key('preview-page')))
          .attachTickSelect;
      final ticked = AppLocalizations.of(t.element(key('preview-page')))
          .attachTickSelected;
      expectTickLabel(t, unticked);

      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      expect(h.tickedIds, ['p1']);
      expectTickLabel(t, ticked);

      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      expect(h.tickedIds, isEmpty);
      expectTickLabel(t, unticked);
      sem.dispose();
    });

    testWidgets('a tick made on the grid shows here; a tick made here stays '
        'after back', (t) async {
      final sem = t.ensureSemantics();
      final h = await open(t, Host(3, initial: 0, ticked: ['p0']));
      expectTickLabel(
        t,
        AppLocalizations.of(t.element(key('preview-page'))).attachTickSelected,
      );

      await page(t, forward: true);
      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      expect(h.tickedIds, ['p0', 'p1']);

      await t.tap(key('preview-back'));
      await t.pumpAndSettle();
      expect(h.result, isNull);
      expect(h.tickedIds, ['p0', 'p1'], reason: 'ticks lost on back');
      sem.dispose();
    });

    testWidgets('the thumbnail strip shows only the ticked photos', (t) async {
      final h = await open(t, Host(4, initial: 0));
      expect(thumbs(), 0, reason: 'nothing ticked, yet thumbnails');

      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      await page(t, forward: true);
      await page(t, forward: true);
      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      await real(t);
      expect(h.tickedIds, ['p0', 'p2']);
      expect(key('preview-thumbs'), findsOneWidget);
      expect(thumbs(), 2, reason: 'not the ticked two');
    });

    testWidgets('the Send badge counts the ticked photos', (t) async {
      final h = await open(t, Host(4, initial: 0, ticked: ['p1', 'p3']));
      expect(
        find.descendant(of: key('preview-badge'), matching: find.text('2')),
        findsOneWidget,
      );
      await t.tap(key('preview-tick'));
      await t.pumpAndSettle();
      expect(h.tickedIds, hasLength(3));
      expect(
        find.descendant(of: key('preview-badge'), matching: find.text('3')),
        findsOneWidget,
      );
    });
  });

  group('Send', () {
    testWidgets('nothing ticked: sends the viewed photo with the caption as '
        'typed', (t) async {
      final h = await open(t, Host(3, initial: 2, caption: 'hello'));
      expect(previewCaption(t), 'hello', reason: 'caption not carried in');
      await t.enterText(key('preview-caption'), 'hi there');
      await send(t);

      expect(h.resolved, isTrue);
      expect(h.result!.images, hasLength(1));
      expect(h.result!.images.single.bytes, bytesOf('p2'));
      expect(h.result!.caption, 'hi there');
      expect(key('preview-page'), findsNothing);
    });

    testWidgets('ticked photos: sends exactly those in tick order, not the '
        'viewed one', (t) async {
      final h = await open(
        t,
        Host(3, initial: 1, caption: 'trip', ticked: ['p2', 'p0']),
      );
      await send(t);
      expect(
        [for (final p in h.result!.images) p.bytes],
        [bytesOf('p2'), bytesOf('p0')],
      );
      expect(h.result!.caption, 'trip');
    });

    testWidgets('a second Send while the photos load is ignored', (t) async {
      final h = Host(2, initial: 0, ticked: ['p0', 'p1']);
      await open(t, h);
      h.gallery.holdLoad();
      await t.tap(key('preview-send'));
      await t.pump();
      await t.tap(key('preview-send'), warnIfMissed: false);
      await t.pump();
      h.gallery.releaseLoad();
      await t.pumpAndSettle();
      await real(t);
      expect(h.resolved, isTrue);
      expect(h.result!.images, hasLength(2));
      expect(
        h.gallery.loadedIds.where((id) => id == 'p1'),
        hasLength(1),
        reason: 'the second tap was not ignored: it read the photos again',
      );
      expect(
        key('open'),
        findsOneWidget,
        reason: 'a second pop took the screen under the view with it',
      );
    });

    testWidgets('a viewed photo that cannot be opened: a notice, nothing '
        'sent', (t) async {
      final h = Host(2, initial: 0);
      h.gallery.loadResults['p0'] = null;
      await open(t, h);
      await t.tap(key('preview-send'));
      await t.pump();
      await real(t);
      expect(find.byType(SisNotice), findsOneWidget);
      expect(
        h.result?.images ?? const <PickedImage>[],
        isEmpty,
        reason: 'sent a photo that could not be opened',
      );
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
    });
  });

  group('back', () {
    testWidgets('the back arrow: null', (t) async {
      final h = await open(t, Host(2, caption: 'x'));
      await t.tap(key('preview-back'));
      await t.pumpAndSettle();
      expect(h.resolved, isTrue);
      expect(h.result, isNull);
      expect(key('preview-page'), findsNothing);
    });

    testWidgets('the system back: null', (t) async {
      final h = await open(t, Host(1));
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(h.resolved, isTrue);
      expect(h.result, isNull);
    });
  });

  group('crop', () {
    testWidgets('Done keeps the cut and ticks the photo; Send gives the cut', (
      t,
    ) async {
      final h = await open(t, Host(3, initial: 1));
      await cropDone(t);
      expect(
        isOf(h.renderer.cuts.single.source, 'p1'),
        isTrue,
        reason: 'cropped another photo',
      );
      expect(key('preview-page'), findsOneWidget);
      expect(h.tickedIds, ['p1'], reason: 'Done did not tick it');

      await send(t);
      expect(h.result!.images.single, same(cutA));
    });

    testWidgets('a cut replaces that photo only among the ticked', (t) async {
      final h = await open(t, Host(3, initial: 1, ticked: ['p0', 'p1']));
      await cropDone(t);
      expect(h.tickedIds, ['p0', 'p1'], reason: 'Done must not untick');
      await send(t);
      expect(h.result!.images, hasLength(2));
      expect(h.result!.images[0].bytes, bytesOf('p0'));
      expect(h.result!.images[1], same(cutA));
    });

    testWidgets('a second crop starts from the original, not the first cut', (
      t,
    ) async {
      final h = await open(t, Host(2, initial: 0));
      await cropDone(t);
      h.renderer.answer = cutB;
      await cropDone(t);
      expect(h.renderer.cuts, hasLength(2));
      expect(
        isOf(h.renderer.cuts[1].source, 'p0'),
        isTrue,
        reason: 'cropped the cut',
      );
      await send(t);
      expect(h.result!.images.single, same(cutB));
    });

    testWidgets('a failed cut (renderer null) keeps the photo', (t) async {
      final h = await open(t, Host(1, renderer: RendererFake()));
      await cropDone(t);
      expect(h.renderer.cuts, hasLength(1));
      // The crop screen stays open on failure; leave it with Cancel.
      await t.pump(const Duration(seconds: 5));
      await t.tap(key('crop-free-cancel'));
      await t.pumpAndSettle();
      await send(t);
      expect(h.result!.images.single.bytes, bytesOf('p0'));
    });

    testWidgets('Cancel changes nothing: no tick, the photo as it was', (
      t,
    ) async {
      final h = await open(t, Host(3, initial: 2));
      await openCrop(t);
      await t.tap(key('crop-free-cancel'));
      await t.pumpAndSettle();
      expect(key('preview-page'), findsOneWidget);
      expect(h.renderer.cuts, isEmpty);
      expect(h.tickedIds, isEmpty, reason: 'Cancel ticked it');

      await send(t);
      expect(h.result!.images.single.bytes, bytesOf('p2'));
    });
  });

  group('routes fade and grow, never push in sideways', () {
    // Mid-transition, a sideways push has the page's centre off the
    // screen's centre; a fade + grow from the centre keeps it there.
    testWidgets('the big photo view', (t) async {
      final h = Host(2);
      phoneView(t);
      await t.pumpWidget(h.app());
      await t.tap(key('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      final mid = t.getCenter(key('preview-page')).dx;
      expect(mid, moreOrLessEquals(screenWidth(t) / 2, epsilon: 1));
      await t.pumpAndSettle();
      await real(t);
    }, variant: platforms);

    testWidgets('the free crop screen', (t) async {
      await open(t, Host(2));
      await t.tap(key('preview-crop'));
      await t.pump();
      for (var i = 0; i < 4; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 15));
        if (find.byType(FreeCropScreen).evaluate().isNotEmpty) break;
      }
      expect(find.byType(FreeCropScreen), findsOneWidget);
      final mid = t.getCenter(find.byType(FreeCropScreen)).dx;
      expect(mid, moreOrLessEquals(screenWidth(t) / 2, epsilon: 1));
      await t.pumpAndSettle();
      await real(t);
    }, variant: platforms);
  });

  group('the background follows the theme', () {
    Color background(WidgetTester t) {
      final scaffold = find.ancestor(
        of: key('preview-send'),
        matching: find.byType(Scaffold),
      );
      final ctx = t.element(scaffold.first);
      return t.widget<Scaffold>(scaffold.first).backgroundColor ??
          Theme.of(ctx).scaffoldBackgroundColor;
    }

    testWidgets('light: a light page', (t) async {
      await open(t, Host(1));
      expect(background(t).computeLuminance(), greaterThan(0.5));
    });

    testWidgets('dark: a dark page', (t) async {
      await open(t, Host(1, dark: true));
      expect(background(t).computeLuminance(), lessThan(0.5));
    });
  });

  // The page opts out of swipe-back -- its pager keeps the horizontal drag --
  // while back still leaves.
  group('swipe-back opt-out', () {
    testWidgets('a slow mid-screen right drag on the pager pages back and '
        'never leaves', (t) async {
      final h = await open(t, Host(3, initial: 2));
      expect(count(t), '3/3');

      final at = t.getCenter(key('preview-pager'));
      await stroke(
        t,
        at,
        Offset(screenWidth(t) * 0.6, 0),
        over: const Duration(milliseconds: 1500),
      );
      await t.pumpAndSettle();
      expect(key('preview-page'), findsOneWidget, reason: 'it left');
      expect(h.resolved, isFalse);
      expect(count(t), '2/3', reason: 'the pager lost its drag');
    }, variant: platforms);

    testWidgets('on the first photo too, a right drag stays', (t) async {
      final h = await open(t, Host(1));
      await stroke(
        t,
        Offset(screenWidth(t) * 0.45, screenHeight(t) * 0.4),
        Offset(screenWidth(t) * 0.6, 0),
      );
      await t.pumpAndSettle();
      expect(key('preview-page'), findsOneWidget);
      expect(h.resolved, isFalse);
    }, variant: platforms);

    testWidgets('a right drag on the top bar, off the pager, stays too', (
      t,
    ) async {
      final h = await open(t, Host(2, initial: 1));
      final y = t.getCenter(key('preview-back')).dy;
      await stroke(
        t,
        Offset(screenWidth(t) * 0.3, y),
        Offset(screenWidth(t) * 0.6, 0),
      );
      await t.pumpAndSettle();
      expect(key('preview-page'), findsOneWidget, reason: 'it left');
      expect(h.resolved, isFalse);
    }, variant: platforms);

    testWidgets('OS back through the platform channel still leaves', (t) async {
      final h = await open(t, Host(1));
      await osBack(t);
      expect(h.resolved, isTrue);
      expect(h.result, isNull);
    }, variant: platforms);
  });
}
