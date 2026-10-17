import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/legacy_chat_list.dart';

void main() {
  test('deletes chat_list.json', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    addTearDown(() async => dir.delete(recursive: true));

    final file = File('${dir.path}/chat_list.json');
    await file.create();

    await deleteLegacyChatList(supportDir: () async => dir);

    expect(await file.exists(), isFalse);
  });

  test('deletes chat_list.json.part', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    addTearDown(() async => dir.delete(recursive: true));

    final file = File('${dir.path}/chat_list.json.part');
    await file.create();

    await deleteLegacyChatList(supportDir: () async => dir);

    expect(await file.exists(), isFalse);
  });

  test('does not delete other files', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    addTearDown(() async => dir.delete(recursive: true));

    final keep1 = File('${dir.path}/keep.txt');
    final keep2 = File('${dir.path}/sis_store.sqlite');
    await keep1.create();
    await keep2.create();

    await deleteLegacyChatList(supportDir: () async => dir);

    expect(await keep1.exists(), isTrue);
    expect(await keep2.exists(), isTrue);
  });

  test('completes when nothing present', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    addTearDown(() async => dir.delete(recursive: true));

    await expectLater(
      deleteLegacyChatList(supportDir: () async => dir),
      completes,
    );
  });

  test('completes when supportDir throws', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    addTearDown(() async => dir.delete(recursive: true));

    await expectLater(
      deleteLegacyChatList(
        supportDir: () async => throw const FileSystemException('no dir'),
      ),
      completes,
    );
  });

  test('completes when supportDir points to non-existent directory', () async {
    final dir = await Directory.systemTemp.createTemp('sis-legacy-');
    await dir.delete(); // ensure the directory does not exist
    addTearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    await expectLater(
      deleteLegacyChatList(supportDir: () async => dir),
      completes,
    );
  });

  group('push feed', () {
    late Directory dir;
    late File feed;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sis-legacy-');
      feed = File('${dir.path}/chat_list.json');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Map<String, Object?> entry({Object? lastMessage}) => {
      'id': 'c1',
      'name': 'Ada',
      'avatarUrl': 'https://img.sis.test/a.png',
      'lastMessage': lastMessage,
    };

    Future<bool> runOn(String content) async {
      await feed.writeAsString(content);
      await deleteLegacyChatList(supportDir: () async => dir);
      return feed.exists();
    }

    test('keeps a valid feed byte-identical', () async {
      final content = jsonEncode({
        'v': 1,
        'list': [entry(), entry()],
      });
      final before = utf8.encode(content);
      await feed.writeAsBytes(before);

      await deleteLegacyChatList(supportDir: () async => dir);

      expect(await feed.exists(), isTrue);
      expect(await feed.readAsBytes(), before);
    });

    test('keeps a valid feed with an empty list', () async {
      expect(await runOn(jsonEncode({'v': 1, 'list': <Object>[]})), isTrue);
    });

    test('keeps the feed but still deletes .part', () async {
      final part = File('${dir.path}/chat_list.json.part');
      await part.writeAsString('partial');

      final kept = await runOn(
        jsonEncode({
          'v': 1,
          'list': [entry()],
        }),
      );

      expect(kept, isTrue);
      expect(await part.exists(), isFalse);
    });

    test('deletes when v is missing', () async {
      expect(
        await runOn(
          jsonEncode({
            'list': [entry()],
          }),
        ),
        isFalse,
      );
    });

    test('deletes when v is wrong', () async {
      expect(
        await runOn(
          jsonEncode({
            'v': 2,
            'list': [entry()],
          }),
        ),
        isFalse,
      );
    });

    test('deletes when v is the string "1"', () async {
      expect(
        await runOn(
          jsonEncode({
            'v': '1',
            'list': [entry()],
          }),
        ),
        isFalse,
      );
    });

    test('deletes when any entry has message text', () async {
      expect(
        await runOn(
          jsonEncode({
            'v': 1,
            'list': [
              entry(),
              entry(lastMessage: {'text': 'secret hello'}),
            ],
          }),
        ),
        isFalse,
      );
    });

    test('deletes when an entry has a string lastMessage', () async {
      expect(
        await runOn(
          jsonEncode({
            'v': 1,
            'list': [entry(lastMessage: 'hello')],
          }),
        ),
        isFalse,
      );
    });

    test('deletes when an entry is not a Map', () async {
      expect(
        await runOn(
          jsonEncode({
            'v': 1,
            'list': ['secret hello'],
          }),
        ),
        isFalse,
      );
    });

    test('deletes the old format (no v, message text)', () async {
      expect(
        await runOn(
          jsonEncode([
            entry(lastMessage: {'text': 'hi'}),
          ]),
        ),
        isFalse,
      );
    });

    test('deletes garbage JSON', () async {
      expect(await runOn('{"v": 1, "list": [ not json'), isFalse);
    });

    test('deletes a JSON value that is not a Map', () async {
      expect(await runOn(jsonEncode([1, 2, 3])), isFalse);
      expect(await runOn(jsonEncode('v')), isFalse);
      expect(await runOn('null'), isFalse);
    });

    test('deletes when list is not a List', () async {
      expect(await runOn(jsonEncode({'v': 1, 'list': entry()})), isFalse);
      expect(await runOn(jsonEncode({'v': 1})), isFalse);
    });
  });
}
