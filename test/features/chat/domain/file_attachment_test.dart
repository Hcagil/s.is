import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';

void main() {
  group('maxFileBytes', () {
    test('value is 50 MiB', () {
      expect(maxFileBytes, 50 * 1024 * 1024);
    });
  });

  group('isFileTooBig', () {
    final max = maxFileBytes;
    test('0 bytes is not too big', () {
      expect(isFileTooBig(0), isFalse);
    });
    test('maxFileBytes - 1 is not too big', () {
      expect(isFileTooBig(max - 1), isFalse);
    });
    test('maxFileBytes is not too big', () {
      expect(isFileTooBig(max), isFalse);
    });
    test('maxFileBytes + 1 is too big', () {
      expect(isFileTooBig(max + 1), isTrue);
    });
    test('60 MiB is too big', () {
      expect(isFileTooBig(60 * 1024 * 1024), isTrue);
    });
  });

  group('filePreview', () {
    test('returns paperclip and name', () {
      expect(filePreview('Cabin booking.pdf'), '\u{1F4CE} Cabin booking.pdf');
    });
  });

  group('fileTypeLabel', () {
    test('returns correct extension', () {
      expect(fileTypeLabel('Cabin booking.pdf'), 'PDF');
      expect(fileTypeLabel('Menu.xlsx'), 'XLSX');
      expect(fileTypeLabel('a.b.tar.gz'), 'GZ');
      expect(fileTypeLabel('photo.JPG'), 'JPG');
    });
  });

  group('fileSizeLabel', () {
    final labelRe = RegExp(r'^(\d+(?:[.,]\d+)?) (KB|MB)$');

    /// Parses a label like "84 KB" or "2,4 MB" into a numeric value in bytes.
    int? bytesFromLabel(String label) {
      final m = labelRe.firstMatch(label);
      if (m == null) return null;
      final numStr = m.group(1)!.replaceAll(',', '.');
      final unit = m.group(2)!;
      final number = double.parse(numStr);
      final multiplier = unit == 'KB' ? 1024 : 1024 * 1024;
      return (number * multiplier).round();
    }

    bool within10Percent(int bytes, int labelBytes) {
      final tolerance = (bytes * 0.1).round();
      return (labelBytes - bytes).abs() <= tolerance;
    }

    test('matches regex and tolerance for various sizes', () {
      final cases = [
        86016, // ~84 KB
        2516582, // ~2.4 MB
        18874368, // ~18 MB
      ];
      for (final bytes in cases) {
        final label = fileSizeLabel(bytes);
        expect(
          labelRe.hasMatch(label),
          isTrue,
          reason: 'Label "$label" does not match regex',
        );
        final labelBytes = bytesFromLabel(label);
        expect(
          labelBytes,
          isNotNull,
          reason: 'Could not parse bytes from label "$label"',
        );
        expect(
          within10Percent(bytes, labelBytes!),
          isTrue,
          reason:
              'Label "$label" ($labelBytes bytes) not within 10% of $bytes bytes',
        );
      }
      expect(fileSizeLabel(86016), endsWith(' KB'));
      expect(fileSizeLabel(2516582), endsWith(' MB'));
      expect(fileSizeLabel(2516582), matches(RegExp(r'^\d+[.,]\d MB$')));
      expect(fileSizeLabel(18874368), endsWith(' MB'));
      // Ensure 2516582 and 18874368 produce different labels
      expect(fileSizeLabel(2516582), isNot(equals(fileSizeLabel(18874368))));
    });
  });

  group('safeFileName', () {
    final inputs = [
      'report.pdf',
      '../../etc/passwd',
      '..\\..\\win.ini',
      'a/b/c.txt',
      'C:\\x\\y.doc',
      '..',
      '.',
      '',
    ];
    test('returns a safe name for various inputs', () {
      for (final input in inputs) {
        final result = safeFileName(input);
        expect(
          result.contains('/'),
          isFalse,
          reason: 'Result "$result" contains "/"',
        );
        expect(
          result.contains('\\'),
          isFalse,
          reason: 'Result "$result" contains "\\"',
        );
        expect(result, isNot(equals('..')), reason: 'Result "$result" is ".."');
        expect(result, isNot(equals('.')), reason: 'Result "$result" is "."');
        expect(
          result.isNotEmpty,
          isTrue,
          reason: 'Result for "$input" is empty',
        );
        expect(
          result.startsWith('..'),
          isFalse,
          reason: 'Result "$result" starts with ".."',
        );
      }
      expect(safeFileName('report.pdf'), equals('report.pdf'));
    });

    test('drops invisible and direction-changing characters', () {
      final hidden = [
        for (var c = 0x200B; c <= 0x200F; c++) c,
        for (var c = 0x202A; c <= 0x202E; c++) c,
        for (var c = 0x2066; c <= 0x2069; c++) c,
      ];
      for (final c in hidden) {
        final name = 'invoice${String.fromCharCode(c)}fdp.exe';
        final result = safeFileName(name);
        expect(
          result.runes.where(hidden.contains),
          isEmpty,
          reason: 'U+${c.toRadixString(16)} kept',
        );
        expect(result, startsWith('invoice'));
        expect(result, endsWith('fdp.exe'));
      }
    });
  });

  group('previewText', () {
    test('returns file preview when file attached', () {
      final attached = AttachedFile(
        name: 'Menu.xlsx',
        mime:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        size: 86016,
      );
      final msg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: '',
        createdAt: DateTime.now(),
        file: attached,
      );
      expect(previewText(msg), '\u{1F4CE} Menu.xlsx');
    });
  });

  group('canEdit', () {
    test('allows edit when no file attached', () {
      final now = DateTime.now();
      final msg = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'hi',
        createdAt: now.subtract(const Duration(minutes: 1)),
        file: null,
      );
      expect(msg.canEdit('u1', now), isTrue);
    });

    test('disallows edit when file attached and body empty', () {
      final now = DateTime.now();
      final msg = Message(
        id: 'm2',
        conversationId: 'c1',
        senderId: 'u1',
        body: '',
        createdAt: now.subtract(const Duration(minutes: 1)),
        file: AttachedFile(name: 'file.txt', mime: 'text/plain', size: 100),
      );
      expect(msg.canEdit('u1', now), isFalse);
    });

    test('disallows edit when file attached and body has caption', () {
      final now = DateTime.now();
      final msg = Message(
        id: 'm3',
        conversationId: 'c1',
        senderId: 'u1',
        body: 'caption',
        createdAt: now.subtract(const Duration(minutes: 1)),
        file: AttachedFile(name: 'file.txt', mime: 'text/plain', size: 100),
      );
      expect(msg.canEdit('u1', now), isFalse);
    });
  });

  group('FilePick defaults', () {
    test('files empty and tooBig 0', () {
      final fp = FilePick();
      expect(fp.files, isEmpty);
      expect(fp.tooBig, equals(0));
    });
  });
}
