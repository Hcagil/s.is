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

  /// Every domain a rule can name (Android docs, Auto Backup).
  const domains = ['root', 'file', 'database', 'sharedpref', 'external'];

  /// Each rule must name a path; "." is the whole domain. A rule without
  /// one is invalid, and what Android makes of it is not ours to guess.
  void expectWholeDomains(String rules) {
    final excludes = RegExp(r'<exclude\b[^>]*>').allMatches(rules).toList();
    expect(excludes, isNotEmpty);
    for (final e in excludes) {
      expect(e.group(0), contains('path="."'), reason: '${e.group(0)}');
    }
  }

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
      for (final domain in domains) {
        expect(
          body,
          matches(RegExp('<exclude[^>]*domain="$domain"')),
          reason: '<$section> does not exclude $domain',
        );
      }
    }
    expectWholeDomains(rules);
  });

  test('Android 11 and lower: full backup content excludes every domain', () {
    final ref = RegExp(r'android:fullBackupContent="@xml/([a-z_]+)"')
        .firstMatch(application);
    expect(ref, isNotNull, reason: 'no fullBackupContent on <application>');
    final rules = File('android/app/src/main/res/xml/${ref!.group(1)}.xml')
        .readAsStringSync();
    expect(rules, contains('<full-backup-content'));
    expect(rules, isNot(contains('<include')), reason: 'nothing is included');
    for (final domain in domains) {
      expect(
        rules,
        matches(RegExp('<exclude[^>]*domain="$domain"')),
        reason: 'does not exclude $domain',
      );
    }
    expectWholeDomains(rules);
  });
}
