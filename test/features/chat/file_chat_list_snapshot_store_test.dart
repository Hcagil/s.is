// FileChatListSnapshotStore, written from the ChatListSnapshotStore contract
// (lib/features/chat/domain/chat_list_snapshot_store.dart) and the stored
// chat list section of docs/SECURITY.md, never from the implementation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/file_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/auth/domain/member.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat-list-store-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileChatListSnapshotStore store() =>
      FileChatListSnapshotStore(root: () async => root);

  // Helper to compare two conversation lists field‑by‑field.
  void expectConversationsEqual(
    List<Conversation> expected,
    List<Conversation> actual,
  ) {
    expect(actual.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      final e = expected[i];
      final a = actual[i];
      expect(a.id, e.id);
      expect(a.title, e.title);
      expect(a.lastMessage, e.lastMessage);
      if (e.lastMessageAt == null) {
        expect(a.lastMessageAt, isNull);
      } else {
        expect(a.lastMessageAt!.isAtSameMomentAs(e.lastMessageAt!), isTrue);
      }
      expect(a.lastSenderId, e.lastSenderId);
      expect(a.unread, e.unread);
      expect(a.avatarPath, e.avatarPath);
      expect(a.hasLeft, e.hasLeft);
      if (e.other == null) {
        expect(a.other, null);
      } else {
        expect(a.other, isNotNull);
        expect(a.other!.userId, e.other!.userId);
        expect(a.other!.displayName, e.other!.displayName);
        expect(a.other!.tag, e.other!.tag);
        // Never stored (docs/SECURITY.md, stored chat list).
        expect(a.other!.email, isNull);
        expect(a.other!.avatarPath, e.other!.avatarPath);
      }
    }
  }

  test('1. load with nothing saved returns null', () async {
    final s = store();
    expect(await s.load('owner'), isNull);
  });

  test(
    '2. save then load for the same owner returns all fields and order',
    () async {
      final s = store();
      final convs = [
        Conversation(
          id: 'g1',
          title: 'Group Chat',
          lastMessage: 'Hello',
          lastMessageAt: DateTime.now(),
          lastSenderId: 'u1',
          unread: 5,
          avatarPath: '/path/to/avatar.png',
          hasLeft: false,
        ),
        Conversation(
          id: 'c1',
          other: Member(
            userId: 'u2',
            displayName: 'Alice',
            tag: 'A',
            email: 'alice@example.com',
            avatarPath: '/avatars/alice.png',
          ),
          lastMessage: 'Hi',
          lastMessageAt: DateTime.now(),
          lastSenderId: 'u2',
          unread: 0,
          avatarPath: null,
          hasLeft: false,
        ),
        Conversation(
          id: 'c2',
          other: Member(
            userId: 'u3',
            displayName: 'Bob',
            tag: null,
            email: null,
            avatarPath: null,
          ),
          hasLeft: true,
          lastMessage: null,
          lastMessageAt: null,
          lastSenderId: null,
          unread: 0,
          avatarPath: null,
        ),
      ];
      await s.save('owner', convs);
      final loaded = await s.load('owner');
      expect(loaded, isNotNull);
      expectConversationsEqual(convs, loaded!);
    },
  );

  test('3. a new store instance on the same root reads what another instance saved', () async {
    final s1 = store();
    final convs = [
      Conversation(id: 'x', title: 'X', other: null, hasLeft: false),
    ];
    await s1.save('owner', convs);
    final s2 = store();
    final loaded = await s2.load('owner');
    expect(loaded, isNotNull);
    expectConversationsEqual(convs, loaded!);
  });

  test('4. load for a different owner returns null and deletes file', () async {
    final s = store();
    final convs = [
      Conversation(id: 'x', title: 'X', other: null, hasLeft: false),
    ];
    await s.save('owner', convs);
    final file = File('${root.path}/chat_list.json');
    expect(await file.exists(), isTrue);
    final loadedDiff = await s.load('other');
    expect(loadedDiff, isNull);
    expect(await file.exists(), isFalse);
    final loadedSame = await s.load('owner');
    expect(loadedSame, isNull);
  });

  test('5. save replaces previous snapshot', () async {
    final s = store();
    await s.save('a', [
      Conversation(id: 'a1', title: 'A', other: null, hasLeft: false),
    ]);
    await s.save('b', [
      Conversation(id: 'b1', title: 'B', other: null, hasLeft: false),
    ]);
    final loadedB = await s.load('b');
    expect(loadedB, isNotNull);
    expectConversationsEqual([
      Conversation(id: 'b1', title: 'B', other: null, hasLeft: false),
    ], loadedB!);
    // A's list is gone, not merely hidden (and asking as A erases B's).
    expect(await s.load('a'), isNull);
  });

  test('6. member email is never written', () async {
    final s = store();
    final conv = Conversation(
      id: 'c',
      other: Member(userId: 'u', displayName: 'User', email: 'x@example.org'),
      hasLeft: false,
    );
    await s.save('owner', [conv]);
    final content = await File('${root.path}/chat_list.json').readAsString();
    expect(content.contains('x@example.org'), isFalse);
  });

  test('7. corrupt file: load returns null and deletes file', () async {
    final file = File('${root.path}/chat_list.json');
    await file.writeAsString('not json{');
    final s = store();
    final loaded = await s.load('owner');
    expect(loaded, isNull);
    expect(await file.exists(), isFalse);
  });

  test('8. valid JSON of wrong shape returns null and deletes file', () async {
    final file = File('${root.path}/chat_list.json');
    for (final bad in ['[]', '{"foo":1}']) {
      await file.writeAsString(bad);
      final s = store();
      final loaded = await s.load('owner');
      expect(loaded, isNull);
      expect(await file.exists(), isFalse);
    }
  });

  test(
    '9. unknown schema version causes load to return null and delete file',
    () async {
      final s = store();
      await s.save('owner', [
        Conversation(id: 'x', title: 'X', other: null, hasLeft: false),
      ]);
      final file = File('${root.path}/chat_list.json');
      final jsonStr = await file.readAsString();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      bool found = false;
      data.forEach((key, value) {
        final lk = key.toLowerCase();
        if (lk.contains('version') || lk == 'v' || lk == 'schema') {
          data[key] = 999;
          found = true;
        }
      });
      expect(found, isTrue, reason: 'No version key found in JSON');
      await file.writeAsString(jsonEncode(data));
      final loaded = await s.load('owner');
      expect(loaded, isNull);
      expect(await file.exists(), isFalse);
    },
  );

  test('10. clear removes chat_list.json', () async {
    final s = store();
    await s.save('owner', [
      Conversation(id: 'x', title: 'X', other: null, hasLeft: false),
    ]);
    await s.clear();
    expect(await File('${root.path}/chat_list.json').exists(), isFalse);
    expect(await s.load('owner'), isNull);
  });

  test('11. clear removes leftover .part file as well', () async {
    final part = File('${root.path}/chat_list.json.part');
    await part.writeAsString('dummy');
    final s = store();
    await s.clear();
    expect(await part.exists(), isFalse);
    expect(await File('${root.path}/chat_list.json').exists(), isFalse);
  });

  test('12. clear on an empty directory does not throw', () async {
    final s = store();
    await s.clear(); // should not throw
  });

  test('13. a leftover .part is never loaded, even a complete one', () async {
    // A crash between the temporary write and its rename: the finished file
    // is gone, only its ".part" sibling -- here a whole, valid one -- is left.
    final s = store();
    await s.save('owner', [const Conversation(id: 'x', title: 'X')]);
    await File('${root.path}/chat_list.json')
        .rename('${root.path}/chat_list.json.part');

    expect(await store().load('owner'), isNull);
  });

  test(
    '14. failing storage root: operations complete without throwing',
    () async {
      // Root function throws.
      final sThrow = FileChatListSnapshotStore(
        root: () async => throw const FileSystemException('fail'),
      );
      await expectLater(sThrow.save('owner', const []), completes);
      expect(await sThrow.load('owner'), isNull);
      await expectLater(sThrow.clear(), completes);

      // Root points to a regular file, not a directory.
      final fileRoot = File('${root.path}/notadir');
      await fileRoot.create();
      final sFile = FileChatListSnapshotStore(
        root: () async => Directory(fileRoot.path),
      );
      await expectLater(sFile.save('owner', const []), completes);
      expect(await sFile.load('owner'), isNull);
      await expectLater(sFile.clear(), completes);
    },
  );

  test('15. save racing a clear loses', () async {
    final s = store();
    final convs = [
      Conversation(id: 'x', title: 'X', other: null, hasLeft: false),
    ];
    final f1 = s.save('a', convs);
    final f2 = s.clear();
    await Future.wait([f1, f2]);
    expect(await File('${root.path}/chat_list.json').exists(), isFalse);
    expect(await File('${root.path}/chat_list.json.part').exists(), isFalse);
    expect(await s.load('a'), isNull);

    // Reverse order
    final f3 = s.save('a', convs);
    await Future.delayed(Duration.zero);
    final f4 = s.clear();
    await Future.wait([f3, f4]);
    expect(await File('${root.path}/chat_list.json').exists(), isFalse);
    expect(await File('${root.path}/chat_list.json.part').exists(), isFalse);
    expect(await s.load('a'), isNull);
  });

  test('16. unread and lastMessageAt preserved in UTC and local', () async {
    final s = store();
    final utcTime = DateTime.utc(2026, 9, 29, 12, 0);
    final conv = Conversation(
      id: 'x',
      title: 'X',
      lastMessageAt: utcTime,
      unread: 7,
      other: null,
      hasLeft: false,
    );
    await s.save('owner', [conv]);
    final loaded = await s.load('owner');
    expect(loaded, isNotNull);
    final loadedConv = loaded!.first;
    expect(loadedConv.lastMessageAt?.isAtSameMomentAs(utcTime), isTrue);
    expect(loadedConv.unread, 7);
  });

  test('a save held at any of its storage lookups loses to a clear that '
      'finishes first', () async {
    final convs = [const Conversation(id: 'x', title: 'X')];
    var tested = 0;
    for (var k = 0; k < 6; k++) {
      final sub = await Directory('${root.path}/k$k').create();
      var n = 0;
      var clearing = false;
      final held = Completer<void>();
      final reached = Completer<void>();
      final s = FileChatListSnapshotStore(
        root: () async {
          if (!clearing && n++ == k) {
            reached.complete();
            await held.future;
          }
          return sub;
        },
      );
      final saving = s.save('a', convs);
      final wasHeld = await Future.any([
        reached.future.then((_) => true),
        saving.then((_) => false),
      ]);
      if (!wasHeld) break; // the save looks the directory up fewer times
      clearing = true;
      await s.clear();
      held.complete();
      await saving;

      expect(
        await File('${sub.path}/chat_list.json').exists(),
        isFalse,
        reason: 'a save held at lookup $k re-created the file after clear()',
      );
      expect(await File('${sub.path}/chat_list.json.part').exists(), isFalse);
      tested++;
    }
    expect(tested, greaterThan(0));
  });

  test('a save racing a clear loses at every interleaving sampled', () async {
    final convs = [const Conversation(id: 'x', title: 'X')];
    final s = store();
    for (var turns = 0; turns < 40; turns++) {
      final saving = s.save('a', convs);
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future.wait([saving, s.clear()]);
      expect(
        await File('${root.path}/chat_list.json').exists(),
        isFalse,
        reason: 'clear() started $turns turns into a save lost to it',
      );
      expect(await File('${root.path}/chat_list.json.part').exists(), isFalse);
    }
    // And the store still works afterwards.
    await s.save('a', convs);
    expect(await s.load('a'), hasLength(1));
  });
}
