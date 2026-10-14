// Contract: Verify that location usage descriptions are present and consistent
// in Info.plist and in each lproj InfoPlist.strings file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extracts the string value for a given key from an Info.plist XML file.
/// Returns null if the key is not found.
String? plistString(String plist, String key) {
  final pattern = RegExp(
    r'<key>' + RegExp.escape(key) + r'</key>\s*<string>(.*?)</string>',
    dotAll: true,
  );
  final match = pattern.firstMatch(plist);
  return match?.group(1);
}

/// Extracts the string value for a given key from an InfoPlist.strings file.
/// Handles escaped quotes inside the value.
/// Returns null if the key is not found.
String? stringsValue(String strings, String key) {
  final pattern = RegExp(
    r'"' + RegExp.escape(key) + r'"\s*=\s*"((?:\\.|[^"\\])*)";',
    dotAll: true,
  );
  final match = pattern.firstMatch(strings);
  return match?.group(1);
}

void main() {
  test('Info.plist has the Always-and-When-In-Use location text', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    final always = plistString(
      plist,
      'NSLocationAlwaysAndWhenInUseUsageDescription',
    );
    final when = plistString(plist, 'NSLocationWhenInUseUsageDescription');

    expect(
      always,
      isNotNull,
      reason: 'NSLocationAlwaysAndWhenInUseUsageDescription missing',
    );
    expect(
      when,
      isNotNull,
      reason: 'NSLocationWhenInUseUsageDescription missing',
    );

    expect(
      always!.trim(),
      isNotEmpty,
      reason: 'NSLocationAlwaysAndWhenInUseUsageDescription empty',
    );
    expect(
      when!.trim(),
      isNotEmpty,
      reason: 'NSLocationWhenInUseUsageDescription empty',
    );

    expect(
      always.trim(),
      equals(when.trim()),
      reason: 'NSLocationAlwaysAndWhenInUseUsageDescription must equal NSLocationWhenInUseUsageDescription',
    );
  });

  for (final lang in ['en', 'tr']) {
    test('lproj $lang InfoPlist.strings contains matching usage descriptions', () {
      final strings = File('ios/Runner/$lang.lproj/InfoPlist.strings')
          .readAsStringSync();

      final always = stringsValue(
        strings,
        'NSLocationAlwaysAndWhenInUseUsageDescription',
      );
      final when = stringsValue(strings, 'NSLocationWhenInUseUsageDescription');

      expect(
        always,
        isNotNull,
        reason: 'NSLocationAlwaysAndWhenInUseUsageDescription missing in $lang',
      );
      expect(
        when,
        isNotNull,
        reason: 'NSLocationWhenInUseUsageDescription missing in $lang',
      );

      expect(
        always!.trim(),
        isNotEmpty,
        reason: 'NSLocationAlwaysAndWhenInUseUsageDescription empty in $lang',
      );
      expect(
        when!.trim(),
        isNotEmpty,
        reason: 'NSLocationWhenInUseUsageDescription empty in $lang',
      );

      expect(
        always.trim(),
        equals(when.trim()),
        reason:
            'NSLocationAlwaysAndWhenInUseUsageDescription must equal NSLocationWhenInUseUsageDescription in $lang',
      );
    });
  }
}
