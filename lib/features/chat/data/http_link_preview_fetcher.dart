import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../domain/link_page.dart';
import '../domain/link_preview.dart';
import '../domain/link_preview_fetcher.dart';

/// Reads web pages and extracts link previews from them.
final class HttpLinkPreviewFetcher implements LinkPreviewFetcher {
  HttpLinkPreviewFetcher(
    this._client, {
    Future<Uint8List?> Function(Uint8List bytes)? shrink,
    this.timeout = const Duration(seconds: 6),
    Future<List<InternetAddress>> Function(String host)? lookup,
  }) : _shrink = shrink ?? ((_) async => null),
       _lookup = lookup ?? InternetAddress.lookup;

  final http.Client _client;
  final Future<Uint8List?> Function(Uint8List bytes) _shrink;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Longest wait for the page; the picture gets half of it on its own, and
  /// the whole fetch is capped at 9 seconds.
  final Duration timeout;

  @override
  Future<LinkPreviewDraft?> fetch(Uri url) async {
    try {
      return await _fetch(url).timeout(const Duration(seconds: 9));
    } catch (_) {
      return null;
    }
  }

  Future<LinkPreviewDraft?> _fetch(Uri url) async {
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    if (url.host.isEmpty) return null;
    final page = await _read(
      url,
      maxBytes: 300000,
      accept: 'text/html,application/xhtml+xml',
      truncate: true,
      type: 'html',
      budget: timeout,
    );
    if (page == null) return null;
    final html = utf8.decode(page, allowMalformed: true);
    final info = parseLinkPage(url, html);
    if (info == null) return null;

    Uint8List? jpeg;
    if (info.image != null) {
      try {
        final raw = await _read(
          info.image!,
          maxBytes: 3000000,
          accept: 'image/*',
          truncate: false,
          type: 'image/',
          budget: Duration(microseconds: timeout.inMicroseconds ~/ 2),
        );
        if (raw != null) jpeg = await _shrink(raw);
      } catch (_) {
        // A picture that fails or stalls never costs the card.
      }
    }

    return LinkPreviewDraft(
      preview: LinkPreview(
        url: url,
        title: info.title,
        description: info.description,
        site: info.site,
        video: isVideoHost(url),
      ),
      image: jpeg,
    );
  }

  /// Reads [uri] (following up to 5 redirects by hand, checking every hop)
  /// with a max of [maxBytes] inside [budget]; returns the bytes or null.
  Future<Uint8List?> _read(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required bool truncate,
    required String type,
    required Duration budget,
  }) async {
    final sw = Stopwatch()..start();
    for (var hop = 0; hop < 6; hop++) {
      if (!await _allowed(uri)) return null;
      Duration remaining() {
        final left = budget - sw.elapsed;
        if (left <= Duration.zero) throw TimeoutException('timeout', budget);
        return left;
      }

      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36 SISLinkPreview';
      request.headers['Accept'] = accept;
      request.headers['Accept-Language'] = 'en,tr;q=0.8';
      request.followRedirects = false;

      final response = await _client.send(request).timeout(remaining());

      if (response.statusCode >= 300 && response.statusCode <= 399) {
        final location = response.headers['location'];
        if (location == null) return null;
        unawaited(response.stream.listen(null).cancel());
        final next = uri.resolve(location);
        if (hop == 5) return null;
        if (uri.scheme == 'https' && next.scheme != 'https') return null;
        uri = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode > 299) return null;

      final contentType = response.headers['content-type'];
      final ok = contentType == null ? truncate : contentType.contains(type);
      if (!ok) {
        unawaited(response.stream.listen(null).cancel());
        return null;
      }

      final bytes = BytesBuilder(copy: false);
      var total = 0;
      final it = StreamIterator(response.stream);
      try {
        while (await it.moveNext().timeout(remaining())) {
          final chunk = it.current;
          if (total + chunk.length > maxBytes) {
            if (!truncate) return null;
            bytes.add(chunk.sublist(0, maxBytes - total));
            break;
          }
          bytes.add(chunk);
          total += chunk.length;
          if (total >= maxBytes) break;
        }
      } finally {
        // Also runs on timeout: a stalled body is cancelled, not left open.
        await it.cancel();
      }
      return bytes.toBytes();
    }
    return null;
  }

  Future<bool> _allowed(Uri u) async {
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    final host = displayHost(u);
    if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
      return false;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return !_private(ip);
    return await _publicAddresses(_lookup, host) != null;
  }
}

/// Loopback, private, link-local, CGNAT, ULA, multicast, documentation and
/// other special ranges.
bool _private(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length == 4) {
    if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
    if (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) return true;
    if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return true;
    if (b[0] == 198 && b[1] == 51 && b[2] == 100) return true;
    if (b[0] == 203 && b[1] == 0 && b[2] == 113) return true;
    return false;
  }
  if (b.length != 16) return true;
  // NAT64 and 6to4 carry an IPv4 address: judge that one.
  if (b[0] == 0 &&
      b[1] == 0x64 &&
      b[2] == 0xff &&
      b[3] == 0x9b &&
      b.sublist(4, 12).every((x) => x == 0)) {
    return _private(
      InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
    );
  }
  if (b[0] == 0x20 && b[1] == 0x02) {
    return _private(
      InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(2, 6))),
    );
  }
  // ::, ::1 and the old IPv4-compatible form ::a.b.c.d.
  if (b.sublist(0, 12).every((x) => x == 0)) return true;
  if ((b[0] & 0xfe) == 0xfc) return true;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
  if (b[0] == 0xff) return true;
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
    return true;
  }
  if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) {
    return _private(
      InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
    );
  }
  return false;
}

/// Resolves [host] and returns its addresses only if every one is public;
/// null on a failed, empty or timed-out lookup or any special address.
Future<List<InternetAddress>?> _publicAddresses(
  Future<List<InternetAddress>> Function(String host) lookup,
  String host,
) async {
  try {
    final list = await lookup(host).timeout(const Duration(seconds: 3));
    return list.isEmpty || list.any(_private) ? null : list;
  } catch (_) {
    return null;
  }
}

/// The client the app uses for link cards. It connects only to an address it
/// resolved and checked itself, so a DNS answer that changes between the
/// check and the connection cannot redirect it; for https the certificate is
/// checked against the original host name.
http.Client linkPreviewHttpClient({
  Future<List<InternetAddress>> Function(String host)? lookup,
}) {
  final look = lookup ?? InternetAddress.lookup;
  final inner = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (url, proxyHost, proxyPort) async {
      final host = displayHost(url);
      final addresses = await _publicAddresses(look, host);
      if (addresses == null) {
        throw const SocketException('link target is not a public address');
      }
      final secure = url.scheme == 'https';
      // HttpClient adds no TLS to a custom connection: _connectAny does it.
      return ConnectionTask.fromSocket(
        _connectAny(
          addresses,
          url.hasPort ? url.port : (secure ? 443 : 80),
          secure ? host : null,
        ),
        () {},
      );
    };
  return IOClient(inner);
}

/// Connects to the first address that answers (3 s each); for https it then
/// does the TLS handshake for [tlsHost] within 5 s, so a silent server cannot
/// hold the connection open.
Future<Socket> _connectAny(
  List<InternetAddress> addresses,
  int port,
  String? tlsHost,
) async {
  Object? last;
  for (final a in addresses) {
    try {
      final s = await Socket.connect(
        a,
        port,
        timeout: const Duration(seconds: 3),
      );
      if (tlsHost == null) return s;
      try {
        return await SecureSocket.secure(
          s,
          host: tlsHost,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        s.destroy();
        rethrow;
      }
    } catch (e) {
      last = e;
    }
  }
  throw last ?? const SocketException('no address');
}
