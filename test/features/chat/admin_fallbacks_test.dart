// R2: an admin chat with no staffKey (old stored row) shows the neutral title.
// R3: an old salesSwitchOn/salesSwitchOff reply without `c` shows the localized text with
// the neutral "Total money" title; with `c` the command name is used.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/admin_reply_bubble.dart';
import 'package:sis/features/chat/presentation/member_name.dart';

import '../../support/l10n.dart';

void main() {
  test(
    'admin chat without staffKey shows the neutral staff title, not Member',
    () {
      const c = Conversation(id: 'c1', isAdminChat: true);
      for (final l in [l10nEn, l10nTr]) {
        expect(conversationLabel(l, c), l.staffChatTitleFallback);
        expect(conversationLabel(l, c), isNot(l.commonMember));
      }
    },
  );

  for (final (key, on) in [
    ('salesSwitchOn', true),
    ('salesSwitchOff', false),
  ]) {
    test('$key without c uses the neutral title in EN and TR', () {
      for (final l in [l10nEn, l10nTr]) {
        final want = on
            ? l.salesSwOn(l.salesTitle)
            : l.salesSwOff(l.salesTitle);
        expect(adminReplyText(l, {'k': key}), want);
        expect(adminReplyText(l, {'k': key}), contains(l.salesTitle));
      }
      expect(l10nEn.salesTitle, isNot(l10nTr.salesTitle));
    });

    test('$key with c names the command', () {
      final l = l10nTr;
      final want = on ? l.salesSwOn('rapor') : l.salesSwOff('rapor');
      expect(adminReplyText(l, {'k': key, 'c': 'rapor'}), want);
    });
  }
}
