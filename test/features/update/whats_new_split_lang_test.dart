import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/domain/whats_new_note.dart';

void main() {
  group('parseWhatsNewNote language split', () {
    test('case 1: split between English and Turkish', () {
      const body = '''Version 2026.10.3 (216)
- Faster start
- New stickers
---
Version 2026.10.3 (216)
- Daha hızlı açılış
- Yeni çıkartmalar''';

      final enNote = parseWhatsNewNote(body, lang: 'en');
      expect(enNote.version, equals('2026.10.3'));
      expect(enNote.build, equals(216));
      expect(enNote.bullets, equals(['Faster start', 'New stickers']));

      final trNote = parseWhatsNewNote(body, lang: 'tr');
      expect(trNote.version, equals('2026.10.3'));
      expect(trNote.build, equals(216));
      expect(trNote.bullets, equals(['Daha hızlı açılış', 'Yeni çıkartmalar']));
    });

    test('case 2: default language (en)', () {
      const body = '''Version 2026.10.3 (216)
- Faster start
- New stickers
---
Version 2026.10.3 (216)
- Daha hızlı açılış
- Yeni çıkartmalar''';

      final note = parseWhatsNewNote(body);
      expect(note.version, equals('2026.10.3'));
      expect(note.build, equals(216));
      expect(note.bullets, equals(['Faster start', 'New stickers']));
    });

    test('case 3: unsupported language (de) falls back to English', () {
      const body = '''Version 2026.10.3 (216)
- Faster start
- New stickers
---
Version 2026.10.3 (216)
- Daha hızlı açılış
- Yeni çıkartmalar''';

      final note = parseWhatsNewNote(body, lang: 'de');
      expect(note.version, equals('2026.10.3'));
      expect(note.build, equals(216));
      expect(note.bullets, equals(['Faster start', 'New stickers']));
    });

    test('case 4: empty part 2, Turkish should use part 1', () {
      const body1 = '''Version 1.2
- One
---''';
      const body2 = '''Version 1.2
- One
---
   
''';

      final note1 = parseWhatsNewNote(body1, lang: 'tr');
      expect(note1.version, equals('1.2'));
      expect(note1.build, isNull);
      expect(note1.bullets, equals(['One']));

      final note2 = parseWhatsNewNote(body2, lang: 'tr');
      expect(note2.version, equals('1.2'));
      expect(note2.build, isNull);
      expect(note2.bullets, equals(['One']));
    });

    test('case 5: no split line, all languages identical', () {
      const body = '''Version 1.2
- One
- Two''';

      final enNote = parseWhatsNewNote(body, lang: 'en');
      final trNote = parseWhatsNewNote(body, lang: 'tr');

      expect(enNote.version, equals('1.2'));
      expect(enNote.build, isNull);
      expect(enNote.bullets, equals(['One', 'Two']));

      expect(trNote.version, equals('1.2'));
      expect(trNote.build, isNull);
      expect(trNote.bullets, equals(['One', 'Two']));
    });

    test('case 6: line "--- extra" or "----" is not a split', () {
      const body = '''Version 1.2
- One
----
- Two''';

      final note = parseWhatsNewNote(body, lang: 'en');
      // The line "----" is treated as a normal bullet after marker removal.
      expect(note.bullets, contains('Two'));
    });

    test('case 7: text is always the original body', () {
      const body = '''Version 2026.10.3 (216)
- Faster start
- New stickers
---
Version 2026.10.3 (216)
- Daha hızlı açılış
- Yeni çıkartmalar''';

      final enNote = parseWhatsNewNote(body, lang: 'en');
      final trNote = parseWhatsNewNote(body, lang: 'tr');

      expect(enNote.text, equals(body));
      expect(trNote.text, equals(body));
    });
  });
}
