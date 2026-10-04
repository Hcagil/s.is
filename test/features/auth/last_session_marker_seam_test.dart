// The cold-start marker on a real disk (0.30.15/0.30.16): SessionController
// over the real FileLastSessionStore in a temp directory, auth faked.
//
// What the in-memory store fake cannot show: two writes of the marker in
// flight at once. On the first run the server's "yes" writes the marker and
// the profile, the moment it says the first-run screen is done, writes it
// again with onboarded = true. Whatever the disk does with the two writes,
// the marker afterwards must be the last one asked for and readable, or the
// next cold start silently loses the instant stored start.
//
// Plain `test`, not testWidgets: real file I/O does not run under fake time.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/data/file_last_session_store.dart';
import 'package:sis/features/auth/domain/session_state.dart';

import '../../support/last_session_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Future<void> until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// The marker file has stopped changing for 300 ms (every write landed).
Future<void> settled(File f) async {
  String? last;
  var since = DateTime.now();
  await until(() {
    final now = f.existsSync() ? f.readAsStringSync() : null;
    if (now != last) {
      last = now;
      since = DateTime.now();
      return false;
    }
    return DateTime.now().difference(since) > const Duration(milliseconds: 300);
  }, 'the marker writes to land');
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sis-marker'));
  tearDown(() => dir.delete(recursive: true));

  FileLastSessionStore store() => FileLastSessionStore(root: () async => dir);

  test('two saves in flight on one store: the marker reads back as the one '
      'asked for last', () async {
    final s = store();
    await Future.wait([
      s.save(marker(onboarded: false)),
      s.save(marker(onboarded: true)),
    ]);

    final got = await store().load();
    expect(got, isNotNull, reason: 'the marker was lost or left corrupt');
    expect(got!.onboarded, isTrue, reason: 'the earlier save won');
  });

  test('the profile says onboarded the moment the server confirms: the next '
      'cold start shows the stored state before the server answers', () async {
    ProviderContainer rig(ColdAuth auth) => ProviderContainer(
      overrides: [
        runtimeConfigProvider.overrideWithValue(config),
        authRepositoryProvider.overrideWithValue(auth),
        lastSessionStoreProvider.overrideWithValue(store()),
      ],
    );

    // First run: no marker, so the gated path; the server says yes at once,
    // and the profile (already cached) says the first-run screen is done.
    final first = rig(ColdAuth(autoAllow: true));
    first.listen(sessionControllerProvider, (_, next) {
      if (next.value case final Allowed a when a.confirmed) {
        first.read(sessionControllerProvider.notifier).markOnboarded();
      }
    }, fireImmediately: true);
    await until(
      () => switch (first.read(sessionControllerProvider).value) {
        final Allowed a => a.confirmed,
        _ => false,
      },
      'the gated confirm',
    );
    final file = File('${dir.path}/last_session.json');
    await settled(file);
    final onDisk = file.existsSync() ? file.readAsStringSync() : 'no file';
    first.dispose();

    // Next cold start, the server check held in flight.
    final auth = ColdAuth();
    final next = rig(auth);
    addTearDown(next.dispose);
    final states = <SessionState>[];
    next.listen(sessionControllerProvider, (_, s) {
      if (s.value case final v?) states.add(v);
    }, fireImmediately: true);
    await until(
      () => states.isNotEmpty || auth.checks.isNotEmpty,
      'the start to show something or ask the server',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      states,
      isNotEmpty,
      reason: 'the gated path ran, waiting on the server; marker: $onDisk',
    );
    expect(
      states.first,
      isA<Allowed>()
          .having((a) => a.confirmed, 'confirmed', isFalse)
          .having((a) => a.onboarded, 'onboarded', isTrue),
      reason: 'marker: $onDisk',
    );
  });
}
