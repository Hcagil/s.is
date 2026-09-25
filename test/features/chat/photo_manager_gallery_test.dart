// PhotoManagerGallery's access answer, from the Gallery contract in
// lib/features/chat/domain/gallery.dart: Android never says "permanently
// denied", it silently stops prompting after the member has refused once.
// So a refusal after an earlier recorded ask is read as permanent, and the
// record lives in the preferences file so it survives the app restarting.
//
// Runs the real class over photo_manager's platform channel and Android's
// preferences file (DiskPrefs): the device side, written from what the
// platform answers -- not from what the class expects of it.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/chat/data/photo_manager_gallery.dart';
import 'package:sis/features/chat/domain/gallery.dart';

import '../../support/push_platform.dart';

/// photo_manager's PermissionState, by index, as its channel answers.
enum Platform { notDetermined, restricted, denied, authorized, limited }

/// The photo library's platform side on one phone.
class PhotoPlatform {
  /// The phone's record of the permission.
  Platform state = Platform.notDetermined;

  /// What the member taps if a prompt is shown.
  Platform answer = Platform.denied;

  /// Android 11+ stops prompting once the member has refused twice; the
  /// answer is then whatever the record already says.
  int refusals = 0;

  int requests = 0;
  int settingsOpened = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'requestPermissionExtend':
        requests++;
        if (state == Platform.authorized) return state.index;
        if (refusals >= 2) return state.index; // no prompt any more
        state = answer;
        if (state == Platform.denied) refusals++;
        return state.index;
      case 'getPermissionState':
        return state.index;
      case 'openSetting':
        settingsOpened++;
        return null;
      default:
        return null;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  const prefs = MethodChannel('plugins.flutter.io/shared_preferences');
  late PhotoPlatform phone;
  late DiskPrefs disk;

  /// A new process on the same phone.
  void restart() => SharedPreferences.resetStatic();

  setUp(() {
    phone = PhotoPlatform();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(photos, phone.handle);
    messenger.setMockMethodCallHandler(prefs, disk.handle);
    restart();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(photos, null);
    messenger.setMockMethodCallHandler(prefs, null);
  });

  test('allowed in full is full; a selection is limited', () async {
    phone.answer = Platform.authorized;
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.full,
    );

    phone = PhotoPlatform()..answer = Platform.limited;
    messenger.setMockMethodCallHandler(photos, phone.handle);
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.limited,
    );
  });

  test('the first refusal is plain denied: Android can still prompt', () async {
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );
    expect(phone.requests, 1);
  });

  test('refused again is permanently denied', () async {
    const gallery = PhotoManagerGallery();
    expect(await gallery.requestAccess(), GalleryAccess.denied);

    expect(
      await gallery.requestAccess(),
      GalleryAccess.permanentlyDenied,
      reason: 'Android will not prompt a second time: only settings help',
    );
  });

  test('the earlier ask is remembered across a restart', () async {
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );

    restart();

    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.permanentlyDenied,
      reason: 'the record of the first ask must live in the preferences file',
    );
  });

  test('a refusal on a phone that never asked before is not permanent, '
      'even after a restart', () async {
    restart();
    expect(
      await const PhotoManagerGallery().requestAccess(),
      GalleryAccess.denied,
    );
  });

  test('openSettings opens the app\'s page in the phone\'s settings', () async {
    await const PhotoManagerGallery().openSettings();
    expect(phone.settingsOpened, 1);
  });
}
