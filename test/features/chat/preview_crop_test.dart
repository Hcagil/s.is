// The crop button of the send preview, from its contract: `preview-crop`
// opens the free crop screen on the current page's ORIGINAL photo; a
// returned image replaces that page only; null changes nothing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/chat_launcher.dart' show phoneView;
import '../../support/crop_fakes.dart';

Finder key(String k) => find.byKey(ValueKey(k));

typedef Sent = ({List<PickedImage> images, String caption});

late List<PickedImage> photos; // three distinct originals
late PickedImage cutA;
late PickedImage cutB;

class Host {
  Host(this.renderer);
  final RendererFake renderer;
  Sent? result;

  Widget app() => ProviderScope(
    overrides: [photoCropRendererProvider.overrideWithValue(renderer)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: sisTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async => result = await showAttachmentPreview(
                context,
                images: photos,
                caption: '',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Lets real image decodes finish (they run outside fake time).
Future<void> real(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

Future<Host> open(WidgetTester t, RendererFake r) async {
  phoneView(t);
  final h = Host(r);
  await t.pumpWidget(h.app());
  await t.tap(key('open'));
  await t.pumpAndSettle();
  await real(t);
  return h;
}

Future<void> cropDone(WidgetTester t) async {
  await t.tap(key('preview-crop'));
  await t.pumpAndSettle();
  await real(t);
  expect(key('crop-free-done'), findsOneWidget, reason: 'crop screen not open');
  await t.tap(key('crop-free-done'));
  await t.pump(const Duration(milliseconds: 60));
  await t.pumpAndSettle();
  await real(t);
}

Future<void> send(WidgetTester t) async {
  await t.tap(key('preview-send'));
  await t.pumpAndSettle();
}

Future<void> page(WidgetTester t, int i) async {
  await t.tap(key('preview-thumb-$i'));
  await t.pumpAndSettle();
  await real(t);
}

void main() {
  setUpAll(() async {
    photos = [
      for (final w in [120, 140, 160])
        PickedImage(
          bytes: await png(w, 80),
          contentType: 'image/png',
          extension: 'png',
        ),
    ];
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

  testWidgets('crop replaces the current page only', (t) async {
    final r = RendererFake(answer: cutA);
    final h = await open(t, r);
    await page(t, 1);
    await cropDone(t);
    expect(r.cuts.single.source, same(photos[1]), reason: 'not page 1');
    expect(key('preview-page'), findsOneWidget);

    await send(t);
    final out = h.result!.images;
    expect(out, hasLength(3));
    expect(out[0], same(photos[0]));
    expect(out[1], same(cutA));
    expect(out[2], same(photos[2]));
  });

  testWidgets('a second crop starts from the ORIGINAL, not the first cut', (
    t,
  ) async {
    final r = RendererFake(answer: cutA);
    final h = await open(t, r);
    await cropDone(t);
    r.answer = cutB;
    await cropDone(t);
    expect(r.cuts, hasLength(2));
    expect(r.cuts[0].source, same(photos[0]));
    expect(r.cuts[1].source, same(photos[0]), reason: 'cropped the cut');

    await send(t);
    expect(h.result!.images[0], same(cutB));
    expect(h.result!.images[1], same(photos[1]));
  });

  testWidgets('Cancel on the crop screen changes nothing', (t) async {
    final r = RendererFake(answer: cutA);
    final h = await open(t, r);
    await page(t, 2);
    await t.tap(key('preview-crop'));
    await t.pumpAndSettle();
    await real(t);
    await t.tap(key('crop-free-cancel'));
    await t.pumpAndSettle();
    expect(key('preview-page'), findsOneWidget);
    expect(r.cuts, isEmpty);

    await send(t);
    expect(h.result!.images, [
      same(photos[0]),
      same(photos[1]),
      same(photos[2]),
    ]);
  });

  testWidgets('a failed cut (renderer null) keeps the photo', (t) async {
    final r = RendererFake();
    final h = await open(t, r);
    await cropDone(t);
    expect(r.cuts, hasLength(1));
    // The crop screen stays open on failure; leave it with Cancel.
    await t.pump(const Duration(seconds: 5));
    await t.tap(key('crop-free-cancel'));
    await t.pumpAndSettle();

    await send(t);
    expect(h.result!.images[0], same(photos[0]));
  });

  testWidgets('after a photo is removed, crop opens the right original', (
    t,
  ) async {
    final r = RendererFake(answer: cutA);
    final h = await open(t, r);
    await t.tap(key('preview-remove')); // drops photos[0]
    await t.pumpAndSettle();
    await page(t, 1); // now photos[2]
    await cropDone(t);
    expect(r.cuts.single.source, same(photos[2]));

    await send(t);
    expect(h.result!.images, [same(photos[1]), same(cutA)]);
  });
}
