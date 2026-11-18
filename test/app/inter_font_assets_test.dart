import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Inter font assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    test('pubspec declares Inter with weights 400,500,600,700,800', () {
      expect(
        pubspec.contains('- family: Inter'),
        isTrue,
        reason: 'Inter family not declared',
      );
      for (final w in [400, 500, 600, 700, 800]) {
        final assetLine = 'assets/fonts/Inter-$w.ttf';
        final weightLine = 'weight: $w';
        expect(
          pubspec.contains(assetLine),
          isTrue,
          reason: 'Missing asset $assetLine',
        );
        expect(
          pubspec.contains(weightLine),
          isTrue,
          reason: 'Missing weight $weightLine',
        );
        expect(
          File('assets/fonts/Inter-$w.ttf').existsSync(),
          isTrue,
          reason: 'Font file Inter-$w.ttf does not exist',
        );
      }
    });

    test('Inter licence file exists and is the SIL Open Font License', () {
      final licenseFile = File('assets/fonts/OFL-inter.txt');
      expect(
        licenseFile.existsSync(),
        isTrue,
        reason: 'Inter licence file not found',
      );
      final content = licenseFile.readAsStringSync();
      expect(
        content.contains('SIL Open Font License'),
        isTrue,
        reason: 'Inter licence does not contain SIL Open Font License',
      );
    });

    test('no Manrope is left', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec.toLowerCase().contains('manrope'),
        isFalse,
        reason: 'pubspec still references Manrope',
      );

      final fontsDir = Directory('assets/fonts');
      final hasManropeFile = fontsDir
          .listSync(recursive: true)
          .any((f) => f.path.toLowerCase().contains('manrope'));
      expect(
        hasManropeFile,
        isFalse,
        reason: 'Some font file contains Manrope in its path',
      );

      final manropeLicense = File('assets/fonts/OFL-manrope.txt');
      expect(
        manropeLicense.existsSync(),
        isFalse,
        reason: 'Manrope licence file still exists',
      );
    });

    test('Sora is still declared for the wordmark', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        pubspec.contains('- family: Sora'),
        isTrue,
        reason: 'Sora family not declared',
      );

      final soraFont = File('assets/fonts/Sora-800.ttf');
      expect(
        soraFont.existsSync(),
        isTrue,
        reason: 'Sora-800.ttf font file does not exist',
      );
    });
  });
}
