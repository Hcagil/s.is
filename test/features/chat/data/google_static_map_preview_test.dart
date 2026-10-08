import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sis/features/chat/data/google_static_map_preview.dart';
import 'package:sis/features/chat/domain/geo.dart';

import '../../../support/fakes.dart';

base class _Recorder extends IOOverrides {
  final List<String> files = [];
  final List<String> dirs = [];

  @override
  File createFile(String path) {
    files.add(path);
    return super.createFile(path);
  }

  @override
  Directory createDirectory(String path) {
    dirs.add(path);
    return super.createDirectory(path);
  }
}

late List<http.Request> requests;
late http.Client client;

Future<void> show(WidgetTester t, GeoPoint p, {Key? key}) async {
  await t.runAsync(() async {
    await t.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 150,
          child: GoogleStaticMapPreview(
            key: key,
            point: p,
            apiKey: 'test-key',
            client: client,
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await t.pump();
}

void main() {
  setUp(() {
    requests = [];
    client = MockClient((r) async {
      requests.add(r);
      return http.Response.bytes(
        pngBytes,
        200,
        headers: {'content-type': 'image/png'},
      );
    });
  });

  testWidgets('asks Google Static Maps for the point', (t) async {
    final point = GeoPoint(10.1, 20.1);
    await show(t, point);
    expect(requests.length, 1);
    final url = requests[0].url;
    expect(url.host, 'maps.googleapis.com');
    expect(url.path, '/maps/api/staticmap');
    expect(url.queryParameters['key'], 'test-key');
    expect(url.toString(), contains('10.1'));
    expect(url.toString(), contains('20.1'));
  });

  testWidgets('shows the picture', (t) async {
    final point = GeoPoint(10.4, 20.4);
    await show(t, point);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('never writes the picture to disk', (t) async {
    final rec = _Recorder();
    IOOverrides.global = rec;
    addTearDown(() => IOOverrides.global = null);

    final point = GeoPoint(10.5, 20.5);
    await show(t, point);
    expect(rec.files, isEmpty);
    expect(rec.dirs, isEmpty);
    expect(requests.length, 1);
  });

  testWidgets('the same point is fetched once', (t) async {
    final point = GeoPoint(10.2, 20.2);
    await show(t, point, key: ValueKey('a'));
    await show(t, point, key: ValueKey('b'));
    expect(requests.length, 1);
  });

  testWidgets('a failed fetch shows no picture and does not throw', (t) async {
    final originalClient = client;
    client = MockClient((r) async {
      requests.add(r);
      return http.Response('denied', 403);
    });
    addTearDown(() => client = originalClient);

    final point = GeoPoint(10.3, 20.3);
    await show(t, point);
    expect(find.byType(Image), findsNothing);
    expect(t.takeException(), isNull);
  });
}
