// Slice 7a, from its contract: File in the attach card picks and sends,
// files over 50 MB are skipped with the fileTooBig notice, and a received
// photo gated by auto-download waits behind attachment-download-<id> until a
// tap approves it. Written from the contract, never from the widgets.
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
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/file_fakes.dart';
import '../../support/video_fakes.dart';

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
        ...videoOverrides(),
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
  Future<void> attachFile(WidgetTester t) async {
    await t.tap(byKey('composer-attach'));
    await frames(t);
    await t.tap(byKey('attach-file'));
    await frames(t);
  }

  Future<(FileRepoFake, DeviceFilesFake)> composer(
    WidgetTester t,
    FilePick pick,
  ) async {
    final devices = DeviceFilesFake(pickResult: pick);
    final repo = FileRepoFake(devices: devices);
    await pumpChat(
      t,
      world()..messagesResult = const Ok(<Message>[]),
      repo: repo,
      devices: devices,
    );
    await attachFile(t);
    return (repo, devices);
  }

  group('sending a file', () {
    testWidgets('File in the attach card picks and sends', (t) async {
      final (repo, devices) = await composer(
        t,
        FilePick(files: [picked('n1')]),
      );
      expect(devices.picks, 1);
      expect(repo.sends, hasLength(1));
      expect(repo.sends.single.conversationId, 'c1');
      expect(repo.sends.single.file.id, 'n1');
      expect(byKey('file-n1'), findsOneWidget, reason: 'the pending message');
      repo.sendOk(0);
      await frames(t);
      expect(byKey('file-n1'), findsOneWidget);
    });

    testWidgets('two files over 50 MB: none sent, the notice says so', (
      t,
    ) async {
      final (repo, _) = await composer(t, const FilePick(tooBig: 2));
      expect(repo.sends, isEmpty);
      expect(
        find.text('2 files are over 50 MB and were not sent.'),
        findsOneWidget,
      );
      await noticeGone(t);
    });

    testWidgets('one over 50 MB, one fine: the fine one is sent and the '
        'notice is singular', (t) async {
      final (repo, _) = await composer(
        t,
        FilePick(files: [picked('n2')], tooBig: 1),
      );
      expect(repo.sends.map((s) => s.file.id), ['n2']);
      expect(
        find.text('1 file is over 50 MB and was not sent.'),
        findsOneWidget,
      );
      await noticeGone(t);
    });

    testWidgets('a cancelled chooser sends nothing and says nothing', (
      t,
    ) async {
      final (repo, devices) = await composer(t, const FilePick());
      expect(devices.picks, 1);
      expect(repo.sends, isEmpty);
      expect(find.textContaining('over 50 MB'), findsNothing);
    });
  });

  group('a received photo and auto-download', () {
    const path = 'c1/p1/photo.jpg';
    ChatFake photoChat() {
      final photo = Message(
        id: 'p1',
        conversationId: 'c1',
        senderId: 'u2',
        body: '',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        attachmentPath: path,
      );
      return world()
        ..messagesResult = Ok([photo])
        ..storedObjects.add(path);
    }

    testWidgets('disabled: the photo waits for a tap, then loads', (t) async {
      final chat = photoChat();
      final container = await pumpChat(
        t,
        chat,
        settings: AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled),
      );
      expect(byKey('attachment-download-p1'), findsOneWidget);
      expect(chat.bytesRequests, isNot(contains(path)));
      await t.tap(byKey('attachment-download-p1'));
      await frames(t);
      expect(container.read(photoApprovalsProvider), contains(path));
      expect(chat.bytesRequests, contains(path));
      expect(byKey('attachment-download-p1'), findsNothing);
    });

    testWidgets('defaults on mobile: the photo loads without a tap', (t) async {
      final chat = photoChat();
      await pumpChat(t, chat);
      expect(byKey('attachment-download-p1'), findsNothing);
      expect(chat.bytesRequests, contains(path));
    });

    testWidgets('defaults while roaming: the photo waits', (t) async {
      final chat = photoChat();
      await pumpChat(t, chat, probe: ProbeFake(NetworkKind.roaming));
      expect(byKey('attachment-download-p1'), findsOneWidget);
      expect(chat.bytesRequests, isNot(contains(path)));
    });

    testWidgets('a network probe that fails loads the photo', (t) async {
      final chat = photoChat();
      await pumpChat(
        t,
        chat,
        probe: ProbeFake(NetworkKind.roaming, error: true),
      );
      expect(byKey('attachment-download-p1'), findsNothing);
      expect(chat.bytesRequests, contains(path));
    });
  });
}
