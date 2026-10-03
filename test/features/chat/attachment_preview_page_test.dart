// The preview page every photo pick lands on (0.30.10), written from its
// contract, never from its widgets:
//
//  - showAttachmentPreview(context, images:, caption:) resolves with
//    (images, caption) on Send, or null on back.
//  - Keys: preview-page, preview-back, preview-count ("n/N"), preview-remove,
//    preview-pager, preview-photo-<i>, preview-thumbs, preview-thumb-<i>,
//    preview-caption, preview-send. The count, the trash and the thumbnail
//    strip show only with more than one photo.
//  - The background follows the theme (light or dark), not a fixed black.
//  - It is there on the first frames after the call.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/attachment_preview_page.dart';

import '../../support/attach_flow.dart' show key, previewCaption;
import '../../support/fakes.dart';

typedef Sent = ({List<PickedImage> images, String caption});

PickedImage photo() =>
    PickedImage(bytes: photoPng, contentType: 'image/png', extension: 'png');

class Host {
  Host(this.images, {this.caption = '', this.dark = false});
  final List<PickedImage> images;
  final String caption;
  final bool dark;
  Sent? result;
  bool resolved = false;

  Widget app() => ProviderScope(
    child: MaterialApp(
      theme: sisTheme(dark ? Brightness.dark : Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await showAttachmentPreview(
                  context,
                  images: images,
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
}

Future<Host> open(WidgetTester t, Host h) async {
  await t.pumpWidget(h.app());
  await t.tap(key('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 16));
  expect(key('preview-page'), findsOneWidget, reason: 'not there at once');
  await t.pumpAndSettle();
  return h;
}

String count(WidgetTester t) => find
    .descendant(of: key('preview-count'), matching: find.byType(RichText))
    .evaluate()
    .map((e) => (e.widget as RichText).text.toPlainText())
    .join()
    .replaceAll(RegExp(r'\s'), ''); // "1 / 3" and "1/3" are both n/N

Future<void> send(WidgetTester t) async {
  await t.tap(key('preview-send'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('one photo: no count, no trash, no thumbnails; Send gives the '
      'photo and the caption as typed', (t) async {
    final one = photo();
    final h = await open(t, Host([one], caption: 'hello'));
    expect(key('preview-photo-0'), findsOneWidget);
    expect(key('preview-count'), findsNothing);
    expect(key('preview-remove'), findsNothing);
    expect(key('preview-thumbs'), findsNothing);
    expect(previewCaption(t), 'hello', reason: 'caption not carried in');

    await t.enterText(key('preview-caption'), 'hi there');
    await send(t);
    expect(h.resolved, isTrue);
    expect(h.result!.images.single, same(one));
    expect(h.result!.caption, 'hi there');
    expect(key('preview-page'), findsNothing);
  });

  testWidgets('three photos: count, trash and thumbnails; a thumbnail and a '
      'swipe move the count', (t) async {
    await open(t, Host([photo(), photo(), photo()]));
    expect(count(t), '1/3');
    expect(key('preview-remove'), findsOneWidget);
    expect(key('preview-thumbs'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(key('preview-thumb-$i'), findsOneWidget);
    }

    await t.tap(key('preview-thumb-2'));
    await t.pumpAndSettle();
    expect(count(t), '3/3');

    await t.fling(key('preview-pager'), const Offset(400, 0), 1000);
    await t.pumpAndSettle();
    expect(count(t), '2/3');
  });

  testWidgets('the trash takes out the photo shown; down to one, the count, '
      'trash and thumbnails go; Send gives what is left in order', (t) async {
    final a = photo(), b = photo(), c = photo();
    final h = await open(t, Host([a, b, c]));
    await t.tap(key('preview-thumb-1'));
    await t.pumpAndSettle();
    await t.tap(key('preview-remove'));
    await t.pumpAndSettle();
    expect(count(t), endsWith('/2'));
    expect(key('preview-thumb-2'), findsNothing);

    await t.tap(key('preview-remove'));
    await t.pumpAndSettle();
    expect(key('preview-count'), findsNothing);
    expect(key('preview-remove'), findsNothing);
    expect(key('preview-thumbs'), findsNothing);
    await send(t);
    expect(h.result!.images, hasLength(1));
    expect([a, c].any((p) => identical(p, h.result!.images.single)), isTrue);
  });

  testWidgets('two photos, the second removed: Send gives the first only', (
    t,
  ) async {
    final a = photo(), b = photo();
    final h = await open(t, Host([a, b]));
    await t.tap(key('preview-thumb-1'));
    await t.pumpAndSettle();
    await t.tap(key('preview-remove'));
    await t.pumpAndSettle();
    await send(t);
    expect(h.result!.images, hasLength(1));
    expect(h.result!.images.single, same(a));
  });

  testWidgets('three photos sent untouched come back all, in order', (t) async {
    final ps = [photo(), photo(), photo()];
    final h = await open(t, Host(ps, caption: 'trip'));
    await send(t);
    expect(h.result!.images, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(h.result!.images[i], same(ps[i]));
    }
    expect(h.result!.caption, 'trip');
  });

  testWidgets('the back arrow: null', (t) async {
    final h = await open(t, Host([photo(), photo()], caption: 'x'));
    await t.tap(key('preview-back'));
    await t.pumpAndSettle();
    expect(h.resolved, isTrue);
    expect(h.result, isNull);
    expect(key('preview-page'), findsNothing);
  });

  testWidgets('the system back: null', (t) async {
    final h = await open(t, Host([photo()]));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(h.resolved, isTrue);
    expect(h.result, isNull);
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
      await open(t, Host([photo()]));
      expect(background(t).computeLuminance(), greaterThan(0.5));
    });

    testWidgets('dark: a dark page', (t) async {
      await open(t, Host([photo()], dark: true));
      expect(background(t).computeLuminance(), lessThan(0.5));
    });
  });
}
