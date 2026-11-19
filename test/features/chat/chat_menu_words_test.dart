import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

void main() {
  group('mark-as-unread words', () {
    test('English words', () {
      expect(l10nEn.chatMenuMarkUnread, equals('Mark as unread'));
      expect(l10nEn.chatMarkedUnread, equals('Chat marked as unread'));
      expect(l10nEn.commonSelect, equals('Select'));
    });

    test('Turkish words', () {
      expect(l10nTr.chatMenuMarkUnread, equals('Okunmadı olarak işaretle'));
      expect(
        l10nTr.chatMarkedUnread,
        equals('Sohbet okunmadı olarak işaretlendi'),
      );
      expect(l10nTr.commonSelect, equals('Seç'));
    });

    test('the three words differ between the languages and are not empty', () {
      expect(
        l10nEn.chatMenuMarkUnread,
        isNot(equals(l10nTr.chatMenuMarkUnread)),
      );
      expect(l10nEn.chatMarkedUnread, isNot(equals(l10nTr.chatMarkedUnread)));
      expect(l10nEn.commonSelect, isNot(equals(l10nTr.commonSelect)));

      expect(l10nEn.chatMenuMarkUnread, isNotEmpty);
      expect(l10nTr.chatMenuMarkUnread, isNotEmpty);

      expect(l10nEn.chatMarkedUnread, isNotEmpty);
      expect(l10nTr.chatMarkedUnread, isNotEmpty);

      expect(l10nEn.commonSelect, isNotEmpty);
      expect(l10nTr.commonSelect, isNotEmpty);
    });
  });
}
