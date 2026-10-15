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
}
