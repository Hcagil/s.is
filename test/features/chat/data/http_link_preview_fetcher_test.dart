// HttpLinkPreviewFetcher against a fake web: an http.Client that answers like
// real sites do, including the inconvenient parts (a page that never answers,
// an endless body, redirect chains, a connection that drops).
//
// Tests named TARGET encode the security fix list (M2: no private targets,
// every hop checked, no https->http downgrade; L4: cancel on timeout).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sis/features/chat/data/http_link_preview_fetcher.dart';

/// One site: answers by full URL; anything else is a 404.
class _Web extends http.BaseClient {
  final routes = <String, FutureOr<http.StreamedResponse> Function()>{};
  final asked = <Uri>[];

  void page(String url, String html, {int status = 200}) => routes[url] = () =>
      http.StreamedResponse(
        Stream.value(utf8.encode(html)),
        status,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

  void redirect(String from, String to, {int status = 302}) =>
      routes[from] = () => http.StreamedResponse(
        const Stream.empty(),
        status,
        headers: {'location': to},
        isRedirect: true,
      );

  void bytes(String url, Uint8List data, {String type = 'image/jpeg'}) =>
      routes[url] = () => http.StreamedResponse(
        Stream.value(data),
        200,
        contentLength: data.length,
        headers: {'content-type': type},
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    asked.add(request.url);
    final route = routes[request.url.toString()];
    if (route == null) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    return route();
  }
}

/// A resolver that answers like the system one, without a network: an IP
/// literal answers itself, a name in [records] its addresses, any other name
/// one public address. [answer] replaces the whole behaviour when set.
class _Dns {
  final records = <String, List<InternetAddress>>{
    'localhost': [InternetAddress('127.0.0.1'), InternetAddress('::1')],
  };
  final asked = <String>[];
  Future<List<InternetAddress>> Function(String host)? answer;

  Future<List<InternetAddress>> call(String host) async {
    asked.add(host);
    if (answer case final a?) return a(host);
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];
    return records[host] ?? [InternetAddress('93.184.215.14')];
  }
}

String _og({
  String title = 'A page',
  String? image,
  String? description,
  String? site,
}) =>
    '<html><head><meta property="og:title" content="$title">'
    '${description == null ? '' : '<meta property="og:description" content="$description">'}'
    '${site == null ? '' : '<meta property="og:site_name" content="$site">'}'
    '${image == null ? '' : '<meta property="og:image" content="$image">'}'
    '</head><body>hi</body></html>';

final _jpeg = Uint8List.fromList(List.generate(1000, (i) => i % 256));
final _shrunk = Uint8List.fromList([1, 2, 3]);

void main() {
  late _Web web;
  late _Dns dns;
  late List<Uint8List> shrinkCalls;

  HttpLinkPreviewFetcher fetcher({Duration? timeout}) => HttpLinkPreviewFetcher(
    web,
    shrink: (bytes) async {
      shrinkCalls.add(bytes);
      return _shrunk;
    },
    timeout: timeout ?? const Duration(seconds: 6),
    lookup: dns.call,
  );

  setUp(() {
    web = _Web();
    dns = _Dns();
    shrinkCalls = [];
  });

  test(
    'a page with Open Graph data becomes a draft with the shrunk picture',
    () async {
      web.page(
        'https://example.com/a',
        _og(title: 'Hello', description: 'Desc', site: 'Ex', image: '/p.jpg'),
      );
      web.bytes('https://example.com/p.jpg', _jpeg);

      final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));

      expect(draft, isNotNull);
      expect(draft!.preview.url, Uri.parse('https://example.com/a'));
      expect(draft.preview.title, 'Hello');
      expect(draft.preview.description, 'Desc');
      expect(draft.preview.site, 'Ex');
      expect(draft.preview.video, isFalse);
      expect(
        draft.preview.imagePath,
        isNull,
        reason: 'the queue sets the path',
      );
      expect(
        shrinkCalls.single,
        _jpeg,
        reason: 'the downloaded bytes are shrunk',
      );
      expect(draft.image, _shrunk);
    },
  );

  test('a page without a picture gives a card without one', () async {
    web.page('https://example.com/a', _og());
    final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
    expect(draft!.image, isNull);
    expect(shrinkCalls, isEmpty);
  });

  test('a picture that cannot be shrunk gives a card without one', () async {
    web.page('https://example.com/a', _og(image: 'https://example.com/p.jpg'));
    web.bytes('https://example.com/p.jpg', _jpeg);
    final draft = await HttpLinkPreviewFetcher(
      web,
      shrink: (_) async => null,
      lookup: dns.call,
    ).fetch(Uri.parse('https://example.com/a'));
    expect(draft!.preview.title, 'A page');
    expect(draft.image, isNull);
  });

  test('a missing picture (404) gives a card without one', () async {
    web.page(
      'https://example.com/a',
      _og(image: 'https://example.com/gone.jpg'),
    );
    final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
    expect(draft!.preview.title, 'A page');
    expect(draft.image, isNull);
  });

  test('a page without a title gives no card', () async {
    web.page('https://example.com/a', '<html><body>no head</body></html>');
    expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
  });

  test('a video host gets the video flag', () async {
    web.page('https://www.youtube.com/watch?v=abc', _og(title: 'Clip'));
    final draft = await fetcher().fetch(
      Uri.parse('https://www.youtube.com/watch?v=abc'),
    );
    expect(draft!.preview.video, isTrue);
  });

  group('never throws', () {
    test('a dropped connection gives null', () async {
      web.routes['https://example.com/a'] = () =>
          throw const SocketException('connection reset');
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
    });

    test('a client bug (StateError) gives null', () async {
      web.routes['https://example.com/a'] = () => throw StateError('boom');
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
    });

    test(
      'a body that errors half-way gives null or a card, never a throw',
      () async {
        Stream<List<int>> half() async* {
          yield utf8.encode('<title>Half');
          throw const HttpException('reset');
        }

        web.routes['https://example.com/a'] = () =>
            http.StreamedResponse(half(), 200);
        await expectLater(
          fetcher().fetch(Uri.parse('https://example.com/a')),
          completes,
        );
      },
    );

    test('a shrink that throws gives a card without the picture', () async {
      web.page(
        'https://example.com/a',
        _og(image: 'https://example.com/p.jpg'),
      );
      web.bytes('https://example.com/p.jpg', _jpeg);
      final draft = await HttpLinkPreviewFetcher(
        web,
        shrink: (_) async => throw const FormatException('bad jpeg'),
        lookup: dns.call,
      ).fetch(Uri.parse('https://example.com/a'));
      expect(draft?.image, isNull);
    });

    test('a server error gives null', () async {
      web.page('https://example.com/a', _og(), status: 500);
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
    });

    test('a non-http scheme gives null without asking anyone', () async {
      for (final u in [
        'ftp://example.com/a',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(await fetcher().fetch(Uri.parse(u)), isNull, reason: u);
      }
      expect(web.asked, isEmpty);
    });
  });

  group('timeout', () {
    test('a page that never answers gives null within the timeout', () async {
      web.routes['https://example.com/a'] = () =>
          Completer<http.StreamedResponse>().future;
      final watch = Stopwatch()..start();
      final draft = await fetcher(timeout: const Duration(milliseconds: 300))
          .fetch(Uri.parse('https://example.com/a'));
      expect(draft, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('the default timeout is 6 seconds', () {
      expect(
        HttpLinkPreviewFetcher(web, lookup: dns.call).timeout,
        const Duration(seconds: 6),
      );
    });

    test('TARGET L4: a body that stalls is abandoned at the timeout and its stream cancelled', () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      body.add(utf8.encode('<html><head><title>Slow'));
      web.routes['https://example.com/a'] = () =>
          http.StreamedResponse(body.stream, 200);
      final watch = Stopwatch()..start();
      await fetcher(timeout: const Duration(milliseconds: 300))
          .fetch(Uri.parse('https://example.com/a'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cancelled, isTrue, reason: 'TARGET L4: cancel on timeout');
    });

    test(
      'a picture that never answers still gives the card, without it',
      () async {
        web.page(
          'https://example.com/a',
          _og(image: 'https://example.com/p.jpg'),
        );
        web.routes['https://example.com/p.jpg'] = () =>
            Completer<http.StreamedResponse>().future;
        final watch = Stopwatch()..start();
        final draft = await fetcher(timeout: const Duration(milliseconds: 300))
            .fetch(Uri.parse('https://example.com/a'));
        expect(draft?.preview.title, 'A page');
        expect(draft?.image, isNull);
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      },
    );
  });

  group('caps', () {
    test('an endless page is read only to 300000 bytes', () async {
      var sent = 0;
      final head = utf8.encode(
        '<html><head><title>Endless</title></head><body>',
      );
      Stream<List<int>> endless() async* {
        sent += head.length;
        yield head;
        final chunk = List.filled(16384, 0x61);
        while (true) {
          sent += chunk.length;
          yield chunk;
          if (sent > 50000000) throw StateError('read far past the cap');
        }
      }

      web.routes['https://example.com/a'] = () =>
          http.StreamedResponse(endless(), 200);
      final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
      expect(draft?.preview.title, 'Endless');
      expect(sent, lessThanOrEqualTo(300000 + 2 * 16384));
    });

    test('a picture over 3000000 bytes is never shrunk', () async {
      web.page(
        'https://example.com/a',
        _og(image: 'https://example.com/big.jpg'),
      );
      web.bytes('https://example.com/big.jpg', Uint8List(3000001));
      final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
      expect(draft?.preview.title, 'A page');
      expect(draft?.image, isNull);
      expect(shrinkCalls, isEmpty);
    });

    test('a picture of exactly 3000000 bytes is shrunk', () async {
      web.page(
        'https://example.com/a',
        _og(image: 'https://example.com/ok.jpg'),
      );
      web.bytes('https://example.com/ok.jpg', Uint8List(3000000));
      final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
      expect(shrinkCalls.single.length, 3000000);
      expect(draft!.image, _shrunk);
    });

    test(
      'a picture over the cap with no content-length is cut off, not buffered',
      () async {
        var sent = 0;
        Stream<List<int>> endless() async* {
          final chunk = List.filled(65536, 1);
          while (true) {
            sent += chunk.length;
            yield chunk;
            if (sent > 50000000) throw StateError('read far past the cap');
          }
        }

        web.page(
          'https://example.com/a',
          _og(image: 'https://example.com/big.jpg'),
        );
        web.routes['https://example.com/big.jpg'] = () =>
            http.StreamedResponse(endless(), 200);
        final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
        expect(draft?.image, isNull);
        expect(shrinkCalls, isEmpty);
        expect(sent, lessThanOrEqualTo(3000000 + 2 * 65536));
      },
    );
  });

  group(
    'TARGET M2: redirects followed hop by hop by the fetcher, at most 5',
    () {
      void chain(int hops) {
        for (var i = 0; i < hops; i++) {
          web.redirect(
            'https://example.com/r$i',
            'https://example.com/r${i + 1}',
          );
        }
        web.page('https://example.com/r$hops', _og(title: 'End'));
      }

      test(
        '5 redirects are followed; the card keeps the link that was typed',
        () async {
          chain(5);
          final draft = await fetcher().fetch(
            Uri.parse('https://example.com/r0'),
          );
          expect(draft?.preview.title, 'End');
          expect(draft?.preview.url, Uri.parse('https://example.com/r0'));
        },
      );

      test('6 redirects give null', () async {
        chain(6);
        expect(
          await fetcher().fetch(Uri.parse('https://example.com/r0')),
          isNull,
        );
        expect(web.asked.length, lessThanOrEqualTo(6));
      });

      test('a redirect loop ends', () async {
        web.redirect('https://example.com/a', 'https://example.com/b');
        web.redirect('https://example.com/b', 'https://example.com/a');
        expect(
          await fetcher().fetch(Uri.parse('https://example.com/a')),
          isNull,
        );
      });

      test('a relative Location is resolved against the hop', () async {
        web.redirect('https://example.com/a', '/b');
        web.page('https://example.com/b', _og(title: 'B'));
        final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
        expect(draft?.preview.title, 'B');
      });
    },
  );

  group('TARGET M2: no private targets, every hop checked', () {
    for (final u in [
      'http://127.0.0.1/',
      'http://localhost/',
      'http://[::1]/',
      'http://10.0.0.1/',
      'http://172.16.0.1/',
      'http://192.168.1.1/',
      'http://169.254.169.254/latest/meta-data/',
      'http://100.64.0.1/',
      'http://[fd00::1]/',
      'http://[fe80::1]/',
      'http://0.0.0.0/',
    ]) {
      test('refuses $u without asking it', () async {
        web.page(u, _og(title: 'Internal'));
        expect(await fetcher().fetch(Uri.parse(u)), isNull);
        expect(web.asked, isEmpty);
      });
    }

    test('a redirect to a private address is not followed', () async {
      web.redirect('https://example.com/a', 'http://169.254.169.254/latest/');
      web.page('http://169.254.169.254/latest/', _og(title: 'Metadata'));
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
      expect(web.asked.map((u) => u.host), isNot(contains('169.254.169.254')));
    });

    test('an og:image on a private address is not downloaded', () async {
      web.page('https://example.com/a', _og(image: 'http://10.0.0.5/p.jpg'));
      web.bytes('http://10.0.0.5/p.jpg', _jpeg);
      final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
      expect(draft?.image, isNull);
      expect(web.asked.map((u) => u.host), isNot(contains('10.0.0.5')));
    });

    test('an https page redirecting to http is not followed', () async {
      web.redirect('https://example.com/a', 'http://example.com/a');
      web.page('http://example.com/a', _og(title: 'Plain'));
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
    });
  });

  group('name resolution fails closed (M2)', () {
    test('a lookup that fails refuses the link without asking it', () async {
      web.page('https://example.com/a', _og());
      dns.answer = (_) async => throw const SocketException('no such host');
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
      expect(web.asked, isEmpty);
    });

    test('an empty lookup refuses the link without asking it', () async {
      web.page('https://example.com/a', _og());
      dns.answer = (_) async => [];
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
      expect(web.asked, isEmpty);
    });

    test('a lookup that never answers refuses the link within about 3 s, '
        'long before the page timeout', () async {
      web.page('https://example.com/a', _og());
      dns.answer = (_) => Completer<List<InternetAddress>>().future;
      final watch = Stopwatch()..start();
      final draft = await fetcher(timeout: const Duration(seconds: 30))
          .fetch(Uri.parse('https://example.com/a'));
      expect(draft, isNull);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 4500)));
      expect(web.asked, isEmpty);
    });

    test(
      'a public name that resolves to a private address is refused',
      () async {
        dns.records['intranet.example.com'] = [InternetAddress('10.1.2.3')];
        web.page('https://intranet.example.com/', _og(title: 'Internal'));
        expect(
          await fetcher().fetch(Uri.parse('https://intranet.example.com/')),
          isNull,
        );
        expect(dns.asked, contains('intranet.example.com'));
        expect(web.asked, isEmpty);
      },
    );

    test('one private address among public ones is enough to refuse', () async {
      dns.records['mixed.example.com'] = [
        InternetAddress('93.184.215.14'),
        InternetAddress('127.0.0.1'),
      ];
      web.page('https://mixed.example.com/', _og());
      expect(
        await fetcher().fetch(Uri.parse('https://mixed.example.com/')),
        isNull,
      );
      expect(web.asked, isEmpty);
    });

    test('a redirect to a name resolving privately is not followed', () async {
      dns.records['inside.example.net'] = [InternetAddress('192.168.0.9')];
      web.redirect('https://example.com/a', 'https://inside.example.net/x');
      web.page('https://inside.example.net/x', _og(title: 'Inside'));
      expect(await fetcher().fetch(Uri.parse('https://example.com/a')), isNull);
      expect(
        web.asked.map((u) => u.host),
        isNot(contains('inside.example.net')),
      );
    });

    test(
      'an og:image on a name resolving privately is not downloaded',
      () async {
        dns.records['img.example.net'] = [InternetAddress('fd00::7')];
        web.page(
          'https://example.com/a',
          _og(image: 'https://img.example.net/p.jpg'),
        );
        web.bytes('https://img.example.net/p.jpg', _jpeg);
        final draft = await fetcher().fetch(Uri.parse('https://example.com/a'));
        expect(draft?.preview.title, 'A page', reason: 'the card itself stays');
        expect(draft?.image, isNull);
        expect(
          web.asked.map((u) => u.host),
          isNot(contains('img.example.net')),
        );
      },
    );

    test(
      'a public name resolving publicly is read (the control case)',
      () async {
        dns.records['ok.example.org'] = [InternetAddress('2606:4700::1')];
        web.page('https://ok.example.org/', _og(title: 'Fine'));
        final draft = await fetcher().fetch(
          Uri.parse('https://ok.example.org/'),
        );
        expect(draft?.preview.title, 'Fine');
      },
    );
  });

  group('NAT64 and 6to4 are judged by the IPv4 address they carry', () {
    for (final (addr, carried, private) in [
      ('64:ff9b::a00:1', '10.0.0.1', true),
      ('64:ff9b::7f00:1', '127.0.0.1', true),
      ('64:ff9b::a9fe:a9fe', '169.254.169.254', true),
      ('64:ff9b::808:808', '8.8.8.8', false),
      ('2002:a00:1::1', '10.0.0.1', true),
      ('2002:c0a8:101::1', '192.168.1.1', true),
      ('2002:808:808::1', '8.8.8.8', false),
    ]) {
      test(
        '$addr (carries $carried) is ${private ? 'refused' : 'read'}',
        () async {
          dns.records['wrapped.example.com'] = [InternetAddress(addr)];
          web.page('https://wrapped.example.com/', _og(title: 'W'));
          final draft = await fetcher().fetch(
            Uri.parse('https://wrapped.example.com/'),
          );
          if (private) {
            expect(draft, isNull);
            expect(web.asked, isEmpty);
          } else {
            expect(draft?.preview.title, 'W');
          }
        },
      );
    }
  });

  group('the whole fetch is capped at 9 s', () {
    test('a long page timeout still ends the fetch by 9 s', () async {
      Future<http.StreamedResponse> slow(http.StreamedResponse r) =>
          Future.delayed(const Duration(milliseconds: 2500), () => r);
      for (var i = 0; i < 4; i++) {
        web.routes['https://example.com/$i'] = () => slow(
          http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': 'https://example.com/${i + 1}'},
            isRedirect: true,
          ),
        );
      }
      web.routes['https://example.com/4'] = () => slow(
        http.StreamedResponse(
          Stream.value(utf8.encode(_og(title: 'Late'))),
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      final watch = Stopwatch()..start();
      final draft = await fetcher(timeout: const Duration(seconds: 20))
          .fetch(Uri.parse('https://example.com/0'));
      expect(draft, isNull, reason: 'the page would come at 12.5 s');
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 10000)));
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 8000)));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('link-card lows (step 11b)', () {
    for (final addr in ['::7f00:1', '::a00:1', '::808:808']) {
      test('an IPv4-compatible address ($addr, first 12 bytes zero) is '
          'refused', () async {
        dns.records['compat.example.com'] = [InternetAddress(addr)];
        web.page('https://compat.example.com/', _og(title: 'C'));
        expect(
          await fetcher().fetch(Uri.parse('https://compat.example.com/')),
          isNull,
        );
        expect(web.asked, isEmpty);
      });
    }

    test('an IPv4-compatible literal is refused without asking it', () async {
      web.page('http://[::7f00:1]/', _og(title: 'C'));
      expect(await fetcher().fetch(Uri.parse('http://[::7f00:1]/')), isNull);
      expect(web.asked, isEmpty);
    });

    test('an IDN host is looked up as punycode and gets a card', () async {
      final link = Uri.parse('https://bücher.example/a');
      for (final u in ['https://xn--bcher-kva.example/a', link.toString()]) {
        web.page(u, _og(title: 'Books'));
      }
      final draft = await fetcher().fetch(link);
      expect(dns.asked, contains('xn--bcher-kva.example'));
      expect(
        dns.asked.where((h) => h.contains('%') || h.contains('ü')),
        isEmpty,
      );
      expect(draft?.preview.title, 'Books');
    });
  });
}
