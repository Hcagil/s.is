import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// What one timed action cost: wall-clock time, HTTP requests, response bytes.
class Timed {
  const Timed(this.d, this.requests, this.bytes);
  final Duration d;
  final int requests;
  final int bytes;
}

/// Passes every request to the real server, [delay] later: the phone-to-server
/// round trip a localhost run does not have. Counts requests and response
/// bytes.
class LatencyWire extends http.BaseClient {
  final _inner = http.Client();
  Duration delay = Duration.zero;
  int requests = 0;
  int bytes = 0;
  final log = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(delay);
    final res = await _inner.send(request);
    final body = await res.stream.toBytes();
    bytes += body.length;
    requests++;
    log.add('${request.method} ${request.url.pathSegments.last}');
    return http.StreamedResponse(
      Stream.value(body),
      res.statusCode,
      contentLength: body.length,
      request: res.request,
      headers: res.headers,
      isRedirect: res.isRedirect,
      persistentConnection: res.persistentConnection,
      reasonPhrase: res.reasonPhrase,
    );
  }

  void reset() {
    requests = 0;
    bytes = 0;
    log.clear();
  }

  @override
  void close() => _inner.close();
}

Future<Timed> timeIt(LatencyWire wire, Future<void> Function() action) async {
  wire.reset();
  final clock = Stopwatch()..start();
  await action();
  return Timed(clock.elapsed, wire.requests, wire.bytes);
}

class Samples {
  Samples(this.name);
  final String name;
  final List<int> micros = [];

  void add(Duration d) => micros.add(d.inMicroseconds);

  int get medianMs {
    final sorted = [...micros]..sort();
    return sorted[sorted.length ~/ 2] ~/ 1000;
  }

  int get minMs =>
      micros.isEmpty ? 0 : micros.reduce((a, b) => a < b ? a : b) ~/ 1000;

  int get maxMs =>
      micros.isEmpty ? 0 : micros.reduce((a, b) => a > b ? a : b) ~/ 1000;
}

/// One result line, `SPEED | what | median ... `, for the report to grep.
void report(String what, Samples s, {String extra = ''}) {
  stdout.writeln(
    'SPEED | $what | median ${s.medianMs} ms | min ${s.minMs} | '
    'max ${s.maxMs} | n ${s.micros.length}'
    '${extra.isEmpty ? '' : ' | $extra'}',
  );
}
