// The chat screen as file_card_test mounts it (fakes at every boundary), with
// the video fakes passed in: for the video bubble, composer and player tests.
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

import 'fakes.dart';
import 'file_fakes.dart';
import 'video_fakes.dart';

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

Future<ProviderContainer> pumpVideoChat(
  WidgetTester t,
  ChatFake chat, {
  FileRepoFake? repo,
  DeviceFilesFake? devices,
  ProbeFake? probe,
  AutoDownloadSettings settings = const AutoDownloadSettings(),
  DeviceVideosFake? videos,
  VideoPlaybackFactoryFake? playback,
  VideoSharerFake? sharer,
  SendQueueStoreFake? store,
  Locale locale = const Locale('en'),
}) async {
  phone(t);
  final files = devices ?? DeviceFilesFake();
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(
          videos: videos,
          playback: playback,
          sharer: sharer,
          store: store,
        ),
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
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await frames(t);
  return container;
}
