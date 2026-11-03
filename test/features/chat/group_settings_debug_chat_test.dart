// GroupSettings.debugChat: default false, kept by copyWith and JSON.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/group_settings.dart';

void main() {
  test('false by default', () {
    expect(const GroupSettings().debugChat, isFalse);
  });

  test('survives copyWith of another field', () {
    final s = const GroupSettings(debugChat: true)
        .copyWith(membersCanAdd: false);
    expect(s.debugChat, isTrue);
    expect(s.membersCanAdd, isFalse);
  });

  test('survives a JSON round trip', () {
    const s = GroupSettings(debugChat: true);
    expect(GroupSettings.fromJson(s.toJson()).debugChat, isTrue);
    expect(
      GroupSettings.fromJson(const GroupSettings().toJson()).debugChat,
      isFalse,
    );
  });

  test('an old JSON without the key reads false', () {
    expect(GroupSettings.fromJson(const {}).debugChat, isFalse);
  });

  test('equality tells debug from non-debug', () {
    expect(const GroupSettings(debugChat: true), isNot(const GroupSettings()));
  });
}
