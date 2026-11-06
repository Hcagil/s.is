// Conversation.staffKey, from the contract: the neutral key of a staff chat
// (looked up in the server's staff registry), null for every other chat; the
// stored list (toJson/fromJson) keeps it; an old row without it, or with a
// leftover key the app no longer knows, reads as a normal chat. The label of
// a staff chat has no built-in name: the screen uses the registry title, else
// the neutral l10n fallback.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/member_name.dart';

import '../../support/l10n.dart';

void main() {
  const member = Member(userId: 'u2', displayName: 'Bob');

  test('toJson writes staffKey only when set', () {
    const staff = Conversation(
      id: 'c1',
      title: 'x',
      isAdminChat: true,
      staffKey: 'staff_a',
    );
    expect(staff.toJson()['staffKey'], 'staff_a');
    const plain = Conversation(id: 'c2', other: member);
    expect(plain.toJson().containsKey('staffKey'), isFalse);
  });

  test('fromJson keeps staffKey', () {
    const staff = Conversation(
      id: 'c3',
      title: 'x',
      isAdminChat: true,
      staffKey: 'staff_b',
    );
    final back = Conversation.fromJson(staff.toJson());
    expect(back.staffKey, 'staff_b');
    expect(back.isAdminChat, isTrue);
  });

  test('a stored row without staffKey, with a leftover unknown key, is a normal chat', () {
    final map = const Conversation(id: 'c4', title: 'Work').toJson()
      ..['isOldFlag'] = true;
    late Conversation c;
    expect(() => c = Conversation.fromJson(map), returnsNormally);
    expect(c.staffKey, isNull);
    expect(c.isAdminChat, isFalse);
    expect(c.label, 'Work');
  });

  test('a staff chat has no built-in name; the label falls back to the neutral key', () {
    const staff = Conversation(
      id: 'c5',
      title: 'x',
      isAdminChat: true,
      staffKey: 'staff_a',
    );
    for (final l in [l10nEn, l10nTr]) {
      expect(conversationLabel(l, staff), l.staffChatTitleFallback);
    }
    expect(l10nEn.staffChatTitleFallback, isNot(l10nTr.staffChatTitleFallback));
  });

  test('a normal titled conversation is labelled by its title', () {
    const c = Conversation(id: 'c7', title: 'Work');
    expect(c.label, 'Work');
    expect(conversationLabel(l10nEn, c), 'Work');
  });
}
