import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/video.dart';

void main() {
  // Helper to compare two QueuedRecord instances deeply.
  void expectSame(QueuedRecord a, QueuedRecord b) {
    expect(a.id, equals(b.id));
    expect(a.conversationId, equals(b.conversationId));
    // The queue keeps milliseconds; a lost microsecond is not a change.
    expect(
      b.createdAt.millisecondsSinceEpoch,
      a.createdAt.millisecondsSinceEpoch,
    );
    expect(a.body, equals(b.body));
    expect(a.replyTo, equals(b.replyTo));

    // File comparison
    if (a.file == null) {
      expect(b.file, isNull);
    } else {
      expect(b.file, isNotNull);
      expect(a.file!.id, equals(b.file!.id));
      expect(a.file!.path, equals(b.file!.path));
      expect(a.file!.name, equals(b.file!.name));
      expect(a.file!.mime, equals(b.file!.mime));
      expect(a.file!.size, equals(b.file!.size));
      expect(a.file!.durationMs, equals(b.file!.durationMs));
      expect(a.file!.thumbPath, equals(b.file!.thumbPath));
    }

    // Video comparison
    if (a.video == null) {
      expect(b.video, isNull);
    } else {
      expect(b.video, isNotNull);
      expect(a.video!.id, equals(b.video!.id));
      expect(a.video!.path, equals(b.video!.path));
      expect(a.video!.name, equals(b.video!.name));
      expect(a.video!.size, equals(b.video!.size));
      expect(a.video!.durationMs, equals(b.video!.durationMs));
      expect(a.video!.width, equals(b.video!.width));
      expect(a.video!.height, equals(b.video!.height));
      expect(a.video!.thumbPath, equals(b.video!.thumbPath));
    }
  }

  group('encodeQueue / decodeQueue round trip', () {
    test('empty list', () {
      final records = <QueuedRecord>[];
      final json = encodeQueue(records);
      final decoded = decodeQueue(json);
      expect(decoded, isEmpty);
    });

    test('text record with replyTo', () {
      final record = QueuedRecord(
        id: '1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: 'Hello',
        replyTo: 'msg123',
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('text record with replyTo null', () {
      final record = QueuedRecord(
        id: '2',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: 'Hi',
        replyTo: null,
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('file record (pdf, no durationMs, no thumbPath)', () {
      final file = PickedFile(
        id: 'file1',
        path: '/path/to/file.pdf',
        name: 'file.pdf',
        mime: 'application/pdf',
        size: 12345,
      );
      final record = QueuedRecord(
        id: '3',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: '',
        file: file,
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('file record that is a shrunk video', () {
      final file = PickedFile(
        id: 'file2',
        path: '/path/to/video.mp4',
        name: 'video.mp4',
        mime: 'video/mp4',
        size: 67890,
        durationMs: 41000,
        thumbPath: '/thumb/path.jpg',
      );
      final record = QueuedRecord(
        id: '4',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: '',
        file: file,
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('video record', () {
      final video = VideoSource(
        id: 'vid1',
        path: '/path/to/video.mp4',
        name: 'video.mp4',
        size: 98765,
        durationMs: 41000,
        width: 1920,
        height: 1080,
        thumbPath: '/thumb/video.jpg',
      );
      final record = QueuedRecord(
        id: '5',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: '',
        video: video,
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('mixed list preserves order', () {
      final text = QueuedRecord(
        id: 't1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: 'Text',
      );
      final file = QueuedRecord(
        id: 'f1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: '',
        file: PickedFile(
          id: 'file',
          path: '/path',
          name: 'file.txt',
          mime: 'text/plain',
          size: 100,
        ),
      );
      final video = QueuedRecord(
        id: 'v1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: '',
        video: VideoSource(
          id: 'vid',
          path: '/path',
          name: 'vid.mp4',
          size: 200,
          durationMs: 5000,
          width: 640,
          height: 480,
          thumbPath: '/thumb',
        ),
      );
      final list = [text, file, video];
      final json = encodeQueue(list);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(3));
      expectSame(text, decoded[0]);
      expectSame(file, decoded[1]);
      expectSame(video, decoded[2]);
    });

    test('createdAt round trip with local and UTC times', () {
      final local = DateTime(2026, 10, 8, 0, 30); // local time
      final utc = DateTime.utc(2026, 10, 7, 15, 30); // same instant in UTC
      final recordLocal = QueuedRecord(
        id: 'l1',
        conversationId: 'conv',
        createdAt: local,
        body: 'Local',
      );
      final recordUtc = QueuedRecord(
        id: 'u1',
        conversationId: 'conv',
        createdAt: utc,
        body: 'UTC',
      );
      final json = encodeQueue([recordLocal, recordUtc]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(2));
      expectSame(recordLocal, decoded[0]);
      expectSame(recordUtc, decoded[1]);
      // Ensure they represent the same instant
      expect(
        decoded[0].createdAt.isAtSameMomentAs(decoded[1].createdAt),
        isTrue,
      );
    });

    test('body with unicode/emoji, quotes, and newlines', () {
      final body = 'Hello 🌟\n"World"';
      final record = QueuedRecord(
        id: 'u1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: body,
      );
      final json = encodeQueue([record]);
      final decoded = decodeQueue(json);
      expect(decoded, hasLength(1));
      expectSame(record, decoded.first);
    });

    test('encodeQueue output is valid JSON', () {
      final record = QueuedRecord(
        id: '1',
        conversationId: 'conv',
        createdAt: DateTime.now(),
        body: 'Test',
      );
      final json = encodeQueue([record]);
      final decodedJson = jsonDecode(json);
      expect(decodedJson, isA<List>());
      expect(decodedJson, hasLength(1));
    });
  });

  group('decodeQueue garbage handling', () {
    final garbageInputs = <String?>[
      null,
      '',
      'not json',
      '{}',
      '42',
      '[1,2]',
      '[{"id":3}]',
      '   ',
      '["invalid", {"id":"x"}]',
    ];

    for (final input in garbageInputs) {
      test('decodeQueue("$input") returns [] and does not throw', () {
        expect(() => decodeQueue(input), returnsNormally);
        final result = decodeQueue(input);
        expect(result, isEmpty);
      });
    }
  });
}
