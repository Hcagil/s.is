import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video.dart';

import '../../support/file_fakes.dart';
import '../../support/l10n.dart';
import '../../support/video_chat.dart';

void main() {
  final video = fileMessage(
    'v1',
    name: 'Beach day.mp4',
    mime: videoMime,
    size: 8388608,
    durationMs: 41000,
  );

  Future<void> replyTo(WidgetTester t, String id) async {
    await t.longPress(byKey('message-$id'));
    await frames(t);
    await t.tap(byKey('menu-reply'));
    await frames(t);
    expect(byKey('reply-bar'), findsOneWidget);
  }

  Finder inBar(String text) => find.descendant(
    of: byKey('reply-bar'),
    matching: find.textContaining(text),
  );

  /// The words shown under [of], for the failure message.
  List<String?> words(WidgetTester t, Finder of) => [
    for (final w in t.widgetList(
      find.descendant(of: of, matching: find.byType(RichText)),
    ))
      (w as RichText).text.toPlainText(),
  ];

  group('reply to a video', () {
    testWidgets('the reply bar quotes a video as 🎥 Video, not its name', (
      t,
    ) async {
      await pumpVideoChat(t, world()..messagesResult = Ok([video]));
      await replyTo(t, 'v1');
      expect(
        inBar(videoPreview),
        findsOneWidget,
        reason: 'bar shows ${words(t, byKey('reply-bar'))}',
      );
      expect(inBar('Beach day'), findsNothing);
    });

    testWidgets('control: replying to a pdf shows no 🎥 Video', (t) async {
      await pumpVideoChat(t, world()..messagesResult = Ok([fileMessage('f1')]));
      await replyTo(t, 'f1');
      expect(inBar(videoPreview), findsNothing);
    });

    testWidgets('a reply bubble quotes the video as 🎥 Video', (t) async {
      await pumpVideoChat(
        t,
        world()
          ..messagesResult = Ok([
            video,
            Message(
              id: 'r1',
              conversationId: 'c1',
              senderId: 'u2',
              body: 'nice',
              createdAt: DateTime.now(),
              replyTo: 'v1',
            ),
          ]),
      );
      final r1 = byKey('message-r1');
      expect(r1, findsOneWidget);
      expect(
        find.descendant(of: r1, matching: find.textContaining(videoPreview)),
        findsOneWidget,
        reason: 'bubble shows ${words(t, r1)}',
      );
      expect(
        find.descendant(of: r1, matching: find.textContaining('Beach day')),
        findsNothing,
      );
    });
  });

  group('strings EN and TR', () {
    test('non‑empty strings', () {
      final enProps = <String Function()>[
        () => l10nEn.videoReviewTitle,
        () => l10nEn.videoSendCount(3),
        () => l10nEn.videoCompressing(42),
        () => l10nEn.videoSending(42),
        () => l10nEn.videoWaitingNetwork,
        () => l10nEn.videoWaiting,
        () => l10nEn.videoCancelSend,
        () => l10nEn.videoTooLong(1),
        () => l10nEn.videoTooLong(3),
        () => l10nEn.videoTooBig,
        () => l10nEn.videoFailed,
        () => l10nEn.videoShare,
        () => l10nEn.videoClose,
        () => l10nEn.videoMute,
        () => l10nEn.videoUnmute,
        () => l10nEn.videoPlay,
        () => l10nEn.videoPause,
        () => l10nEn.videoCannotPlay,
        () => l10nEn.videoSelectLabel,
      ];

      final trProps = <String Function()>[
        () => l10nTr.videoReviewTitle,
        () => l10nTr.videoSendCount(3),
        () => l10nTr.videoCompressing(42),
        () => l10nTr.videoSending(42),
        () => l10nTr.videoWaitingNetwork,
        () => l10nTr.videoWaiting,
        () => l10nTr.videoCancelSend,
        () => l10nTr.videoTooLong(1),
        () => l10nTr.videoTooLong(3),
        () => l10nTr.videoTooBig,
        () => l10nTr.videoFailed,
        () => l10nTr.videoShare,
        () => l10nTr.videoClose,
        () => l10nTr.videoMute,
        () => l10nTr.videoUnmute,
        () => l10nTr.videoPlay,
        () => l10nTr.videoPause,
        () => l10nTr.videoCannotPlay,
        () => l10nTr.videoSelectLabel,
      ];

      for (final fn in enProps) {
        expect(fn(), isNotEmpty);
      }
      for (final fn in trProps) {
        expect(fn(), isNotEmpty);
      }
    });

    test('specific values and pluralisation', () {
      // English specific values
      expect(l10nEn.videoReviewTitle, equals('Videos'));
      expect(l10nEn.videoSendCount(3), equals('Send (3)'));
      expect(l10nEn.videoCompressing(42), equals('Compressing 42%'));
      expect(l10nEn.videoSending(42), equals('Sending 42%'));
      expect(l10nEn.videoWaitingNetwork, equals('Waiting for network'));
      expect(l10nEn.videoTooLong(1), isNot(equals(l10nEn.videoTooLong(3))));
      expect(l10nEn.videoTooLong(3), contains('3'));

      // Turkish specific values
      expect(l10nTr.videoCompressing(42), contains('42'));
      expect(l10nTr.videoSending(42), contains('42'));
      expect(l10nTr.videoTooLong(1), isNot(equals(l10nTr.videoTooLong(3))));
      expect(l10nTr.videoTooLong(3), contains('3'));

      // Language differences
      expect(l10nTr.videoReviewTitle, isNot(equals(l10nEn.videoReviewTitle)));
      expect(l10nTr.videoTooBig, isNot(equals(l10nEn.videoTooBig)));
      expect(l10nTr.videoFailed, isNot(equals(l10nEn.videoFailed)));
      expect(l10nTr.videoCannotPlay, isNot(equals(l10nEn.videoCannotPlay)));
      expect(
        l10nTr.videoWaitingNetwork,
        isNot(equals(l10nEn.videoWaitingNetwork)),
      );
      expect(l10nTr.videoMute, isNot(equals(l10nEn.videoMute)));
    });
  });
}
