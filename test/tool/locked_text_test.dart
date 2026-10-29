// One fallback text for a push whose words cannot be shown, the same on both
// platforms, EN and TR: Android's notification_fallback strings and the
// iPhone NotificationService body. notification_locked no longer exists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String androidString(String path) {
  final xml = File(path).readAsStringSync();
  expect(xml, isNot(contains('notification_locked')), reason: path);
  final m = RegExp(r'<string name="notification_fallback">([^<]*)</string>')
      .firstMatch(xml);
  expect(m, isNotNull, reason: '$path has no notification_fallback');
  return m!.group(1)!;
}

void main() {
  test('Android and iPhone show the same fallback text, EN and TR', () {
    final swift = File('ios/NotificationService/NotificationService.swift')
        .readAsStringSync();
    final ios = RegExp(r'turkish \? "([^"]*)" : "([^"]*)"')
        .allMatches(swift)
        .toList();
    expect(ios, hasLength(1), reason: 'one TR/EN fallback body on iPhone');
    final (iosTr, iosEn) = (ios.single.group(1)!, ios.single.group(2)!);

    final en = androidString('android/app/src/main/res/values/strings.xml');
    final tr = androidString('android/app/src/main/res/values-tr/strings.xml');

    expect(en, 'New message');
    expect(tr, 'Yeni mesaj');
    expect(iosEn, en);
    expect(iosTr, tr);
  });
}
