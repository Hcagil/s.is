// The client the app uses to read link cards must connect only to an address
// it resolved and checked itself (M2: no private targets, no DNS rebinding).
//
// Hermetic part: every check that ends in a refusal. The injected lookup
// answers a private address while a real server listens on it, so a client
// that ignored the check would reach it.
//
// Pinning part: a public answer has to be connected to. A test cannot own a
// public address on a normal machine, and the client refuses every private
// one, so these tests run only where the machine has a non-private interface
// address. Recipe (a Docker network on an unused public range):
//   docker network create --subnet 11.99.0.0/24 qa-pin
//   docker compose run -d --name qa-pin-flutter flutter sleep infinity
//   docker network connect --ip 11.99.0.10 qa-pin qa-pin-flutter
//   docker exec qa-pin-flutter flutter test <this file>
// Elsewhere they are skipped with that reason, never passed silently.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/http_link_preview_fetcher.dart';

bool _special(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        b[0] == 127 ||
        b[0] == 0 ||
        b[0] >= 224 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
        (b[0] == 192 && b[1] == 0) ||
        (b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51)) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113);
  }
  return true; // keep it simple: only a public IPv4 counts
}

Future<InternetAddress?> _publicInterface() async {
  for (final i in await NetworkInterface.list()) {
    for (final a in i.addresses) {
      if (!_special(a)) return a;
    }
  }
  return null;
}

/// The SNI host name in a TLS ClientHello, or null if it carries none.
String? _sni(List<int> b) {
  try {
    var p = 5 + 4 + 2 + 32; // record + handshake headers, version, random
    p += 1 + b[p]; // session id
    p += 2 + (b[p] << 8 | b[p + 1]); // cipher suites
    p += 1 + b[p]; // compression methods
    final end = p + 2 + (b[p] << 8 | b[p + 1]);
    p += 2;
    while (p + 4 <= end) {
      final type = b[p] << 8 | b[p + 1];
      final len = b[p + 2] << 8 | b[p + 3];
      if (type == 0) {
        final nameLen = b[p + 7] << 8 | b[p + 8];
        return String.fromCharCodes(b.sublist(p + 9, p + 9 + nameLen));
      }
      p += 4 + len;
    }
  } on RangeError {
    return null;
  }
  return null;
}

void main() {
  late HttpServer local;
  late int hits;
  late List<String> asked;

  setUp(() async {
    hits = 0;
    asked = [];
    local = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    local.listen((r) {
      hits++;
      r.response
        ..write('<meta property="og:title" content="reached">')
        ..close();
    });
  });

  tearDown(() => local.close(force: true));

  Future<List<InternetAddress>> Function(String) answering(
    FutureOr<List<InternetAddress>> Function(String host) answer,
  ) => (host) async {
    asked.add(host);
    return answer(host);
  };

  group('refuses before connecting (hermetic)', () {
    test('a name answering a loopback address where a server listens is '
        'refused, and the server is never reached', () async {
      final client = linkPreviewHttpClient(
        lookup: answering((_) => [InternetAddress.loopbackIPv4]),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://pin.example:${local.port}/')),
        throwsA(anything),
      );
      expect(asked, ['pin.example'], reason: 'the injected lookup is used');
      expect(hits, 0);
    });

    test('a NAT64 address carrying loopback is refused', () async {
      final client = linkPreviewHttpClient(
        lookup: answering((_) => [InternetAddress('64:ff9b::7f00:1')]),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://pin.example:${local.port}/')),
        throwsA(anything),
      );
      expect(hits, 0);
    });

    test('a failed lookup is refused', () async {
      final client = linkPreviewHttpClient(
        lookup: answering((_) => throw const SocketException('no such host')),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${local.port}/')),
        throwsA(anything),
      );
      expect(asked, ['127.0.0.1']);
      expect(hits, 0);
    });

    test('an empty lookup is refused', () async {
      final client = linkPreviewHttpClient(lookup: answering((_) => []));
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://pin.example:${local.port}/')),
        throwsA(anything),
      );
      expect(hits, 0);
    });

    test('a lookup that never answers is refused within about 3 s', () async {
      final client = linkPreviewHttpClient(
        lookup: answering((_) => Completer<List<InternetAddress>>().future),
      );
      addTearDown(client.close);
      final watch = Stopwatch()..start();
      await expectLater(
        client.get(Uri.parse('http://pin.example:${local.port}/')),
        throwsA(anything),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 4500)));
      expect(hits, 0);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('connects to the checked address (needs a public interface)', () {
    InternetAddress? public;
    setUpAll(() async => public = await _publicInterface());
    String? skipReason() => public == null
        ? 'no non-private interface address here; see the recipe at the top'
        : null;

    test('the request goes to the address the lookup gave, whatever the URL '
        'host says', () async {
      if (skipReason() case final r?) return markTestSkipped(r);
      final server = await HttpServer.bind(public!, 0);
      final hosts = <String?>[];
      server.listen((r) {
        hosts.add(r.headers.host);
        r.response
          ..write('pinned')
          ..close();
      });
      addTearDown(() => server.close(force: true));
      final client = linkPreviewHttpClient(lookup: answering((_) => [public!]));
      addTearDown(client.close);

      final res = await client.get(
        Uri.parse('http://nowhere.invalid:${server.port}/'),
      );
      expect(res.body, 'pinned');
      expect(hosts, ['nowhere.invalid'], reason: 'Host header is unchanged');
      expect(asked, ['nowhere.invalid']);
    });

    test('https names the original host to the server (SNI)', () async {
      if (skipReason() case final r?) return markTestSkipped(r);
      final server = await ServerSocket.bind(public!, 0);
      final hello = Completer<List<int>>();
      server.listen((s) {
        final got = <int>[];
        s.listen(
          (d) {
            got.addAll(d);
            if (got.length > 200 && !hello.isCompleted) {
              hello.complete(got);
              s.destroy();
            }
          },
          onError: (_) {},
          onDone: () {
            if (!hello.isCompleted) hello.complete(got);
          },
        );
      });
      addTearDown(server.close);
      final client = linkPreviewHttpClient(lookup: answering((_) => [public!]));
      addTearDown(client.close);

      unawaited(
        client
            .get(Uri.parse('https://pin.example:${server.port}/'))
            .then((_) {}, onError: (_) {}),
      );
      final bytes = await hello.future.timeout(const Duration(seconds: 5));
      expect(bytes.first, 22, reason: 'a TLS handshake, not plain HTTP');
      expect(_sni(bytes), 'pin.example');
    });

    test(
      'https to a server whose certificate is for another name fails',
      () async {
        if (skipReason() case final r?) return markTestSkipped(r);
        final dir = await Directory.systemTemp.createTemp('pin');
        addTearDown(() => dir.delete(recursive: true));
        final made = await Process.run('openssl', [
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', //
          '-subj', '/CN=other.example',
          '-addext', 'subjectAltName=DNS:other.example',
          '-keyout', '${dir.path}/k.pem', '-out', '${dir.path}/c.pem',
        ]);
        expect(made.exitCode, 0, reason: '${made.stderr}');
        final ctx = SecurityContext()
          ..useCertificateChain('${dir.path}/c.pem')
          ..usePrivateKey('${dir.path}/k.pem');
        final server = await HttpServer.bindSecure(public!, 0, ctx);
        var served = 0;
        server.listen((r) {
          served++;
          r.response
            ..write('tls')
            ..close();
        }, onError: (_) {});
        addTearDown(() => server.close(force: true));
        final client = linkPreviewHttpClient(
          lookup: answering((_) => [public!]),
        );
        addTearDown(client.close);

        await expectLater(
          client.get(Uri.parse('https://pin.example:${server.port}/')),
          throwsA(anything),
        );
        expect(served, 0);
      },
    );
  });
}
