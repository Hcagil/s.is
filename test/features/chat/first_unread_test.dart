import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/first_unread.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  // Helper to create a list of messages with optional own messages.
  List<Message> buildMessages(List<int> indices, {bool ownAtEven = false}) {
    return indices.map((i) {
      final sender = (ownAtEven && i % 2 == 0) ? 'u1' : 'u2';
      return Message(
        id: 'm$i',
        conversationId: 'c1',
        senderId: sender,
        body: 'x',
        createdAt: DateTime.utc(2026, 9, 1, 8).add(Duration(minutes: i)),
      );
    }).toList();
  }

  test('empty list returns null', () {
    final result = firstUnreadId([], 1, 'u1');
    expect(result, null);
  });

  test('unread 0 returns null', () {
    final msgs = buildMessages([0, 1, 2]);
    final result = firstUnreadId(msgs, 0, 'u1');
    expect(result, null);
  });

  test('negative unread returns null', () {
    final msgs = buildMessages([0, 1, 2]);
    final result = firstUnreadId(msgs, -1, 'u1');
    expect(result, null);
  });

  test('me null returns null', () {
    final msgs = buildMessages([0, 1, 2]);
    final result = firstUnreadId(msgs, 1, null);
    expect(result, null);
  });

  test('unread 1 newest incoming', () {
    final msgs = buildMessages([0, 1, 2]); // all incoming
    final result = firstUnreadId(msgs, 1, 'u1');
    expect(result, 'm2');
  });

  test('unread 3 of 5 all incoming', () {
    final msgs = buildMessages([0, 1, 2, 3, 4]); // all incoming
    final result = firstUnreadId(msgs, 3, 'u1');
    expect(result, 'm2');
  });

  test('own messages interleaved are skipped', () {
    final msgs = buildMessages([0, 1, 2, 3, 4], ownAtEven: true);
    // indices: 0 own,1 in,2 own,3 in,4 own
    expect(firstUnreadId(msgs, 1, 'u1'), 'm3');
    expect(firstUnreadId(msgs, 2, 'u1'), 'm1');
    expect(firstUnreadId(msgs, 3, 'u1'), null);
  });

  test('newest messages own are skipped', () {
    final msgs = buildMessages([0, 1, 2], ownAtEven: true);
    // 0 own,1 in,2 own
    final result = firstUnreadId(msgs, 1, 'u1');
    expect(result, 'm1');
  });

  test('unread greater than loaded incoming returns null', () {
    final msgs = buildMessages([0, 1, 2]); // all incoming
    final result = firstUnreadId(msgs, 5, 'u1');
    expect(result, null);
  });

  test('orOldest true with fewer incoming returns oldest', () {
    final msgs = buildMessages([0, 1, 2]); // all incoming
    final result = firstUnreadId(msgs, 5, 'u1', orOldest: true);
    expect(result, 'm0');
  });

  test('orOldest true with all own returns null', () {
    final msgs = [
      Message(
        id: 'a0',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'x',
        createdAt: DateTime.utc(2026, 9, 1, 8),
      ),
      Message(
        id: 'a1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'x',
        createdAt: DateTime.utc(2026, 9, 1, 8).add(Duration(minutes: 1)),
      ),
      Message(
        id: 'a2',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'x',
        createdAt: DateTime.utc(2026, 9, 1, 8).add(Duration(minutes: 2)),
      ),
    ];
    final result = firstUnreadId(msgs, 1, 'u1', orOldest: true);
    expect(result, null);
  });

  test('orOldest true with enough loaded behaves like normal', () {
    final msgs = buildMessages([0, 1, 2, 3, 4]); // all incoming
    final result = firstUnreadId(msgs, 3, 'u1', orOldest: true);
    expect(result, 'm2');
  });

  test('unread equals incoming count returns oldest incoming', () {
    final msgs = buildMessages([0, 1, 2]); // all incoming
    final result = firstUnreadId(msgs, 3, 'u1');
    expect(result, 'm0');
  });

  test('orOldest with fewer incoming and own messages mixed returns oldest incoming',
      () {
    final msgs = buildMessages([0, 1, 2, 3, 4], ownAtEven: true);
    // incoming m1, m3
    final result = firstUnreadId(msgs, 9, 'u1', orOldest: true);
    expect(result, 'm1');
  });
}
