import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/message.dart';

// isClosed: default, copy methods, JSON. Written from the contract.
Conversation _c({bool closed = false}) =>
    Conversation(id: 'g1', title: 'Club', lastMessage: 'yo', isClosed: closed);

void main() {
  test('defaults to false', () {
    expect(const Conversation(id: 'g1').isClosed, isFalse);
  });

  test('round trip keeps true, through real JSON text', () {
    final j = jsonDecode(jsonEncode(_c(closed: true).toJson()));
    expect(Conversation.fromJson(j as Map<String, dynamic>).isClosed, isTrue);
  });

  test('round trip keeps false; the key is omitted when false', () {
    final json = _c().toJson();
    expect(json.containsKey('isClosed'), isFalse);
    expect(Conversation.fromJson(json).isClosed, isFalse);
  });

  test('toJson writes isClosed: true only when closed', () {
    expect(_c(closed: true).toJson()['isClosed'], isTrue);
  });

  test('an old snapshot without the key reads as open', () {
    final json = _c(closed: true).toJson()..remove('isClosed');
    expect(Conversation.fromJson(json).isClosed, isFalse);
  });

  test('copy methods carry isClosed', () {
    final c = _c(closed: true);
    expect(c.withArchived(true).isClosed, isTrue);
    expect(c.withArchived(false).isClosed, isTrue);
    expect(c.read().isClosed, isTrue);
    expect(c.withLastMessage('x').isClosed, isTrue);
    expect(c.withSettings(const GroupSettings()).isClosed, isTrue);
    expect(c.withPinned(true).isClosed, isTrue);
    expect(c.withPinnedMessage('m').isClosed, isTrue);
    final msg = Message(
      id: 'm1',
      conversationId: 'g1',
      senderId: 'u2',
      body: 'hi',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    expect(c.withPreview(msg, counts: true).isClosed, isTrue);
  });
}
