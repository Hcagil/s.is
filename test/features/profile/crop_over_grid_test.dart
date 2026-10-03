// The square picture picker crops over its own grid, written from the 0.30.3
// contract:
//
//  - showAttachmentSheet(context, square: true) pushes the crop screen OVER
//    the sheet: back from the crop returns to the grid as it was left (same
//    scroll offset), the sheet stays open and the caller gets nothing yet;
//    Use pops the sheet with the cropped image as images.first. An empty
//    list means the sheet closed without a pick.
//  - square: false (a chat photo): a tap ticks, "Send N photos" pops the
//    sheet with the ticked photos; no crop route ever. (0.30.10)
//  - square: true has no camera tile and no tick circles. (0.30.10)
//  - "From an app" (sheet-from-app) with square: true crops over the grid
//    too; back returns to it, and a cancelled or failed pick leaves it.
//  - loadForCrop giving null: a notice, still on the grid. A failed crop:
//    "That photo could not be used." on the crop screen, which stays.
//  - showAvatarCard(context, ref, anchor:, hasAvatar:) (0.30.10, replaces
//    the avatar sheet) gives AvatarPicked (the crop), AvatarRemoved, or
//    null.
//
// The profile and group flows run on the whole app as main.dart mounts it
// (World, shared with avatar_widgets_test.dart); the return-value contract
// is checked on the public functions under a bare host with the three
// providers the sheet reads.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/presentation/attachment_sheet.dart';
import 'package:sis/features/chat/presentation/avatar_card.dart';
import 'package:sis/features/chat/presentation/crop_screen.dart';

import '../../support/fakes.dart';
import '../../support/gallery_paging.dart' hide steps;
import '../../support/sis_ui.dart';
import 'avatar_from_app_test.dart' show picked;
import 'avatar_widgets_test.dart'
    show
        World,
        home,
        openProfilePage,
        openGroupPage,
        tapKey,
        act,
        byKey,
        steps,
        settle,
        untilCropReady,
        cropAndUse,
        backOutOfCrop;

const cropFail = 'That photo could not be used.';

final _tile = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('sheet-photo-'),
);

int _index(Element e) => int.parse(
  (e.widget.key! as ValueKey<String>).value.substring('sheet-photo-p'.length),
);

/// A photo tile a finger can hit right now, at or past library index [from]
/// and not [except].
String visibleTile(WidgetTester t, {int from = 0, String? except}) {
  final ids = [
    for (final e in _tile.hitTestable().evaluate())
      if (_index(e) >= from) 'p${_index(e)}',
  ]..remove(except);
  expect(ids, isNotEmpty, reason: 'no tappable photo at index >= $from');
  return ids.first;
}

/// Every photo has a readable thumbnail (an unreadable one ignores taps).
void readable(GalleryFake g) {
  for (final p in g.photos) {
    g.thumbnails[p.id] = photoPng;
  }
}

/// Scrolls the open grid well past its first page (so page 1 is loaded)
/// and returns the offset it rests at.
Future<double> scrollPastFirstPage(WidgetTester t, GalleryFake g) async {
  await jumpToBottom(t);
  await settle(t);
  expect(pagesAsked(g), containsAllInOrder([0, 1]));
  final p = gridPosition(t);
  final firstPage = p.maxScrollExtent / 2; // two pages loaded, ~equal rows
  p.jumpTo(firstPage + p.viewportDimension);
  await settle(t);
  expect(p.pixels, greaterThan(firstPage), reason: 'not past page 0');
  return p.pixels;
}

void expectGridOpen(String when) {
  expect(find.byType(CropScreen), findsNothing, reason: '$when: crop open');
  expect(find.byType(GridView), findsOneWidget, reason: '$when: no grid');
  expect(
    byKey('sheet-from-app'),
    findsOneWidget,
    reason: '$when: the sheet closed',
  );
}

/// The Android back gesture.
Future<void> systemBack(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await steps(t, 30);
}

typedef Picked = ({List<PickedImage> images, int dropped});

/// A bare screen that opens the sheet (or the avatar sheet) and keeps what
/// the call resolves with.
class Host {
  Host({int photos = 200})
    : gallery = GalleryFake(photos: photoLibrary(photos)) {
    readable(gallery);
  }

  final GalleryFake gallery;
  final picker = ExternalPickerFake();
  final cropper = PictureCropperFake();
  Picked? sheet;
  AvatarChoice? avatar;
  bool resolved = false;

  Widget app() => ProviderScope(
    overrides: [
      galleryProvider.overrideWithValue(gallery),
      externalPickerProvider.overrideWithValue(picker),
      pictureCropperProvider.overrideWithValue(cropper),
    ],
    child: MaterialApp(
      theme: sisTheme(Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              for (final square in [true, false])
                TextButton(
                  key: ValueKey('open-$square'),
                  onPressed: () async {
                    sheet = await showAttachmentSheet(context, square: square);
                    resolved = true;
                  },
                  child: Text('open $square'),
                ),
              for (final has in [true, false])
                Consumer(
                  builder: (context, ref, _) => TextButton(
                    key: ValueKey('avatar-$has'),
                    onPressed: () async {
                      final box = context.findRenderObject()! as RenderBox;
                      avatar = await showAvatarCard(
                        context,
                        ref,
                        anchor: box.localToGlobal(Offset.zero) & box.size,
                        hasAvatar: has,
                      );
                      resolved = true;
                    },
                    child: Text('avatar $has'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<Host> mount(WidgetTester t, String button, {Host? host}) async {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.625;
  addTearDown(t.view.reset);
  final h = host ?? Host();
  await t.pumpWidget(h.app());
  await t.tap(byKey(button));
  await settle(t);
  return h;
}

void main() {
  group('back from the crop returns to the grid as it was left', () {
    for (final site in ['profile', 'group']) {
      testWidgets('$site picture: scrolled past page 0, back keeps the grid '
          'at the same offset; another photo then crops and is used', (
        t,
      ) async {
        final w = World(pictures: true);
        w.gallery.photos = photoLibrary(200);
        readable(w.gallery);
        await home(t, w);
        if (site == 'profile') {
          await openProfilePage(t);
          await tapKey(t, 'profile-avatar-edit');
        } else {
          await openGroupPage(t);
          await tapKey(t, 'group-avatar-edit');
        }
        await tapKey(t, 'avatar-library');
        expectGridOpen('opened');

        final offset = await scrollPastFirstPage(t, w.gallery);
        final first = visibleTile(t, from: pageSize);
        // A finger on the tile where it is: no ensureVisible scroll.
        await t.tap(byKey('sheet-photo-$first'));
        await steps(t);
        expect(find.byType(CropScreen), findsOneWidget);
        await untilCropReady(t);

        await systemBack(t);
        expectGridOpen('back from the crop');
        expect(
          gridPosition(t).pixels,
          offset,
          reason: 'the grid lost its place',
        );
        expect(byKey('sheet-photo-$first').hitTestable(), findsOneWidget);
        expect(w.cropper.calls, isEmpty);
        expect(w.profile.avatarUploads, isEmpty, reason: 'caller got a pick');
        expect(w.chat.groupAvatarCalls, isEmpty, reason: 'caller got a pick');
        expect(notice, findsNothing, reason: 'a back-out is not news');

        final second = visibleTile(t, from: pageSize, except: first);
        await act(t, byKey('sheet-photo-$second'));
        await cropAndUse(t);
        expect(find.byType(GridView), findsNothing, reason: 'sheet stayed');
        expect(find.byType(CropScreen), findsNothing);
        expect(w.gallery.cropLoads, [first, second]);
        expect(w.cropper.calls.single.source, photoPng);
        if (site == 'profile') {
          expect(w.profile.avatarUploads.single.image.bytes, w.cropper.output);
        } else {
          expect(w.chat.groupAvatarCalls, hasLength(1));
        }
        await drainNotice(t);
      });
    }

    testWidgets('a crop that fails stays on the crop screen; back from it '
        'is the grid again', (t) async {
      final w = World(pictures: true);
      w.cropper.fails = true;
      await home(t, w);
      await openProfilePage(t);
      await tapKey(t, 'profile-avatar-edit');
      await tapKey(t, 'avatar-library');
      await act(t, byKey('sheet-photo-p1'));
      await cropAndUse(t);

      expect(noticeSaying(cropFail), findsOneWidget);
      expect(find.byType(CropScreen), findsOneWidget, reason: 'crop closed');
      expect(w.profile.avatarUploads, isEmpty);
      await drainNotice(t);
      await backOutOfCrop(t);
      expectGridOpen('back after a failed crop');
      expect(w.profile.avatarUploads, isEmpty);
    });

    testWidgets('a photo that cannot be opened for the crop: a notice, '
        'still on the grid, and another photo still crops', (t) async {
      final w = World(pictures: true);
      w.gallery.cropSources['p1'] = null;
      await home(t, w);
      await openProfilePage(t);
      await tapKey(t, 'profile-avatar-edit');
      await tapKey(t, 'avatar-library');
      await act(t, byKey('sheet-photo-p1'));

      expect(w.gallery.cropLoads, ['p1']);
      expect(notice, findsOneWidget, reason: 'no notice');
      expectGridOpen('after an unopenable photo');
      expect(w.profile.avatarUploads, isEmpty);
      await drainNotice(t);

      await act(t, byKey('sheet-photo-p2'));
      await cropAndUse(t);
      expect(w.profile.avatarUploads.single.image.bytes, w.cropper.output);
      await drainNotice(t);
    });
  });

  group('"From an app" with a square crops over the grid', () {
    testWidgets('back from its crop returns to the grid', (t) async {
      final w = World(pictures: true);
      w.picker.picture = picked;
      await home(t, w);
      await openProfilePage(t);
      await tapKey(t, 'profile-avatar-edit');
      await tapKey(t, 'avatar-library');

      await act(t, byKey('sheet-from-app'));
      await backOutOfCrop(t);
      expectGridOpen('back from the app\'s crop');
      expect(w.profile.avatarUploads, isEmpty);

      await act(t, byKey('sheet-from-app'));
      await cropAndUse(t);
      expect(find.byType(GridView), findsNothing);
      expect(w.cropper.calls.last.source, picked.bytes);
      expect(w.profile.avatarUploads.single.image.bytes, w.cropper.output);
      await drainNotice(t);
    });

    for (final outcome in ['cancelled', 'failed']) {
      testWidgets('$outcome: the grid stays in place', (t) async {
        final w = World(pictures: true);
        w.picker.picture = null; // cancelled
        if (outcome == 'failed') w.picker.failure = true;
        await home(t, w);
        await openProfilePage(t);
        await tapKey(t, 'profile-avatar-edit');
        await tapKey(t, 'avatar-library');

        await act(t, byKey('sheet-from-app'));
        expect(w.picker.pictureCalls, 1);
        expectGridOpen(outcome);
        expect(w.cropper.calls, isEmpty);
        expect(w.profile.avatarUploads, isEmpty);
        await drainNotice(t);
      });
    }
  });

  group('showAttachmentSheet resolves', () {
    testWidgets('square: back from the crop resolves nothing; Use resolves '
        'the crop as images.first', (t) async {
      final h = await mount(t, 'open-true');
      await act(t, byKey('sheet-photo-p0'));
      expect(find.byType(CropScreen), findsOneWidget);
      await untilCropReady(t);
      await systemBack(t);
      expectGridOpen('back');
      expect(h.resolved, isFalse, reason: 'the caller got a result on back');

      await act(t, byKey('sheet-photo-p1'));
      await cropAndUse(t);
      await settle(t);
      expect(h.resolved, isTrue);
      expect(h.sheet!.images.first.bytes, h.cropper.output);
      expect(h.sheet!.dropped, 0);
      expect(h.cropper.calls.single.source, photoPng);
      expect(find.byType(GridView), findsNothing);
    });

    testWidgets('square, from an app: Use resolves the crop of what the app '
        'gave', (t) async {
      final h = Host()..picker.picture = picked;
      await mount(t, 'open-true', host: h);
      await act(t, byKey('sheet-from-app'));
      await cropAndUse(t);
      await settle(t);
      expect(h.sheet!.images.first.bytes, h.cropper.output);
      expect(h.cropper.calls.single.source, picked.bytes);
    });

    testWidgets('not square: a tap ticks, Send resolves the ticked photo; no '
        'crop', (t) async {
      final h = await mount(t, 'open-false');
      await t.tap(byKey('sheet-photo-p0'));
      await steps(t);
      expect(h.resolved, isFalse, reason: 'a tick is not a pick');
      expect(byKey('sheet-tick-p0'), findsOneWidget);
      await t.tap(byKey('sheet-send'));
      var sawCrop = false;
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 20));
        sawCrop |= find.byType(CropScreen).evaluate().isNotEmpty;
      }
      await settle(t);
      expect(sawCrop, isFalse, reason: 'a chat photo went through the crop');
      expect(h.resolved, isTrue, reason: 'Send did not pop the sheet');
      expect(h.sheet!.images.single.bytes, pngBytes);
      expect(h.gallery.loadedIds, ['p0']);
      expect(h.gallery.cropLoads, isEmpty);
      expect(h.cropper.calls, isEmpty);
      expect(find.byType(GridView), findsNothing);
    });

    testWidgets('square: no camera tile, no tick circles; not square: both', (
      t,
    ) async {
      await mount(t, 'open-true');
      expect(byKey('sheet-photo-p0'), findsOneWidget);
      expect(byKey('sheet-camera'), findsNothing);
      expect(byKey('sheet-tick-p0'), findsNothing);
      await systemBack(t);
      await settle(t);

      await t.tap(byKey('open-false'));
      await settle(t);
      expect(byKey('sheet-camera'), findsOneWidget);
      expect(byKey('sheet-tick-p0'), findsOneWidget);
    });

    for (final square in [true, false]) {
      testWidgets('square: $square, closed without a pick: an empty list', (
        t,
      ) async {
        final h = await mount(t, 'open-$square');
        await systemBack(t);
        await settle(t);
        expect(h.resolved, isTrue);
        expect(h.sheet!.images, isEmpty);
        expect(h.sheet!.dropped, 0);
      });
    }

    testWidgets('square: back from the crop, then closed: an empty list', (
      t,
    ) async {
      final h = await mount(t, 'open-true');
      await act(t, byKey('sheet-photo-p0'));
      await backOutOfCrop(t);
      expect(h.resolved, isFalse);
      await systemBack(t);
      await settle(t);
      expect(h.resolved, isTrue);
      expect(h.sheet!.images, isEmpty);
      expect(h.cropper.calls, isEmpty);
    });
  });

  group('showAvatarCard resolves', () {
    testWidgets('Choose photo, back from the crop, another photo, Use: '
        'AvatarPicked with the crop', (t) async {
      final h = await mount(t, 'avatar-true');
      await tapKey(t, 'avatar-library');
      await act(t, byKey('sheet-photo-p0'));
      await backOutOfCrop(t);
      expectGridOpen('back');
      expect(h.resolved, isFalse);

      await act(t, byKey('sheet-photo-p1'));
      await cropAndUse(t);
      await settle(t);
      expect(h.resolved, isTrue);
      expect(h.avatar, isA<AvatarPicked>());
      expect((h.avatar! as AvatarPicked).image.bytes, h.cropper.output);
    });

    testWidgets('Remove: AvatarRemoved', (t) async {
      final h = await mount(t, 'avatar-true');
      await tapKey(t, 'avatar-remove');
      expect(h.resolved, isTrue);
      expect(h.avatar, isA<AvatarRemoved>());
    });

    testWidgets('no picture yet: no Remove', (t) async {
      await mount(t, 'avatar-false');
      expect(byKey('avatar-library'), findsOneWidget);
      expect(byKey('avatar-remove'), findsNothing);
    });

    testWidgets('backed out of the choice: null', (t) async {
      final h = await mount(t, 'avatar-true');
      await systemBack(t);
      await settle(t);
      expect(h.resolved, isTrue);
      expect(h.avatar, isNull);
    });

    testWidgets('back from the crop, then closed: null', (t) async {
      final h = await mount(t, 'avatar-true');
      await tapKey(t, 'avatar-library');
      await act(t, byKey('sheet-photo-p0'));
      await backOutOfCrop(t);
      await systemBack(t);
      await settle(t);
      expect(h.resolved, isTrue);
      expect(h.avatar, isNull);
      expect(h.cropper.calls, isEmpty);
    });
  });
}
