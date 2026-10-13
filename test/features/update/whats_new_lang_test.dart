import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/domain/whats_new_note.dart';

void main() {
  group('isNewerVersion', () {
    test('compares dotted numeric parts correctly', () {
      expect(isNewerVersion('0.31', '0.30.17'), isTrue);
      expect(isNewerVersion('0.30.17', '0.31'), isFalse);
      expect(isNewerVersion('0.31', '0.31'), isFalse);
      expect(isNewerVersion('0.31', '0.31.0'), isFalse);
      expect(isNewerVersion('0.31.0', '0.31'), isFalse);
      expect(isNewerVersion('0.10', '0.9'), isTrue);
      expect(isNewerVersion('0.9', '0.10'), isFalse);
      expect(isNewerVersion('1.0', '0.99.99'), isTrue);
      expect(isNewerVersion('0.31.1', '0.31'), isTrue);
      expect(isNewerVersion('0.31', '0.31.1'), isFalse);
    });
  });

  group('parseWhatsNewNote', () {
    test('splits body on "---" and parses English part by default', () {
      const body =
          'Version 0.31\n- Chats load faster\n---\nSürüm 0.31\n- Sohbetler hızlı açılır';
      final note = parseWhatsNewNote(body);
      expect(note.text, equals(body));
      expect(note.version, equals('0.31'));
      expect(note.bullets, equals(['Chats load faster']));
    });

    test('splits body on "---" and parses Turkish part when lang is tr', () {
      const body =
          'Version 0.31\n- Chats load faster\n---\nSürüm 0.31\n- Sohbetler hızlı açılır';
      final note = parseWhatsNewNote(body, lang: 'tr');
      expect(note.text, equals(body));
      expect(note.version, equals('0.31'));
      expect(note.bullets, equals(['Sohbetler hızlı açılır']));
    });

    test('falls back to English when Turkish part is empty', () {
      const body = 'Version 0.31\n- A\n---\n   \n';
      final note = parseWhatsNewNote(body, lang: 'tr');
      expect(note.bullets, equals(['A']));
    });

    test('returns same result for en and tr when no separator is present', () {
      const body = 'Version 0.31\n- A\n- B';
      final enNote = parseWhatsNewNote(body, lang: 'en');
      final trNote = parseWhatsNewNote(body, lang: 'tr');
      expect(enNote.bullets, equals(['A', 'B']));
      expect(trNote.bullets, equals(['A', 'B']));
    });

    test('does not treat "----" or "a---b" as a separator', () {
      for (final sep in ['----', 'a---b']) {
        final body = 'Version 0.31\n- A\n$sep\nSürüm 0.31\n- B';
        final tr = parseWhatsNewNote(body, lang: 'tr');
        final en = parseWhatsNewNote(body);
        expect(tr.version, en.version, reason: sep);
        expect(tr.bullets, en.bullets, reason: sep);
        expect(en.bullets, contains('A'), reason: sep);
      }
    });

    test('a "---" line with spaces around it still splits', () {
      const body = 'Version 0.31\n- A\n  ---  \nSürüm 0.31\n- B';
      expect(parseWhatsNewNote(body, lang: 'tr').bullets, ['B']);
      expect(parseWhatsNewNote(body).bullets, ['A']);
    });

    test('extracts version from various accepted forms', () {
      const bodies = [
        '0.31\n- A',
        'v0.31\n- A',
        'Version 0.31\n- A',
        'sürüm 0.31\n- A',
        'Sürüm 0.31\n- A',
      ];
      for (final body in bodies) {
        final note = parseWhatsNewNote(body);
        expect(note.version, equals('0.31'), reason: 'body: $body');
      }
    });

    test('text property is always the original body', () {
      const body = 'Version 0.31\n- A\n---\nSürüm 0.31\n- B';
      final note = parseWhatsNewNote(body, lang: 'en');
      expect(note.text, equals(body));
    });
  });
}
