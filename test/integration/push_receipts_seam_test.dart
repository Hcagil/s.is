@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/data/push_receipt_log.dart';
import 'package:sis/features/notifications/data/supabase_push_receipts.dart';
import 'package:sis/features/notifications/data/supabase_push_registry.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/push_platform.dart';

/// Push receipts, from the phone's buffer to the server, as main.dart
/// mounts them: PushRegistration starting over the production
/// [SupabaseAuthRepository], [SupabasePushRegistry] and
/// [SupabasePushReceipts] on one signed-in client. Only Firebase (no
/// Firebase locally) and the phone's preferences file are stood in for.
///
/// What the server answered is read off the wire: report_push_receipts
/// returns how many rows it stored for the caller. The pgTAP suite
/// (supabase/tests/push_receipts_test.sql) proves those rows are always the
/// caller's; this suite proves the app reaches that RPC with the right name
/// and parameter, as a member the server lets through, and that the buffer
/// empties only by what the server took.
///
/// Requires `docker compose run --rm supabase start`. Uses its own seeded
/// account (supabase/seed.sql): pax. Run with --concurrency=1, as CI does.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const _email = 'pax@integration.test';

/// Every answer report_push_receipts gave, as sent over the wire.
class _Wire extends http.BaseClient {
  final _inner = http.Client();
  final answers = <({int status, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _inner.send(request);
    if (!request.url.path.endsWith('/rpc/report_push_receipts')) return res;
    final bytes = await res.stream.toBytes();
    answers.add((status: res.statusCode, body: utf8.decode(bytes)));
    return http.StreamedResponse(
      Stream.value(bytes),
      res.statusCode,
      headers: res.headers,
      request: res.request,
      reasonPhrase: res.reasonPhrase,
    );
  }
}

Future<SupabaseClient> _signedIn(_Wire wire) async {
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: wire,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: _email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: _email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  return client;
}

class _SignedInAuth implements AuthRepository {
  _SignedInAuth(SupabaseClient client)
    : real = SupabaseAuthRepository(
        client,
        GoogleSignIn.instance,
        googleWebClientId: 'unused-locally',
      );
  final SupabaseAuthRepository real;

  @override
  Future<Result<void>> signInWithGoogle() async =>
      const Err(ProviderFailure('no Google locally'));
  @override
  bool get hasSession => real.hasSession;
  @override
  Stream<bool> get signedInChanges => real.signedInChanges;
  @override
  Future<Result<bool>> activateSession() => real.activateSession();
  @override
  Future<Result<Member>> currentMember() => real.currentMember();
  @override
  Future<void> signOut() => real.signOut();
  @override
  String? get userId => real.userId;
  @override
  String? get sessionId => real.sessionId;
}

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const prefs = MethodChannel('plugins.flutter.io/shared_preferences');
  late DiskPrefs disk;

  setUp(() {
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(prefs, disk.handle);
    SharedPreferences.resetStatic();
  });
  tearDown(() => messenger.setMockMethodCallHandler(prefs, null));

  Future<List<Map<String, Object?>>> pending() async {
    SharedPreferences.resetStatic();
    return PushReceiptLog.pending();
  }

  /// The phone collected [n] receipts while the app was closed.
  Future<void> collected(int n) async {
    for (var i = 0; i < n; i++) {
      await PushReceiptLog.add(i.isEven ? 'received' : 'shown');
    }
    expect(await pending(), hasLength(n), reason: 'precondition');
  }

  /// The app starts on [client], wired as main.dart wires it.
  ProviderContainer start(SupabaseClient client, {SupabaseClient? receipts}) {
    final c = ProviderContainer.test(
      overrides: [
        runtimeConfigProvider.overrideWithValue(
          const RuntimeConfig(
            supabaseUrl: _url,
            supabasePublishableKey: _key,
            googleWebClientId: 'unused-locally',
          ),
        ),
        authRepositoryProvider.overrideWithValue(_SignedInAuth(client)),
        pushSourceProvider.overrideWithValue(
          PushSourceFake(token: 'itest-receipts-${client.hashCode}-token'),
        ),
        pushRegistryProvider.overrideWithValue(SupabasePushRegistry(client)),
        pushReceiptsProvider.overrideWithValue(
          SupabasePushReceipts(receipts ?? client),
        ),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    c.listen(pushRegistrationProvider, (_, _) {});
    return c;
  }

  test(
    'on start, the receipts reach the server as pax and leave the phone',
    () async {
      final wire = _Wire();
      final phone = await _signedIn(wire);
      addTearDown(phone.dispose);
      await collected(3);

      final c = start(phone);
      addTearDown(c.dispose);

      await _until(() => wire.answers.isNotEmpty, 'the upload');
      expect(wire.answers.single, (
        status: 200,
        body: '3',
      ), reason: 'the server stored all three for the caller');
      await _until(
        () =>
            (disk.values['flutter.sis.push_receipts'] as List?)?.isEmpty ??
            true,
        'the buffer to empty',
      );
      expect(await pending(), isEmpty);
    },
  );

  test(
    'more than one batch: only what the server took leaves the phone',
    () async {
      final wire = _Wire();
      final phone = await _signedIn(wire);
      addTearDown(phone.dispose);
      // More receipts than one call carries (the phone keeps 50 itself; the
      // buffer is written directly to hold more).
      final one = [
        for (var i = 0; i < 120; i++)
          jsonEncode({
            'stage': 'received',
            'occurred_at': DateTime.now().toUtc().toIso8601String(),
            'build': i,
          }),
      ];
      disk.values['flutter.sis.push_receipts'] = one;
      expect(await pending(), hasLength(120), reason: 'precondition');

      final c = start(phone);
      addTearDown(c.dispose);

      await _until(() => wire.answers.isNotEmpty, 'the upload');
      expect(wire.answers.single, (status: 200, body: '100'));
      await _until(
        () => (disk.values['flutter.sis.push_receipts'] as List?)?.length == 20,
        'the first 100 to leave the phone',
      );
      expect(
        [for (final r in await pending()) r['build']],
        [for (var i = 100; i < 120; i++) i],
        reason: 'the oldest 100 went, the newest 20 wait',
      );

      await SupabasePushReceipts(phone).upload();
      expect(wire.answers.last, (status: 200, body: '20'));
      expect(await pending(), isEmpty);
    },
  );

  test('refused (this phone was replaced by another sign-in): the receipts '
      'stay, and go on the next start that is let through', () async {
    final wire = _Wire();
    final phone = await _signedIn(wire);
    addTearDown(phone.dispose);
    expect(await phone.rpc('activate_session'), isTrue);
    await collected(4);
    final other = await _signedIn(_Wire());
    addTearDown(other.dispose);
    expect(
      await other.rpc('activate_session'),
      isTrue,
      reason: 'precondition: the other sign-in now holds the device',
    );

    // The app on the replaced phone: its receipts go out on a client the
    // server no longer lets through.
    final c = start(other, receipts: phone);
    addTearDown(c.dispose);
    await _until(() => wire.answers.isNotEmpty, 'the refused upload');
    expect(wire.answers.single.status, isNot(200), reason: '${wire.answers}');
    // Give removeFirst a chance to run, if it wrongly would.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await pending(), hasLength(4), reason: 'refused, yet dropped');
    c.dispose();

    final wire2 = _Wire();
    final again = await _signedIn(wire2);
    addTearDown(again.dispose);
    final c2 = start(again);
    addTearDown(c2.dispose);
    await _until(() => wire2.answers.isNotEmpty, 'the next upload');
    expect(wire2.answers.single, (status: 200, body: '4'));
    await _until(
      () =>
          (disk.values['flutter.sis.push_receipts'] as List?)?.isEmpty ?? true,
      'the buffer to empty',
    );
  });

  test('offline: the receipts stay, nothing is thrown', () async {
    final phone = await _signedIn(_Wire());
    addTearDown(phone.dispose);
    await collected(2);
    final dead = await deadButSignedIn(phone);
    addTearDown(dead.dispose);

    await expectLater(SupabasePushReceipts(dead).upload(), completes);

    expect(await pending(), hasLength(2));
  });
}
