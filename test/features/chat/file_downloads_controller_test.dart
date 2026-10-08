import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/autodownload/application/auto_download_controller.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

import '../../support/fakes.dart' show AttachmentCacheFake;
import '../../support/file_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

ProviderContainer scope({
  required DeviceFilesFake devices,
  required FileRepoFake repo,
  ProbeFake? probe,
  AutoDownloadSettings settings = const AutoDownloadSettings(),
  AutoDownloadStoreFake? store,
}) {
  final c = ProviderContainer.test(
    overrides: [
      sessionControllerProvider.overrideWith(_SignedIn.new),
      deviceFilesProvider.overrideWithValue(devices),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
      chatFileRepositoryProvider.overrideWithValue(repo),
      networkProbeProvider.overrideWithValue(
        probe ?? ProbeFake(NetworkKind.wifi),
      ),
      initialAutoDownloadProvider.overrideWithValue(settings),
      autoDownloadStoreProvider.overrideWithValue(
        store ?? AutoDownloadStoreFake(settings),
      ),
    ],
  );
  c.listen(fileDownloadsProvider, (_, _) {});
  return c;
}

/// [scope] once the member is signed in, as the app is before any chat shows.
Future<ProviderContainer> scoped({
  required DeviceFilesFake devices,
  required FileRepoFake repo,
  ProbeFake? probe,
  AutoDownloadSettings settings = const AutoDownloadSettings(),
  AutoDownloadStoreFake? store,
}) async {
  final c = scope(
    devices: devices,
    repo: repo,
    probe: probe,
    settings: settings,
    store: store,
  );
  c.listen(sessionControllerProvider, (_, _) {});
  await c.read(sessionControllerProvider.future);
  await settle();
  return c;
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
}

void main() {
  group('FileDownloads.start', () {
    test('success', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      final startFuture = c.read(fileDownloadsProvider.notifier).start(message);
      await settle();
      expect(repo.downloads.single.attachmentPath, 'c1/f1/Cabin booking.pdf');
      expect(repo.downloads.single.destPath, '/app/files/f1/Cabin booking.pdf');
      expect(
        repo.downloads.single.expectedSize,
        2516582,
        reason: 'the size the message promised is checked',
      );

      repo.progress(0, 0.25);
      await settle();
      expect(c.read(fileDownloadsProvider)['f1'], 0.25);

      repo.progress(0, 0.75);
      await settle();
      expect(c.read(fileDownloadsProvider)['f1'], 0.75);

      repo.downloadOk(0);
      final failure = await startFuture;
      expect(failure, isNull);
      await settle();
      expect(c.read(fileDownloadsProvider).containsKey('f1'), false);

      final sub = c.listen(
        storedFileProvider((id: 'f1', name: 'Cabin booking.pdf')),
        (_, _) {},
      );
      final storedPath = await c.read(
        storedFileProvider((id: 'f1', name: 'Cabin booking.pdf')).future,
      );
      sub.close();
      expect(storedPath, '/app/files/f1/Cabin booking.pdf');
    });

    test('refused', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      final startFuture = c.read(fileDownloadsProvider.notifier).start(message);
      await settle();

      repo.downloadFail(0, const NetworkFailure('This file is not available.'));
      final failure = await startFuture;
      expect(failure, isA<NetworkFailure>());
      expect(
        (failure as NetworkFailure).message,
        'This file is not available.',
      );
      expect(c.read(fileDownloadsProvider).containsKey('f1'), false);

      final sub = c.listen(
        storedFileProvider((id: 'f1', name: 'Cabin booking.pdf')),
        (_, _) {},
      );
      final storedPath = await c.read(
        storedFileProvider((id: 'f1', name: 'Cabin booking.pdf')).future,
      );
      sub.close();
      expect(storedPath, isNull);
    });

    test('state holds id while running', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      final run = c.read(fileDownloadsProvider.notifier).start(message);
      await settle();
      expect(repo.downloads, hasLength(1));
      final f = c.read(fileDownloadsProvider)['f1'];
      expect(f, isNotNull, reason: 'a running download shows its ring');
      expect(f, inInclusiveRange(0, 1));
      repo.downloadOk(0);
      await run;
    });
  });

  group('FileDownloads.auto', () {
    test('tries a message once: a second auto after a failure asks '
        'nothing', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      c.read(fileDownloadsProvider.notifier).auto(message);
      await settle();
      expect(repo.downloads, hasLength(1));
      repo.downloadFail(0, const NetworkFailure('x', retryable: true));
      await settle();

      c.read(fileDownloadsProvider.notifier).auto(message);
      await settle();
      expect(repo.downloads, hasLength(1));
      expect(c.read(fileDownloadsProvider), isEmpty);
    });

    test('a tap after a failed auto download still downloads', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      c.read(fileDownloadsProvider.notifier).auto(message);
      await settle();
      repo.downloadFail(0, const NetworkFailure('x', retryable: true));
      await settle();

      final tap = c.read(fileDownloadsProvider.notifier).start(message);
      await settle();
      expect(repo.downloads, hasLength(2));
      repo.downloadOk(1);
      expect(await tap, isNull);
    });

    test('a second start while one runs asks nothing more', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(devices: devices, repo: repo);
      addTearDown(c.dispose);

      final message = fileMessage('f1');
      final first = c.read(fileDownloadsProvider.notifier).start(message);
      await settle();
      final second = c.read(fileDownloadsProvider.notifier).start(message);
      c.read(fileDownloadsProvider.notifier).auto(message);
      await settle();
      expect(repo.downloads, hasLength(1));
      repo.downloadOk(0);
      expect(await first, isNull);
      await second;
    });
  });

  group('photoGate', () {
    test('defaults on mobile', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final c = await scoped(
        devices: devices,
        repo: repo,
        probe: ProbeFake(NetworkKind.mobile),
      );
      addTearDown(c.dispose);

      final sub = c.listen(photoGateProvider('c1/p1.jpg'), (_, _) {});
      final gate = await c.read(photoGateProvider('c1/p1.jpg').future);
      sub.close();
      expect(gate, true);
    });

    test('disabled settings on wifi', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.disabled,
      );
      final c = await scoped(
        devices: devices,
        repo: repo,
        probe: ProbeFake(NetworkKind.wifi),
        settings: settings,
      );
      addTearDown(c.dispose);

      var sub = c.listen(photoGateProvider('c1/p1.jpg'), (_, _) {});
      var gate = await c.read(photoGateProvider('c1/p1.jpg').future);
      sub.close();
      expect(gate, false);

      c.read(photoApprovalsProvider.notifier).approve('c1/p1.jpg');
      await settle();

      sub = c.listen(photoGateProvider('c1/p1.jpg'), (_, _) {});
      gate = await c.read(photoGateProvider('c1/p1.jpg').future);
      sub.close();
      expect(gate, true);

      sub = c.listen(photoGateProvider('c1/p2.jpg'), (_, _) {});
      gate = await c.read(photoGateProvider('c1/p2.jpg').future);
      sub.close();
      expect(gate, false);
    });

    test('disabled settings, probe throws', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.disabled,
      );
      final c = await scoped(
        devices: devices,
        repo: repo,
        probe: ProbeFake(NetworkKind.wifi, error: true),
        settings: settings,
      );
      addTearDown(c.dispose);

      final sub = c.listen(photoGateProvider('c1/p1.jpg'), (_, _) {});
      final gate = await c.read(photoGateProvider('c1/p1.jpg').future);
      sub.close();
      expect(gate, true);
    });
  });

  group('AutoDownloadController', () {
    test('setPreset disabled', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final store = AutoDownloadStoreFake();
      final c = await scoped(devices: devices, repo: repo, store: store);
      addTearDown(c.dispose);

      final notifier = c.read(autoDownloadProvider.notifier);
      final future = notifier.setPreset(AutoDownloadPreset.disabled);
      expect(
        c.read(autoDownloadProvider),
        AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled),
      );
      await future;
      expect(
        c.read(autoDownloadProvider),
        AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled),
      );
      expect(
        store.saved.last,
        AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled),
      );
    });

    test('failed save', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final store = AutoDownloadStoreFake();
      store.failSaves = true;
      final c = await scoped(devices: devices, repo: repo, store: store);
      addTearDown(c.dispose);

      await c.read(autoDownloadProvider.notifier).setKinds(
        NetworkKind.roaming,
        {MediaKind.photos},
      );
      expect(c.read(autoDownloadProvider).kindsFor(NetworkKind.roaming), {
        MediaKind.photos,
      });
    });

    test('build reads initialAutoDownloadProvider', () async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.wifiOnly,
      );
      final c = await scoped(devices: devices, repo: repo, settings: settings);
      addTearDown(c.dispose);

      expect(
        c.read(autoDownloadProvider),
        AutoDownloadSettings.forPreset(AutoDownloadPreset.wifiOnly),
      );
    });
  });
}
