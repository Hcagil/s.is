// Private Chats 4b I3: one locked text for an encrypted push, the same on
// both platforms, EN and TR: Android's notification_locked strings and the
// iPhone NotificationService body.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String androidString(String path) {
  final m = RegExp(r'<string name="notification_locked">([^<]*)</string>')
      .firstMatch(File(path).readAsStringSync());
  expect(m, isNotNull, reason: '$path has no notification_locked');
  return m!.group(1)!;
}

void main() {
  test('Android and iPhone show the same locked text, EN and TR', () {
    final swift = File('ios/NotificationService/NotificationService.swift')
        .readAsStringSync();
    final ios = RegExp(r'turkish \? "([^"]*)" : "([^"]*)"')
        .allMatches(swift)
        .toList();
    expect(ios, hasLength(1), reason: 'one TR/EN locked body on iPhone');
    final (iosTr, iosEn) = (ios.single.group(1)!, ios.single.group(2)!);

    final en = androidString('android/app/src/main/res/values/strings.xml');
    final tr = androidString('android/app/src/main/res/values-tr/strings.xml');

    expect(en, '🔒 New message');
    expect(tr, '🔒 Yeni mesaj');
    expect(iosEn, en);
    expect(iosTr, tr);
  });
}
