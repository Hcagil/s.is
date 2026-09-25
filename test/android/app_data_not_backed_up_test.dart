// The app's data never leaves the phone through Android backup or a
// device-to-device transfer: the stored notification previews (and the
// session) would otherwise be restored onto another phone, for whoever signs
// in there. A build does not fail when either setting is dropped, so this
// reads the manifest and the rules file the build packages.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final application = RegExp(r'<application\b[^>]*>')
      .firstMatch(manifest)!
      .group(0)!;

  test('backup is off for the application', () {
    expect(application, contains('android:allowBackup="false"'));
  });

  test('Android 12+ extraction rules exclude every domain from cloud backup '
      'and from device transfer', () {
    final ref = RegExp(r'android:dataExtractionRules="@xml/([a-z_]+)"')
        .firstMatch(application);
    expect(ref, isNotNull, reason: 'no dataExtractionRules on <application>');
    final rules = File('android/app/src/main/res/xml/${ref!.group(1)}.xml')
        .readAsStringSync();
    expect(rules, isNot(contains('<include')), reason: 'nothing is included');
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section\\b[^>]*>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: 'no <$section> section');
      for (final domain in ['root', 'file', 'database', 'sharedpref']) {
        expect(
          body,
          matches(RegExp('<exclude[^>]*domain="$domain"')),
          reason: '<$section> does not exclude $domain',
        );
      }
    }
  });
}
