import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;
import 'package:sis/features/chat/data/video_source_prep.dart';
import 'package:sis/features/chat/domain/file_repository.dart';

class TempFiles implements DeviceFiles {
  TempFiles(this.root);
  final Directory root;
  final asked = <String>[];

  @override
  Future<String> pathFor(String messageId, String name) async {
    asked.add(messageId);
    return '${root.path}/videos/$messageId/$name';
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class CompressorFake implements lc.LightCompressor {
  CompressorFake(this.root, {this.info, this.infoThrows = false});
  final Directory root;
  lc.MediaInfo? info;
  bool infoThrows;
  final infoPaths = <String>[];
  int thumbs = 0;

  @override
  Future<lc.MediaInfo> getMediaInfo(String path) async {
    infoPaths.add(path);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (infoThrows) throw const lc.MediaInfoException();
    return info!;
  }

  @override
  Future<String> getVideoThumbnail(
    String path, {
    int positionInMs = 0,
    int quality = 50,
  }) async {
    thumbs++;
    final f = File('${root.path}/cache/shot$thumbs.jpg');
    await f.create(recursive: true);
    await f.writeAsBytes([0xFF, 0xD8, 1, 2]);
    return f.path;
  }

  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

Stream<List<int>> stream() => Stream.fromIterable([
  [1, 2, 3],
  [4, 5],
]);

void main() {
  late Directory root;
  late Directory videosDir;
  const name = 'Beach day.mov';
  final bytes = [1, 2, 3, 4, 5];

  setUp(() {
    root = Directory.systemTemp.createTempSync('prep');
    videosDir = Directory('${root.path}/videos');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('Readable 41s 1920x1080', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(seconds: 41),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    final source = result.source;
    final tooLong = result.tooLong;

    expect(source, isNotNull);
    expect(tooLong, isFalse);
    expect(source!.durationMs, equals(41000));
    expect(source.width, equals(1920));
    expect(source.height, equals(1080));
    expect(source.size, equals(5));
    expect(source.name, equals(name));
    expect(File(source.path).readAsBytesSync(), equals(bytes));
    expect(compressor.infoPaths.first, equals(source.path));
    expect(File(source.thumbPath).existsSync(), isTrue);
    expect(source.thumbPath, endsWith('thumb.jpg'));
    expect(source.path, contains('/videos/${source.id}/'));
    expect(source.thumbPath, contains('/videos/${source.id}/'));
    expect(videosDir.listSync().length, equals(1));
    expect(compressor.thumbs, equals(1));
  });

  test('Exactly 300000 ms allowed', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(milliseconds: 300000),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    expect(result.source, isNotNull);
    expect(result.tooLong, isFalse);
  });

  test('300001 ms too long', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(milliseconds: 300001),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    expect(result.source, isNull);
    expect(result.tooLong, isTrue);
    expect(videosDir.listSync().length, equals(0));
    expect(compressor.thumbs, equals(0));
  });

  test('MediaInfo duration null', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: null,
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    expect(result.source, isNull);
    expect(result.tooLong, isFalse);
    expect(videosDir.listSync().length, equals(0));
  });

  test('MediaInfo width null', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(seconds: 41),
        width: null,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    expect(result.source, isNull);
    expect(result.tooLong, isFalse);
    expect(videosDir.listSync().length, equals(0));
  });

  test('getMediaInfo throws', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      infoThrows: true,
      info: lc.MediaInfo(
        duration: const Duration(seconds: 41),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    expect(result.source, isNull);
    expect(result.tooLong, isFalse);
    expect(videosDir.listSync().length, equals(0));
  });

  test('Byte stream errors', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(seconds: 41),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final errorStream = Stream<List<int>>.error(FileSystemException('gone'));
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: errorStream,
    );
    expect(result.source, isNull);
    expect(result.tooLong, isFalse);
    expect(videosDir.listSync().length, equals(0));
  });

  test('Two calls get two different ids', () async {
    final files = TempFiles(root);
    final compressor = CompressorFake(
      root,
      info: lc.MediaInfo(
        duration: const Duration(seconds: 41),
        width: 1920,
        height: 1080,
        fileSize: 5,
      ),
    );
    final result1 = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    final result2 = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: name,
      bytes: stream(),
    );
    final source1 = result1.source!;
    final source2 = result2.source!;
    expect(source1.id, isNot(equals(source2.id)));
    expect(videosDir.listSync().length, equals(2));
    expect(source1.path, contains('/videos/${source1.id}/'));
    expect(source2.path, contains('/videos/${source2.id}/'));
  });
}
