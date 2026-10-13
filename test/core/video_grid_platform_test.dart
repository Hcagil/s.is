import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/platform_features.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

void main() {
  group('video grid switch', () {
    test('videoGridOnIos is true; videoGridOnAndroid is false', () {
      expect(videoGridOnIos, isTrue);
      expect(videoGridOnAndroid, isFalse);
    });

    test('inAppVideoGrid true on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(inAppVideoGrid, isTrue);
    });

    test('inAppVideoGrid false on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(inAppVideoGrid, isFalse);
    });

    test('inAppVideoGrid false on Linux', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(inAppVideoGrid, isFalse);
    });

    test('inAppVideoGrid false with no override', () {
      debugDefaultTargetPlatformOverride = null;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(inAppVideoGrid, isFalse);
    });

    test('videoGridEnabledProvider true on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer.test();
      expect(container.read(videoGridEnabledProvider), isTrue);
    });

    test('videoGridEnabledProvider false on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer.test();
      expect(container.read(videoGridEnabledProvider), isFalse);
    });

    test('videoGridEnabledProvider false with no override', () {
      debugDefaultTargetPlatformOverride = null;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final container = ProviderContainer.test();
      expect(container.read(videoGridEnabledProvider), isFalse);
    });

    test('videoGridEnabledProvider override works', () {
      final container = ProviderContainer.test(
        overrides: [videoGridEnabledProvider.overrideWithValue(true)],
      );
      expect(container.read(videoGridEnabledProvider), isTrue);
    });

    test('videoGalleryProvider throws without override', () {
      expect(
        () => ProviderContainer.test().read(videoGalleryProvider),
        throwsA(anything),
      );
    });
  });

  group('release files', () {
    test('iOS InfoPlist.strings contain NSPhotoLibraryUsageDescription', () {
      final enPath = 'ios/Runner/en.lproj/InfoPlist.strings';
      final trPath = 'ios/Runner/tr.lproj/InfoPlist.strings';
      final enContent = File(enPath).readAsStringSync();
      final trContent = File(trPath).readAsStringSync();

      final regex = RegExp(
        r'^"NSPhotoLibraryUsageDescription"\s*=\s*"[^"]+";',
        multiLine: true,
      );
      expect(regex.hasMatch(enContent), isTrue);
      expect(regex.hasMatch(trContent), isTrue);

      final valueRegex = RegExp(
        r'"NSPhotoLibraryUsageDescription"\s*=\s*"([^"]+)"',
      );
      final enMatch = valueRegex.firstMatch(enContent);
      final trMatch = valueRegex.firstMatch(trContent);
      expect(enMatch, isNotNull);
      expect(trMatch, isNotNull);
      final enValue = enMatch!.group(1);
      final trValue = trMatch!.group(1);
      expect(enValue, isNot(equals(trValue)));
    });

    test(
      'ios/Runner/Info.plist contains NSPhotoLibraryUsageDescription key',
      () {
        final plistPath = 'ios/Runner/Info.plist';
        final plistContent = File(plistPath).readAsStringSync();
        expect(
          plistContent.contains('<key>NSPhotoLibraryUsageDescription</key>'),
          isTrue,
        );
      },
    );

    test('android manifest READ_MEDIA_VIDEO permission removed', () {
      final manifestPath = 'android/app/src/main/AndroidManifest.xml';
      final manifestContent = File(manifestPath).readAsStringSync();

      final permissionRegex = RegExp(
        r'<uses-permission\b[^>]*android\.permission\.READ_MEDIA_VIDEO[^>]*>',
      );
      final matches = permissionRegex.allMatches(manifestContent).toList();
      expect(matches.isNotEmpty, isTrue);

      for (final match in matches) {
        final tag = match.group(0)!;
        expect(tag.contains('tools:node="remove"'), isTrue);
      }

      expect(
        manifestContent.contains(
          'xmlns:tools="http://schemas.android.com/tools"',
        ),
        isTrue,
      );
    });
  });
}
