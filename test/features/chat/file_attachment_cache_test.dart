// FileAttachmentCache, written from the AttachmentCache contract in
// lib/features/chat/domain/attachment.dart, and from the crash it must
// survive: a write that never finished must never be handed back as a photo.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/file_attachment_cache.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment-cache-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileAttachmentCache cache() => FileAttachmentCache(root: () async => root);

  test('reading a path never written returns null', () async {
    expect(await cache().read('c1/never.png'), isNull);
  });

  test(
    'a write is read back byte for byte, including a "/" in the path',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final c = cache();

      await c.write('c1/sub/photo.png', bytes);
      final got = await c.read('c1/sub/photo.png');

      expect(got, bytes);
    },
  );

  test('two different paths do not collide', () async {
    final c = cache();
    await c.write('c1/a.png', Uint8List.fromList([1]));
    await c.write('c1/b.png', Uint8List.fromList([2]));

    expect(await c.read('c1/a.png'), [1]);
    expect(await c.read('c1/b.png'), [2]);
  });

  test('clear() removes everything', () async {
    final c = cache();
    await c.write('c1/a.png', Uint8List.fromList([1]));
    await c.write('c2/b.png', Uint8List.fromList([2]));

    await c.clear();

    expect(await c.read('c1/a.png'), isNull);
    expect(await c.read('c2/b.png'), isNull);
  });

  test('clear() on an empty (or never-used) cache does not throw', () async {
    await cache().clear();
  });

  test('a leftover ".part" file from an interrupted write is never returned '
      'as a photo', () async {
    final c = cache();
    final full = Uint8List.fromList([9, 9, 9]);
    await c.write('c1/photo.png', full);

    // Find the single file this write actually produced, then simulate a
    // crash between the temporary write and its rename: the finished file
    // is gone, only its ".part" sibling is left, exactly as a write that
    // never completed would leave the directory.
    final written = await root
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    expect(written, hasLength(1));
    final target = written.single;
    await target.rename('${target.path}.part');

    expect(
      await c.read('c1/photo.png'),
      isNull,
      reason: 'a half-written file must not be handed back as a photo',
    );
  });

  test('writing again after an interrupted write recovers cleanly', () async {
    final c = cache();
    await c.write('c1/photo.png', Uint8List.fromList([1]));
    final written = await root
        .list(recursive: true)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    await written.single.rename('${written.single.path}.part');
    expect(await c.read('c1/photo.png'), isNull);

    final retried = Uint8List.fromList([7, 7, 7]);
    await c.write('c1/photo.png', retried);

    expect(await c.read('c1/photo.png'), retried);
  });
}
