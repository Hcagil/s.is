// "From an app" for a profile or group picture, written from its contract
// (the 2026-09-28 decision): the picture picker's sheet offers it at every
// access level, it asks the other app for one photo (the square picture
// shape, never the attachment shape), needs no photo permission, and what
// comes back goes the same set-picture path as a grid pick. A back-out
// changes nothing; something unreadable says "That could not be opened."
//
// The whole app as main.dart mounts it (avatar_widgets_test's World); fakes
// only at the repository, gallery and external-picker boundaries.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';

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
        expectPicture,
        expectInitials;

const failNotice = 'That could not be opened.';

/// What the other app hands back: a decodable photo with a tag byte of its
/// own, already the square JPEG shape, and -- a picture, not a message --
/// no preview.
final picked = PickedImage(
  bytes: Uint8List.fromList([...photoPng, 42]),
  contentType: 'image/jpeg',
  extension: 'jpg',
);

List<SisNotice> notices(WidgetTester t) =>
    t.widgetList<SisNotice>(find.byType(SisNotice)).toList();

/// avatar -> Choose photo -> the sheet, with [access] to the phone's photos.
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
  expect(w.gallery.squareLoads, isEmpty);
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
        await toSheet(t, 'profile-avatar');
        final asked = w.gallery.accessRequests;

        await act(t, byKey('sheet-from-app'));

        expect(w.picker.pictureCalls, 1);
        expect(
          w.picker.attachmentCalls,
          0,
          reason: 'the attachment shape is not the square picture',
        );
        expectNoPermissionAsked(w, asked);
        expect(w.profile.avatarUploads, hasLength(1));
        expect(w.profile.avatarUploads.single.image.bytes, picked.bytes);
        expect(noticeSaying('Profile picture updated'), findsOneWidget);
        expectPicture(byKey('profile-avatar'), picked.bytes, 'profile page');
        await drainNotice(t);
      });
    }

    testWidgets('backing out changes nothing and says nothing', (t) async {
      final w = World();
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar');

      await act(t, byKey('sheet-from-app'));

      expect(w.picker.pictureCalls, 1);
      expect(w.profile.avatarUploads, isEmpty);
      expect(notices(t), isEmpty);
      expectInitials(byKey('profile-avatar'), 'Maya Kaya', 'after back-out');
    });

    testWidgets('not a photo: "$failNotice", the picture kept', (t) async {
      final w = World();
      w.gallery.access = GalleryAccess.denied;
      w.picker.failure = true;
      await home(t, w);
      await openProfilePage(t);
      await toSheet(t, 'profile-avatar');

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
        await toSheet(t, 'group-avatar');
        final asked = w.gallery.accessRequests;

        await act(t, byKey('sheet-from-app'));

        expect(w.picker.pictureCalls, 1);
        expect(w.picker.attachmentCalls, 0);
        expectNoPermissionAsked(w, asked);
        final call = w.chat.groupAvatarCalls.single;
        expect(call.conversationId, 'g1');
        expect(call.image?.bytes, picked.bytes);
        expect(noticeSaying('Group picture updated'), findsOneWidget);
        expectPicture(byKey('group-avatar'), picked.bytes, 'group page');
        await drainNotice(t);
      });
    }

    testWidgets('backing out changes nothing', (t) async {
      final w = World();
      await home(t, w);
      await openGroupPage(t);
      await toSheet(t, 'group-avatar');

      await act(t, byKey('sheet-from-app'));

      expect(w.picker.pictureCalls, 1);
      expect(w.chat.groupAvatarCalls, isEmpty);
      expect(notices(t), isEmpty);
    });

    testWidgets('not a photo: "$failNotice", nothing changed', (t) async {
      final w = World();
      w.gallery.access = GalleryAccess.permanentlyDenied;
      w.picker.failure = true;
      await home(t, w);
      await openGroupPage(t);
      await toSheet(t, 'group-avatar');

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
