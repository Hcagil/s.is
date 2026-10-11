import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/link_preview.dart';

void main() {
  group('displayHost', () {
    test('converts IDN to punycode and lowercases', () {
      expect(
        displayHost(Uri.parse('https://bücher.de/x')),
        equals('xn--bcher-kva.de'),
      );
      expect(
        displayHost(Uri.parse('https://münchen.de')),
        equals('xn--mnchen-3ya.de'),
      );
      expect(
        displayHost(Uri.parse('https://例え.テスト')),
        equals('xn--r8jz45g.xn--zckzah'),
      );
    });

    test('converts Cyrillic lookalike to punycode', () {
      // First letter is Cyrillic a (U+0430)
      expect(
        displayHost(Uri.parse('https://\u0430pple.com')),
        equals('xn--pple-43d.com'),
      );
    });

    test('keeps mixed ASCII and IDN labels', () {
      expect(
        displayHost(Uri.parse('https://www.bücher.de')),
        equals('www.xn--bcher-kva.de'),
      );
    });

    test('lowercases plain ASCII hosts', () {
      expect(
        displayHost(Uri.parse('https://Example.COM/path')),
        equals('example.com'),
      );
    });

    test('does not modify subdomains with only ASCII', () {
      expect(
        displayHost(Uri.parse('https://sub.example.co.uk')),
        equals('sub.example.co.uk'),
      );
    });
  });

  group('displayHost RFC 3492 / IDNA vectors', () {
    test('RFC 3492 (A-sample) simplified Chinese label', () {
      expect(
        displayHost(Uri.parse('https://他们为什么不说中文.com')),
        'xn--ihqwcrb4cv8a8dqg056pqjye.com',
      );
    });

    test('RFC 3492 (J) Russian label', () {
      expect(
        displayHost(Uri.parse('https://почемужеонинеговорятпорусски.ru')),
        'xn--b1abfaaepdrnnbgefbadotcwatmq2g4l.ru',
      );
    });

    test('upper-case IDN is lowercased before encoding', () {
      expect(displayHost(Uri.parse('https://BÜCHER.de')), 'xn--bcher-kva.de');
    });

    test('mixed-script lookalike: Latin with one Cyrillic o', () {
      // "gооgle" with two U+043E Cyrillic o's.
      final host = displayHost(Uri.parse('https://g\u043e\u043egle.com'));
      expect(host, startsWith('xn--'));
      expect(host, isNot('google.com'));
      expect(host, endsWith('.com'));
      expect(host.codeUnits.every((c) => c < 128), isTrue);
    });

    test('an already-encoded xn-- host is left as is', () {
      expect(
        displayHost(Uri.parse('https://xn--bcher-kva.de/a')),
        'xn--bcher-kva.de',
      );
    });

    test('output is always ASCII', () {
      for (final u in [
        'https://bücher.de',
        'https://例え.テスト',
        'https://ex\u0430mple.com',
        'https://😀.example',
      ]) {
        expect(
          displayHost(Uri.parse(u)).codeUnits.every((c) => c < 128),
          isTrue,
          reason: u,
        );
      }
    });
  });

  group('shortLink', () {
    test('shows host and root path, no scheme, <= 40 chars', () {
      final result = shortLink(Uri.parse('https://example.com/'));
      expect(result.startsWith('example.com'), isTrue);
      expect(result.length, lessThanOrEqualTo(40));
    });

    test('truncates long paths after host, <= 40 chars', () {
      final result = shortLink(
        Uri.parse(
          'https://example.com/articles/2026/10/a-very-long-slug-that-goes-on-and-on',
        ),
      );
      expect(result.startsWith('example.com/articles'), isTrue);
      expect(result.length, lessThanOrEqualTo(40));
    });

    test('shows punycode host for IDN URLs', () {
      final result = shortLink(Uri.parse('https://bücher.de/a'));
      expect(result.startsWith('xn--bcher-kva.de'), isTrue);
    });

    test('keeps short paths fully', () {
      expect(
        shortLink(Uri.parse('https://example.com/a/b')),
        equals('example.com/a/b'),
      );
    });
  });

  group('isVideoHost', () {
    test('identifies known video hosts', () {
      expect(isVideoHost(Uri.parse('https://youtube.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://www.youtube.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://m.youtube.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://youtu.be')), isTrue);
      expect(isVideoHost(Uri.parse('https://instagram.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://www.tiktok.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://x.com')), isTrue);
      expect(isVideoHost(Uri.parse('https://twitter.com')), isTrue);
      // Case-insensitive
      expect(isVideoHost(Uri.parse('https://YOUTUBE.com/watch')), isTrue);
    });

    test('rejects non-video hosts and lookalikes', () {
      expect(isVideoHost(Uri.parse('https://notyoutube.com')), isFalse);
      expect(isVideoHost(Uri.parse('https://youtube.com.evil.net')), isFalse);
      expect(isVideoHost(Uri.parse('https://vimeo.com/1')), isFalse);
    });
  });

  group('linkImagePath', () {
    test('returns correct path format', () {
      expect(linkImagePath('c1', 'm1'), equals('c1/m1.jpg'));
    });
  });

  group('LinkPreview JSON (what the server stores, read back)', () {
    final card = LinkPreview(
      url: Uri.parse('https://example.com/a'),
      title: 'T',
      description: 'D',
      site: 'S',
      imagePath: 'c1/m1.jpg',
      video: true,
    );

    test('a card survives the round trip', () {
      final back = LinkPreview.fromJson(card.toJson())!;
      expect(back.url, card.url);
      expect(back.title, 'T');
      expect(back.description, 'D');
      expect(back.site, 'S');
      expect(back.imagePath, 'c1/m1.jpg');
      expect(back.video, isTrue);
    });

    test('no card, or a card that is not an object, reads as none', () {
      expect(LinkPreview.fromJson(null), isNull);
      expect(LinkPreview.fromJson('https://example.com'), isNull);
    });

    test('a card a reader must not trust reads as none', () {
      Map<String, Object?> with_(Map<String, Object?> patch) =>
          {...card.toJson(), ...patch};
      expect(LinkPreview.fromJson(with_({'url': 'javascript:alert(1)'})), isNull);
      expect(LinkPreview.fromJson(with_({'url': 'file:///etc/passwd'})), isNull);
      expect(LinkPreview.fromJson(with_({'title': ''})), isNull);
      expect(
        LinkPreview.fromJson(with_({'title': 'x' * (LinkPreview.maxTitle + 1)})),
        isNull,
      );
      expect(
        LinkPreview.fromJson(
          with_({'description': 'x' * (LinkPreview.maxDescription + 1)}),
        ),
        isNull,
      );
      expect(
        LinkPreview.fromJson(with_({'site': 'x' * (LinkPreview.maxSite + 1)})),
        isNull,
      );
      expect(LinkPreview.fromJson(with_({'video': 'yes'})), isNull);
    });
  });
}
