// iOS only offers a language the bundle declares: every locale the app ships
// must be in Info.plist's CFBundleLocalizations and in the Xcode project's
// knownRegions, or iOS shows the app in English to a Turkish phone.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/l10n/app_localizations.dart';

void main() {
  final codes = AppLocalizations.supportedLocales.map((l) => l.languageCode);

  test('Info.plist lists every supported language', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final m = RegExp(
      r'<key>CFBundleLocalizations</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist);
    expect(m, isNotNull, reason: 'CFBundleLocalizations missing');
    final listed = RegExp(r'<string>([^<]+)</string>')
        .allMatches(m!.group(1)!)
        .map((x) => x.group(1))
        .toSet();
    expect(listed, containsAll(codes));
  });

  test('the Xcode project knows every supported region', () {
    final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final m = RegExp(r'knownRegions = \(([^)]*)\)').firstMatch(pbx);
    expect(m, isNotNull);
    final regions = m!.group(1)!.split(',').map((s) => s.trim()).toSet();
    expect(regions, containsAll(codes));
  });
}
