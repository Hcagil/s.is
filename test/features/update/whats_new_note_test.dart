import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/domain/whats_new_note.dart';

void main() {
  test(
    'first non‑empty line is parsed as version (0.31, v0.31, Version 0.31)',
    () {
      final cases = [
        '0.31\n- a\n- b',
        'v0.31\n- a\n- b',
        'Version 0.31\n- a\n- b',
      ];
      for (final body in cases) {
        final note = parseWhatsNewNote(body);
        expect(note.isStructured, isTrue);
        expect(note.version, equals('0.31'));
        expect(note.bullets, equals(['a', 'b']));
        expect(note.text, equals(body));
      }
    },
  );

  test('bullet markers are stripped only once and text is trimmed', () {
    final body = '''
0.31
- a
* b
• c
– d
- - x
-   y
- x
''';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isTrue);
    expect(note.version, equals('0.31'));
    expect(note.bullets, equals(['a', 'b', 'c', 'd', '- x', 'y', 'x']));
    expect(note.text, equals(body));
  });

  test('no version line results in a plain note', () {
    final body = '- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.version, isNull);
    expect(note.bullets, isEmpty);
    expect(note.text, equals(body));
  });

  test('no bullets results in a plain note', () {
    final body = '0.31';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.text, equals(body));
  });

  test('text is always the original body unchanged', () {
    final body = '0.31\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.text, equals(body));
  });

  test('empty string is a plain note with empty text', () {
    final body = '';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.version, isNull);
    expect(note.bullets, isEmpty);
    expect(note.text, equals(body));
  });

  test('whitespace‑only input is a plain note with unchanged text', () {
    final body = '  \n \n';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.version, isNull);
    expect(note.bullets, isEmpty);
    expect(note.text, equals(body));
  });

  test('CRLF line endings are handled correctly', () {
    final body = '0.31\r\n- a\r\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isTrue);
    expect(note.version, equals('0.31'));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.text, equals(body));
  });

  test('first line that is just a number is not treated as a version', () {
    final cases = ['Fixed 3 bugs\n- a', 'We shipped 0.31 today\n- a'];
    for (final body in cases) {
      final note = parseWhatsNewNote(body);
      expect(note.isStructured, isFalse);
      expect(note.version, isNull);
      expect(note.bullets, isEmpty);
      expect(note.text, equals(body));
    }
  });

  test('empty lines between bullets and leading blanks are skipped', () {
    final body = '''
\n\n0.31\n\n- a\n\n- b\n\n''';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isTrue);
    expect(note.version, equals('0.31'));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.text, equals(body));
  });

  test('only bullets with leading blanks are a plain note', () {
    final body = '''
\n\n- a\n- b''';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.version, isNull);
    expect(note.bullets, isEmpty);
    expect(note.text, equals(body));
  });

  test('version line but no bullets results in a plain note', () {
    final body = '0.31\n';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isFalse);
    expect(note.text, equals(body));
  });

  test('never throws, never drops: odd inputs come back as notes', () {
    for (final body in [
      '\r',
      '\r\n\r\n',
      'v',
      'Version',
      '-',
      '•\n–',
      '0.31\n-\n*',
      'v0.31.\n- a',
      '\u0000',
    ]) {
      final note = parseWhatsNewNote(body);
      expect(note.text, body);
      if (note.isStructured) expect(note.bullets, isNotEmpty);
    }
  });

  test('a structured note keeps its exact original body as text', () {
    const body = '  Version 0.31  \r\n\r\n•  one \r\n';
    final note = parseWhatsNewNote(body);
    expect(note.isStructured, isTrue);
    expect(note.version, '0.31');
    expect(note.bullets, ['one']);
    expect(note.text, body);
  });
}
