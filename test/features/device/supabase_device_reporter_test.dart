import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sis/features/device/data/supabase_device_reporter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // Recording HTTP
  final sent = <http.Request>[];
  int status = 204;
  final client = SupabaseClient(
    'http://supabase.test',
    'publishable-key',
    httpClient: MockClient((req) async {
      sent.add(req);
      return http.Response('', status, request: req);
    }),
  );

  // RPC requests have req.url.path == '/rest/v1/rpc/report_device_info'
  // and a JSON body: jsonDecode(req.body) as Map<String, Object?>.

  // Package info
  const ch = MethodChannel('sis/device_facts');

  setUp(() async {
    sent.clear();
    status = 204;
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          ch,
          (call) async => <String, String>{'model': 'Pixel 8', 'os': '14'},
        );
    PackageInfo.setMockInitialValues(
      appName: 'SIS',
      packageName: 'com.esd.sis',
      version: '0.31.0',
      buildNumber: '4711',
      buildSignature: '',
      installerStore: 'com.android.vending',
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  });

  test('1 sends one RPC request with correct body', () async {
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.length, 1);
    final body = jsonDecode(sent.first.body) as Map<String, Object?>;
    expect(body, {
      'p_model': 'Pixel 8',
      'p_os_version': '14',
      'p_app_version': '0.31.0',
      'p_build': 4711,
      'p_installer': 'com.android.vending',
    });
  });

  test('2 body keys set equals exactly the five names', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          ch,
          (call) async => <String, String>{
            'model': 'Pixel 8',
            'os': '14',
            'name': 'Erin phone',
            'id': 'abc123',
            'androidId': 'x1',
          },
        );
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.length, 1);
    final body = jsonDecode(sent.first.body) as Map<String, Object?>;
    expect(body.keys.toSet(), {
      'p_model',
      'p_os_version',
      'p_app_version',
      'p_build',
      'p_installer',
    });
    expect(body['p_model'], 'Pixel 8');
    expect(body['p_os_version'], '14');
    expect(body['p_app_version'], '0.31.0');
    expect(body['p_build'], 4711);
    expect(body['p_installer'], 'com.android.vending');
    final raw = sent.first.body;
    expect(raw, contains('"Pixel 8"'));
    expect(raw, contains('"14"'));
    expect(raw, contains('"0.31.0"'));
    expect(raw, contains('4711'));
    expect(raw, contains('"com.android.vending"'));
    expect(raw, isNot(contains('Erin phone')));
    expect(raw, isNot(contains('abc123')));
    expect(raw, isNot(contains('x1')));
  });

  test('3 installerStore null -> p_installer is empty string', () async {
    PackageInfo.setMockInitialValues(
      appName: 'SIS',
      packageName: 'com.esd.sis',
      version: '0.31.0',
      buildNumber: '4711',
      buildSignature: '',
      // installerStore omitted
    );
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.length, 1);
    final body = jsonDecode(sent.first.body) as Map<String, Object?>;
    expect(body['p_installer'], '');
  });

  test('4 channel handler removed (MissingPluginException)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.isEmpty, true);
  });

  test('5 channel handler throws PlatformException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
          throw PlatformException(code: 'boom');
        });
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.isEmpty, true);
  });

  test('6 channel answers null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async => null);
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.isEmpty, true);
  });

  test('7 buildNumber non-numeric', () async {
    PackageInfo.setMockInitialValues(
      appName: 'SIS',
      packageName: 'com.esd.sis',
      version: '0.31.0',
      buildNumber: 'abc',
      buildSignature: '',
      installerStore: 'com.android.vending',
    );
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.isEmpty, true);
  });

  test('8 server answers status 500', () async {
    status = 500;
    final reporter = SupabaseDeviceReporter(client);
    await expectLater(reporter.report(), completes);
    expect(sent.length, 1);
  });

  test('9 http client throws ClientException', () async {
    final badClient = SupabaseClient(
      'http://supabase.test',
      'publishable-key',
      httpClient: MockClient((req) async {
        throw http.ClientException('no network');
      }),
    );
    final reporter = SupabaseDeviceReporter(badClient);
    await expectLater(reporter.report(), completes);
    expect(sent.isEmpty, true);
  });
}
