// The manifest's own contract for photo access (v0.9): read straight from
// the file, so a plugin upgrade or an edit that widens photo or video access
// fails CI, not just a device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String manifest;

  setUpAll(() {
    manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
  });

  test('declares the photo permissions the attachment sheet needs', () {
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>',
      ),
    );
    expect(
      manifest,
      contains(
        '<uses-permission '
        'android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED"/>',
      ),
    );
  });

  test('the legacy storage read is capped at API 32', () {
    expect(
      manifest,
      contains(
        '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" '
        'android:maxSdkVersion="32"/>',
      ),
      reason:
          'without the cap, a device on API 33+ would still be asked for '
          'the old, broader storage permission',
    );
  });

  test('removes what the photo library plugin would otherwise add', () {
    for (final permission in [
      'READ_MEDIA_VIDEO',
      'READ_MEDIA_AUDIO',
      'WRITE_EXTERNAL_STORAGE',
      'ACCESS_MEDIA_LOCATION',
    ]) {
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.$permission" '
          'tools:node="remove"/>',
        ),
        reason:
            '$permission is not needed for photos only; it must be '
            'explicitly removed, not merely unused, or a plugin upgrade '
            'silently brings it back',
      );
    }
  });
}
