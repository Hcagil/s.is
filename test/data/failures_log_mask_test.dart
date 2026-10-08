@Tags(['vmservice'])
library;

import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:sis/data/failures.dart';
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service.dart';
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service_io.dart';

late VmService svc;
final records = <LogRecord>[];

Future<void> _waitForLog() async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

void _expectAtLeastOneRecordWithMessageContaining(String substring) {
  expect(
    records.any((r) => r.message!.valueAsString!.contains(substring)),
    isTrue,
    reason: 'At least one log record should contain "$substring"',
  );
}

void _expectNoRecordWithMessageContaining(String substring) {
  expect(
    records.any((r) => r.message!.valueAsString!.contains(substring)),
    isFalse,
    reason: 'No log record should contain "$substring"',
  );
}

void _expectAllRecordsHaveNoError() {
  expect(
    records.every(
      (r) => r.error == null || r.error!.kind == InstanceKind.kNull,
    ),
    isTrue,
    reason: 'All log records should have no error object',
  );
}

void main() {
  setUpAll(() async {
    final uri = (await Service.getInfo()).serverWebSocketUri;
    if (uri == null) fail('run with flutter test --enable-vmservice');
    svc = await vmServiceConnectUri(uri.toString());
    svc.onLoggingEvent.listen((e) => records.add(e.logRecord!));
    await svc.streamListen(EventStreams.kLogging);
  });

  tearDownAll(() => svc.dispose());
  setUp(records.clear);

  test('ClientException with key is masked', () async {
    readableFailure(
      ClientException(
        'Failed host lookup',
        Uri.parse(
          'https://maps.googleapis.com/maps/api/geocode/json?address=x&key=AIzaSECRET123',
        ),
      ),
    );
    await _waitForLog();

    expect(
      records.isNotEmpty,
      isTrue,
      reason: 'Should produce at least one log record',
    );
    _expectNoRecordWithMessageContaining('AIzaSECRET123');
    _expectAtLeastOneRecordWithMessageContaining('key=<hidden>');
    _expectAllRecordsHaveNoError();
  });

  test('Exception with key and size is masked', () async {
    readableFailure(
      Exception('GET https://x.test/staticmap?key=SECRET99&size=2x2 failed'),
    );
    await _waitForLog();

    expect(
      records.isNotEmpty,
      isTrue,
      reason: 'Should produce at least one log record',
    );
    _expectNoRecordWithMessageContaining('SECRET99');
    _expectAtLeastOneRecordWithMessageContaining('key=<hidden>&size=2x2');
    _expectAllRecordsHaveNoError();
  });

  test('Plain exception is logged unchanged', () async {
    readableFailure(Exception('plain failure without secrets'));
    await _waitForLog();

    expect(
      records.isNotEmpty,
      isTrue,
      reason: 'Should produce at least one log record',
    );
    _expectAtLeastOneRecordWithMessageContaining(
      'plain failure without secrets',
    );
    _expectAllRecordsHaveNoError();
  });
}
