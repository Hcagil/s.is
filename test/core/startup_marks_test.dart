// StartupMarks, slice 1 contract: a mark logs the label and the ms since
// start, nothing else (no personal data). "Every build" (not only debug)
// cannot be seen from a debug-mode test; see the QA report.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/startup_marks.dart';

void main() {
  late List<String> lines;
  late DebugPrintCallback oldDebugPrint;

  setUp(() {
    lines = [];
    oldDebugPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) lines.add(m);
    };
  });

  tearDown(() {
    debugPrint = oldDebugPrint;
  });

  test('mark logs one line with label and ms', () async {
    runZoned(
      () => StartupMarks.mark('qa-label-1'),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    expect(lines.length, 1);
    final line = lines.first;
    expect(line, contains('qa-label-1'));
    expect(line, matches(RegExp(r'\+\d+ms')));
  });

  test('line contains only label and time', () async {
    runZoned(
      () => StartupMarks.mark('qa-label-2'),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    final line = lines.first;
    final cleaned = line
        .replaceAll('sis.startup', '')
        .replaceAll('qa-label-2', '')
        .replaceAll(RegExp(r'\+\d+ms'), '')
        .trim();
    expect(cleaned, isEmpty);
  });

  test('second mark ms >= first ms + 20', () async {
    runZoned(
      () => StartupMarks.mark('qa-label-3'),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    final firstLine = lines.first;
    final firstMs = int.parse(
      RegExp(r'\+(\d+)ms').firstMatch(firstLine)!.group(1)!,
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));

    lines.clear();
    runZoned(
      () => StartupMarks.mark('qa-label-4'),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    final secondLine = lines.first;
    final secondMs = int.parse(
      RegExp(r'\+(\d+)ms').firstMatch(secondLine)!.group(1)!,
    );
    expect(secondMs, greaterThanOrEqualTo(firstMs + 20));
  });
}
