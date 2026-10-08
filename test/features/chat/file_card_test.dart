// Slice 7a, from its contract: the file card (file-<id>, file-tile-<id>,
// file-ring-<id>), auto-download by the member's settings on the network the
// phone is on, a tap that downloads or opens, the refused-download and
// cannot-open notices. Written from the contract, never from the widgets.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/autodownload/application/auto_download_controller.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/file_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

Finder byKey(String k) => find.byKey(ValueKey(k));

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(411, 891);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

ChatFake world() => ChatFake(self: me.userId)
  ..conversationsResult = const Ok([Conversation(id: 'c1', other: bob)])
  ..membersResult = const Ok([bob]);

/// Frames for ~1 s: a running download spins, so pumpAndSettle never ends.
Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Lets a notice's timer run out before the tree is torn down.
Future<void> noticeGone(WidgetTester t) => t.pump(const Duration(seconds: 10));

Future<ProviderContainer> pumpChat(
  WidgetTester t,
  ChatFake chat, {
  FileRepoFake? repo,
  DeviceFilesFake? devices,
  ProbeFake? probe,
  AutoDownloadSettings settings = const AutoDownloadSettings(),
}) async {
  phone(t);
  final files = devices ?? DeviceFilesFake();
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        galleryProvider.overrideWithValue(
          GalleryFake(photos: [GalleryPhoto('p1')]),
        ),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        chatFileRepositoryProvider.overrideWithValue(
          repo ?? FileRepoFake(devices: files),
        ),
        deviceFilesProvider.overrideWithValue(files),
        networkProbeProvider.overrideWithValue(
          probe ?? ProbeFake(NetworkKind.mobile),
        ),
        initialAutoDownloadProvider.overrideWithValue(settings),
        autoDownloadStoreProvider.overrideWithValue(AutoDownloadStoreFake()),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await frames(t);
  return container;
}

void main() {
  group('file cards', () {
    testWidgets('a received file shows its card and name; on mobile it waits', (
      t,
    ) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      await pumpChat(t, chat, repo: repo, devices: devices);
      expect(byKey('file-f1'), findsOneWidget);
      expect(
        byKey('file-ring-f1'),
        findsOneWidget,
        reason: 'a received file not on the phone shows the download ring',
      );
      expect(byKey('file-tile-f1'), findsNothing);
      expect(find.text('Cabin booking.pdf'), findsWidgets);
      expect(repo.downloads.isEmpty, isTrue);
    });

    testWidgets('on Wi-Fi a document downloads by itself and shows the ring', (
      t,
    ) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final probe = ProbeFake(NetworkKind.wifi);
      final container = await pumpChat(
        t,
        chat,
        repo: repo,
        devices: devices,
        probe: probe,
      );
      expect(repo.downloads.length, 1);
      expect(repo.downloads[0].attachmentPath, 'c1/f1/Cabin booking.pdf');
      expect(repo.downloads[0].expectedSize, 2516582);
      expect(byKey('file-ring-f1'), findsOneWidget);
      repo.progress(0, 0.5);
      await frames(t);
      expect(container.read(fileDownloadsProvider)['f1'], 0.5);
      expect(byKey('file-ring-f1'), findsOneWidget);
      repo.downloadOk(0);
      await frames(t);
      expect(byKey('file-ring-f1'), findsNothing);
      expect(byKey('file-tile-f1'), findsOneWidget, reason: 'now on the phone');
    });

    testWidgets('disabled: nothing downloads by itself on Wi-Fi', (t) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final probe = ProbeFake(NetworkKind.wifi);
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.disabled,
      );
      await pumpChat(
        t,
        chat,
        repo: repo,
        devices: devices,
        probe: probe,
        settings: settings,
      );
      expect(repo.downloads.isEmpty, isTrue);
    });

    testWidgets('a tap downloads a file that is not on the phone', (t) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      await pumpChat(t, chat, repo: repo, devices: devices);
      await t.tap(byKey('file-f1'));
      await frames(t);
      expect(repo.downloads.length, 1);
      expect(repo.downloads[0].attachmentPath, 'c1/f1/Cabin booking.pdf');
      expect(byKey('file-ring-f1'), findsOneWidget);
    });

    testWidgets('a refused download shows why and stops', (t) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final container = await pumpChat(t, chat, repo: repo, devices: devices);
      await t.tap(byKey('file-f1'));
      await frames(t);
      repo.downloadFail(0, const NetworkFailure('This file is not available.'));
      await frames(t);
      expect(find.text('This file is not available.'), findsOneWidget);
      expect(
        byKey('file-ring-f1'),
        findsOneWidget,
        reason: 'still not on the phone: the ring to try again',
      );
      expect(container.read(fileDownloadsProvider), isNot(contains('f1')));
      await noticeGone(t);
    });

    testWidgets('a tap opens a file already on the phone', (t) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      devices.written.add('/app/files/f1/Cabin booking.pdf');
      final repo = FileRepoFake(devices: devices);
      await pumpChat(t, chat, repo: repo, devices: devices);
      await t.tap(byKey('file-f1'));
      await frames(t);
      expect(devices.opened, ['/app/files/f1/Cabin booking.pdf']);
      expect(repo.downloads.isEmpty, isTrue);
    });

    testWidgets('no app to open it: the notice', (t) async {
      final chat = world()..messagesResult = Ok([fileMessage('f1')]);
      final devices = DeviceFilesFake();
      devices.written.add('/app/files/f1/Cabin booking.pdf');
      devices.opens = false;
      final repo = FileRepoFake(devices: devices);
      await pumpChat(t, chat, repo: repo, devices: devices);
      await t.tap(byKey('file-f1'));
      await frames(t);
      expect(
        find.text('No app on this phone can open this file.'),
        findsOneWidget,
      );
      await noticeGone(t);
    });
  });
}
