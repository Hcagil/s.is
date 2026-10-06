@Tags(['integration'])
library;

// Cold start from the stored last session (0.30.15) against a running local
// Supabase: the real SupabaseAuthRepository, the real FileLastSessionStore
// over a temp directory, the real SessionController. A first run confirms the
// session the gated way and writes the marker, as a phone does on the day it
// is set up. The member is then revoked on the server, and a second run
// (the next cold start, same stored session) must show the stored state
// first and lock the moment the server answers -- with RLS refusing data the
// whole time.
//
// Revocations, one per account (supabase/seed.sql csa..cse, csz partner):
//   csa  off the allowlist: the server's allowlist check joins auth.users'
//        email, so the email is moved to an address the allowlist does not
//        hold (app_private is not reachable from a client, not even with the
//        service key); the email is put back afterwards
//   csb  replaced by a second phone's activate_session
//   csc  off the allowlist, sending while the check is still in flight
//   csd  off the allowlist while the phone is offline, then reconnecting
//   cse  every auth.sessions row deleted (admin sign-out)
//
// Needs SUPABASE_TEST_SERVICE_KEY (test/support/service_key.dart). Run with
// --concurrency=1 like the rest of the suite.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/file_last_session_store.dart';
import 'package:sis/features/auth/data/supabase_auth_repository.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const config = RuntimeConfig(
  supabaseUrl: _url,
  supabasePublishableKey: _key,
  googleWebClientId: 'c',
);

/// The phone's connection: can drop every request (offline) and can hold
/// activate_session in flight until released, as a slow network does.
class Line extends http.BaseClient {
  final _inner = http.Client();
  bool offline = false;
  Completer<void>? _hold;
  int activations = 0;

  /// activate_session calls dropped while offline.
  int refusedChecks = 0;

  void holdChecks() => _hold = Completer<void>();
  void releaseChecks() {
    _hold?.complete();
    _hold = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (offline) {
      if (request.url.path.endsWith('/rpc/activate_session')) refusedChecks++;
      throw const SocketException('Connection refused (test: offline)');
    }
    if (request.url.path.endsWith('/rpc/activate_session')) {
      activations++;
      final hold = _hold;
      if (hold != null) await hold.future;
    }
    return _inner.send(request);
  }
}

class Phone {
  Phone(this.line, this.client, this.dir);
  final Line line;
  final SupabaseClient client;
  final Directory dir;
  File get markerFile => File('${dir.path}/last_session.json');
  String get uid => client.auth.currentUser!.id;
}

Future<Phone> phoneFor(String email) async {
  final line = Line();
  final client = SupabaseClient(
    _url,
    _key,
    httpClient: line,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: '$email is not allowlisted (supabase/seed.sql)',
  );
  return Phone(line, client, await Directory.systemTemp.createTemp('sis-cs'));
}

/// One app run: the real controller over [p]'s client and marker directory.
class Run {
  Run(Phone p)
    : c = ProviderContainer(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(
            SupabaseAuthRepository(
              p.client,
              GoogleSignIn.instance,
              googleWebClientId: 'c',
            ),
          ),
          lastSessionStoreProvider.overrideWithValue(
            FileLastSessionStore(root: () async => p.dir),
          ),
        ],
      ) {
    c.listen(sessionControllerProvider, (_, next) {
      if (next.value case final v?) states.add(v);
    }, fireImmediately: true);
  }
  final ProviderContainer c;
  final states = <SessionState>[];
  SessionState? get state => c.read(sessionControllerProvider).value;

  Future<void> until(
    bool Function() ok,
    String what, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) {
        fail('timed out waiting for $what; states: $states');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

bool isUnconfirmed(SessionState s) => s is Allowed && !s.confirmed;
bool isConfirmed(SessionState? s) => s is Allowed && s.confirmed;

/// The day the phone was set up: gated start, confirmed, onboarded, marker
/// on disk.
Future<void> firstRun(Phone p) async {
  final run = Run(p);
  await run.until(() => isConfirmed(run.state), 'the gated confirm');
  run.c.read(sessionControllerProvider.notifier).markOnboarded();
  // Every write of this run has landed (the file unchanged for 300 ms), and
  // what they left is a readable marker: a corrupt one is dropped by the next
  // start, which then takes the gated path and looks like a race below.
  String? last;
  var since = DateTime.now();
  await run.until(() {
    final now = p.markerFile.existsSync()
        ? p.markerFile.readAsStringSync()
        : null;
    if (now != last) {
      last = now;
      since = DateTime.now();
      return false;
    }
    return now != null &&
        DateTime.now().difference(since) > const Duration(milliseconds: 300);
  }, 'the marker on disk to settle');
  final Object? onDisk;
  try {
    onDisk = jsonDecode(last!);
  } on FormatException {
    fail('the first run left a corrupt marker on disk: $last');
  }
  expect(
    onDisk,
    containsPair('session', containsPair('onboarded', true)),
    reason: 'the onboarded marker on disk',
  );
  run.c.dispose();
}

late SupabaseClient service;
final _phones = <Phone>[];
final _restoreEmail = <String, String>{}; // uid -> email

Future<Phone> phone(String email) async {
  final p = await phoneFor(email);
  _phones.add(p);
  return p;
}

/// Takes [p]'s account off the allowlist as the server sees it.
Future<void> offAllowlist(Phone p, String email) async {
  _restoreEmail[p.uid] = email;
  await service.auth.admin.updateUserById(
    p.uid,
    attributes: AdminUserAttributes(
      email: 'revoked-${p.uid.substring(0, 8)}@nowhere.test',
      emailConfirm: true,
    ),
  );
}

/// What RLS gives [p]'s client now, table by table.
Future<Map<String, int>> visible(Phone p) async => {
  for (final (t, col) in [
    ('messages', 'id'),
    ('conversations', 'id'),
    ('conversation_members', 'user_id'),
    ('profiles', 'user_id'),
  ])
    t: (await p.client.from(t).select(col)).length,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  setUpAll(() {
    service = SupabaseClient(_url, serviceKey());
  });
  tearDown(() async {
    for (final MapEntry(key: uid, value: email) in _restoreEmail.entries) {
      await service.auth.admin.updateUserById(
        uid,
        attributes: AdminUserAttributes(email: email, emailConfirm: true),
      );
    }
    _restoreEmail.clear();
    for (final p in _phones) {
      p.line.offline = false;
      p.line.releaseChecks();
      await p.client.dispose();
      await p.dir.delete(recursive: true);
    }
    _phones.clear();
  });
  tearDownAll(() => service.dispose());

  test('removed from the allowlist: the next start shows the stored state, '
      'then Denied, the marker is wiped, and RLS returns zero rows', () async {
    final p = await phone('csa@integration.test');
    final partner = await phone('csz@integration.test');
    final chat = SupabaseChatRepository(p.client);
    await findByTag(p.client, [partner.client]);
    final conv =
        (await chat.startDirectConversation(partner.uid) as Ok<String>).value;
    expect(
      await chat.send(
        id: randomMessageId(),
        conversationId: conv,
        body: 'before',
      ),
      isA<Ok<Object?>>(),
    );
    final before = await visible(p);
    expect(before['messages'], greaterThan(0), reason: 'fixture: no message');
    expect(before['conversations'], greaterThan(0));
    await firstRun(p);

    await offAllowlist(p, 'csa@integration.test');
    final run = Run(p);
    await run.until(() => run.state is Denied, 'Denied');
    expect(
      isUnconfirmed(run.states.first),
      isTrue,
      reason: 'the stored state was not shown first: ${run.states}',
    );
    expect(run.states.where(isConfirmed), isEmpty, reason: 'confirmed once');
    await run.until(() => !p.markerFile.existsSync(), 'the marker wipe');
    expect(await visible(p), {
      'messages': 0,
      'conversations': 0,
      'conversation_members': 0,
      'profiles': 0,
    });
    run.c.dispose();
  });

  test('replaced by a second phone: the first phone\'s next start shows the '
      'stored state, then Denied', () async {
    final p = await phone('csb@integration.test');
    await firstRun(p);

    final second = await phone('csb@integration.test'); // activates its own
    expect(
      second.client.auth.currentSession!.accessToken,
      isNot(p.client.auth.currentSession!.accessToken),
    );

    final run = Run(p);
    await run.until(() => run.state is Denied, 'Denied');
    expect(isUnconfirmed(run.states.first), isTrue, reason: '${run.states}');
    await run.until(() => !p.markerFile.existsSync(), 'the marker wipe');
    expect((await visible(p))['messages'], 0);
    run.c.dispose();
  });

  test('a revoked member sending in the unconfirmed window is refused by the '
      'server (messages_send), and the row never exists', () async {
    final p = await phone('csc@integration.test');
    final partner = await phone('csz@integration.test');
    final chat = SupabaseChatRepository(p.client);
    await findByTag(p.client, [partner.client]);
    final conv =
        (await chat.startDirectConversation(partner.uid) as Ok<String>).value;
    await firstRun(p);

    await offAllowlist(p, 'csc@integration.test');
    p.line.holdChecks();
    final run = Run(p);
    await run.until(() => run.state != null, 'the first state');
    expect(isUnconfirmed(run.state!), isTrue, reason: '${run.states}');

    final id = randomMessageId();
    final sent = await chat.send(id: id, conversationId: conv, body: 'late');
    expect(sent, isA<Err<Object?>>(), reason: 'a revoked insert was accepted');
    final rows = await service.from('messages').select('id').eq('id', id);
    expect(rows, isEmpty, reason: 'the revoked insert is in the table');
    expect(isUnconfirmed(run.state!), isTrue, reason: 'still unconfirmed');

    p.line.releaseChecks();
    await run.until(() => run.state is Denied, 'Denied');
    run.c.dispose();
  });

  test('revoked while the phone was offline: the stored state while the '
      'ladder retries, then Denied within one retry of reconnecting', () async {
    final p = await phone('csd@integration.test');
    await firstRun(p);
    await offAllowlist(p, 'csd@integration.test');

    p.line.offline = true;
    final run = Run(p);
    // The first check fails and the retry ladder asks again (the Err drives
    // the ladder; there is no flag or notice any more).
    await run.until(
      () => p.line.refusedChecks >= 2,
      'a failed check retried by the ladder',
      timeout: const Duration(seconds: 8),
    );
    expect(isUnconfirmed(run.state!), isTrue, reason: '${run.states}');
    expect(p.markerFile.existsSync(), isTrue, reason: 'offline wiped it');

    final checksBefore = p.line.activations;
    final back = DateTime.now();
    p.line.offline = false;
    // The ladder's longest wait up to here is its next step; the first is 2 s.
    await run.until(
      () => run.state is Denied,
      'Denied after reconnecting',
      timeout: const Duration(seconds: 12),
    );
    expect(
      p.line.activations - checksBefore,
      1,
      reason: 'more than one retry was needed after reconnecting',
    );
    expect(
      DateTime.now().difference(back),
      lessThan(const Duration(seconds: 9)),
    );
    await run.until(() => !p.markerFile.existsSync(), 'the marker wipe');
    run.c.dispose();
  });

  test('every auth session deleted (signed out by the server): the next '
      'start locks and wipes the marker', () async {
    final p = await phone('cse@integration.test');
    await firstRun(p);
    await service.auth.admin.signOut(p.client.auth.currentSession!.accessToken);
    final rows = await p.client.from('messages').select('id');
    expect(rows, isEmpty, reason: 'RLS still serves a deleted session');

    final run = Run(p);
    await run.until(
      () => run.state is Denied || run.state is SignedOut,
      'a locked state',
    );
    expect(isUnconfirmed(run.states.first), isTrue, reason: '${run.states}');
    await run.until(() => !p.markerFile.existsSync(), 'the marker wipe');
    run.c.dispose();
  });
}
