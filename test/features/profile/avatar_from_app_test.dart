// "From an app" for a profile or group picture, written from its contract
// (the 2026-09-28 decisions): the picture picker's sheet offers it at every
// access level, it asks the other app for one photo (the uncropped picture
// source, never the attachment shape), needs no photo permission, and what
// comes back goes the same path as a grid pick: the crop screen on that
// photo, then "Use" uploads what the PictureCropper made. A back-out -- from
// the other app or from the crop screen -- changes nothing; something
// unreadable says "That could not be opened."; a failed crop says "That
// photo could not be used." and uploads nothing.
//
// The whole app as main.dart mounts it (avatar_widgets_test's World); fakes
// only at the repository, gallery and external-picker boundaries.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/crop_screen.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';
import 'avatar_widgets_test.dart'
    show
        World,
        home,
        openProfilePage,
        openGroupPage,
        tapKey,
        act,
        byKey,
        cropAndUse,
        backOutOfCrop,
        expectPicture,
        expectInitials;

const failNotice = 'That could not be opened.';
const cropFail = 'That photo could not be used.';

/// What the other app hands back: a decodable photo with a tag byte of its
/// own, the uncropped JPEG source shape, and -- a picture, not a message --
/// no preview.
final picked = PickedImage(
  bytes: Uint8List.fromList([...photoPng, 42]),
  contentType: 'image/jpeg',
  extension: 'jpg',
);

List<SisNotice> notices(WidgetTester t) =>
    t.widgetList<SisNotice>(find.byType(SisNotice)).toList();

/// camera badge -> Choose photo -> the sheet.
Future<void> toSheet(WidgetTester t, String avatar) async {
  await tapKey(t, avatar);
  await tapKey(t, 'avatar-choose');
  expect(byKey('sheet-from-app'), findsOneWidget);
}

void expectNoPermissionAsked(World w, int asked) {
  expect(
    w.gallery.accessRequests,
    asked,
    reason: 'another app needs no photo permission from SIS',
  );
  expect(w.gallery.openSettingsCalls, 0);
  expect(w.gallery.cropLoads, isEmpty);
  expect(w.gallery.loadedIds, isEmpty);
}

void main() {
  group('Settings > Profile', () {
    for (final access in GalleryAccess.values) {
      testWidgets('${access.name}: a picture from an app becomes the profile '
          'picture', (t) async {
        final w = World();
        w.gallery.access = access;
        w.picker.picture = picked;
        await home(t, w);
        await openProfilePage(t);
        await toSheet(t, 'profile-avatar-edit');
        final asked = w.gallery.accessRequests;

        await act(t, byKey('sheet-from-app'));
        expect(w.profile.avatarUploads, isEmpty, reason: 'uploaded before Use');
        await cropAndUse(t);

        expect(w.picker.pictureCalls, 1);
        expect(
          w.picker.attachmentCalls,
          0,
          reason: 'the attachment shape is not the picture source',
        );
        expectNoPermissionAsked(w, asked);
        expect(
          w.cropper.calls.single.source,
          picked.bytes,
          reason: 'cropped something other than the picked photo',
        );
        expect(w.profile.avatarUploads, hasLength(1));
        expect(w.profile.avatarUploads.single.image.bytes, w.cropper.output);
        expect(noticeSaying('Profile picture updated'), findsOneWidget);
        expectPicture(byKey('profile-avatar'), w.cropper.output, 'profile');
        await drainNotice(t);
      });
    }

    testWidgets('backing out changes nothing and says nothing', (t) async {
      final w = World();
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar-edit');

      await act(t, byKey('sheet-from-app'));

      expect(w.picker.pictureCalls, 1);
      expect(find.byType(CropScreen), findsNothing, reason: 'nothing to crop');
      expect(w.profile.avatarUploads, isEmpty);
      expect(notices(t), isEmpty);
      expectInitials(byKey('profile-avatar'), 'Maya Kaya', 'after back-out');
    });

    testWidgets('back from the crop screen changes nothing and says nothing', (
      t,
    ) async {
      final w = World();
      w.picker.picture = picked;
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar-edit');

      await act(t, byKey('sheet-from-app'));
      await backOutOfCrop(t);

      expect(w.cropper.calls, isEmpty);
      expect(w.profile.avatarUploads, isEmpty);
      expect(notices(t), isEmpty);
      expectInitials(byKey('profile-avatar'), 'Maya Kaya', 'after back');
    });

    testWidgets('a crop that fails: "$cropFail", nothing uploaded', (t) async {
      final w = World();
      w.picker.picture = picked;
      w.cropper.fails = true;
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar-edit');

      await act(t, byKey('sheet-from-app'));
      await cropAndUse(t);

      expect(w.cropper.calls, hasLength(1));
      expect(w.profile.avatarUploads, isEmpty);
      final shown = notices(t);
      expect(shown, hasLength(1));
      expect(shown.single.message, cropFail);
      expect(shown.single.isError, isTrue);
      expect(find.byType(CropScreen), findsOneWidget);
      await drainNotice(t);
    });

    testWidgets('not a photo: "$failNotice", the picture kept', (t) async {
      final w = World();
      w.gallery.access = GalleryAccess.denied;
      w.picker.failure = true;
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar-edit');

      await act(t, byKey('sheet-from-app'));

      expect(w.profile.avatarUploads, isEmpty);
      final shown = notices(t);
      expect(shown, hasLength(1));
      expect(shown.single.message, failNotice);
      expect(shown.single.isError, isTrue);
      expect(w.gallery.openSettingsCalls, 0);
      await drainNotice(t);
    });
  });

  group('a group\'s picture', () {
    for (final access in GalleryAccess.values) {
      testWidgets('${access.name}: a picture from an app becomes the group\'s '
          'picture', (t) async {
        final w = World();
        w.gallery.access = access;
        w.picker.picture = picked;
        await home(t, w);
        await openGroupPage(t);
        await toSheet(t, 'group-avatar-edit');
        final asked = w.gallery.accessRequests;

        await act(t, byKey('sheet-from-app'));
        expect(w.chat.groupAvatarCalls, isEmpty, reason: 'sent before Use');
        await cropAndUse(t);

        expect(w.picker.pictureCalls, 1);
        expect(w.picker.attachmentCalls, 0);
        expectNoPermissionAsked(w, asked);
        expect(w.cropper.calls.single.source, picked.bytes);
        final call = w.chat.groupAvatarCalls.single;
        expect(call.conversationId, 'g1');
        expect(call.image?.bytes, w.cropper.output);
        expect(noticeSaying('Group picture updated'), findsOneWidget);
        expectPicture(byKey('group-avatar'), w.cropper.output, 'group page');
        await drainNotice(t);
      });
    }

    testWidgets('backing out changes nothing', (t) async {
      final w = World();
      await home(t, w);
      await openGroupPage(t);
      await toSheet(t, 'group-avatar-edit');

      await act(t, byKey('sheet-from-app'));

      expect(w.picker.pictureCalls, 1);
      expect(find.byType(CropScreen), findsNothing);
      expect(w.chat.groupAvatarCalls, isEmpty);
      expect(notices(t), isEmpty);
    });

    testWidgets('back from the crop screen sends nothing', (t) async {
      final w = World();
      w.picker.picture = picked;
      await home(t, w);
      await openGroupPage(t);
      await toSheet(t, 'group-avatar-edit');

      await act(t, byKey('sheet-from-app'));
      await backOutOfCrop(t);

      expect(w.cropper.calls, isEmpty);
      expect(w.chat.groupAvatarCalls, isEmpty);
      expect(notices(t), isEmpty);
    });

    testWidgets('not a photo: "$failNotice", nothing changed', (t) async {
      final w = World();
      w.gallery.access = GalleryAccess.permanentlyDenied;
      w.picker.failure = true;
      await home(t, w);
      await openGroupPage(t);
      await toSheet(t, 'group-avatar-edit');

      await act(t, byKey('sheet-from-app'));

      expect(w.chat.groupAvatarCalls, isEmpty);
      final shown = notices(t);
      expect(shown, hasLength(1));
      expect(shown.single.message, failNotice);
      expect(shown.single.isError, isTrue);
      expect(w.gallery.openSettingsCalls, 0);
      await drainNotice(t);
    });
  });
}
