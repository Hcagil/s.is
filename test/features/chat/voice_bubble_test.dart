import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/voice.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_chat.dart';
import '../../support/voice_fakes.dart';
import '../../support/file_fakes.dart';

/// Helper to create a voice message.
Message voice(String id, {String? transcript, DateTime? at}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: '',
  createdAt: at ?? DateTime(2026, 10, 9, 10),
  attachmentPath: 'c1/$id/Note.m4a',
  file: AttachedFile(
    name: 'Note.m4a',
    mime: voiceMime,
    size: 9000,
    durationMs: 41000,
    waveform: '0123456789abcdef0123456789abcdef01234567',
    transcript: transcript,
  ),
);

void main() {
  group('Voice bubble widget tests', () {
    testWidgets('1. Voice message shows bubble and duration', (
      WidgetTester t,
    ) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1');
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: factory),
      );

      await frames(t);

      expect(find.byKey(const ValueKey('voice-v1')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-wave-v1')), findsOneWidget);
      expect(find.text('0:41'), findsOneWidget);

      await noticeGone(t);
    });

    testWidgets('2. Tap play opens and plays', (WidgetTester t) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1');
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: factory),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);
      expect(factory.made.isNotEmpty, true);
      final last = factory.made.last;
      expect(last.calls, contains('open'));
      expect(last.calls, contains('play'));
      expect(last.openedPath, '/app/files/v1/Note.m4a');

      await noticeGone(t);
    });

    testWidgets('3. Speed cycle', (WidgetTester t) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1');
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: factory),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);

      // First tap: 1.5x
      await t.tap(find.byKey(const ValueKey('voice-speed-v1')));
      await frames(t);
      expect(
        find.descendant(
          of: byKey('voice-speed-v1'),
          matching: find.text('1.5x'),
        ),
        findsOneWidget,
      );
      expect(factory.made.last.calls, contains('speed:1.5'));

      // Second tap: 2x
      await t.tap(find.byKey(const ValueKey('voice-speed-v1')));
      await frames(t);
      expect(
        find.descendant(of: byKey('voice-speed-v1'), matching: find.text('2x')),
        findsOneWidget,
      );
      expect(factory.made.last.calls, contains('speed:2.0'));

      // Third tap: back to 1x
      await t.tap(find.byKey(const ValueKey('voice-speed-v1')));
      await frames(t);
      expect(
        find.descendant(of: byKey('voice-speed-v1'), matching: find.text('1x')),
        findsOneWidget,
      );
      expect(factory.made.last.calls, contains('speed:1.0'));

      await noticeGone(t);
    });

    testWidgets('4. Auto‑play next message', (WidgetTester t) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg1 = voice('v1', at: DateTime(2026, 10, 9, 10));
      final msg2 = voice('v2', at: DateTime(2026, 10, 9, 11));
      chat.messagesResult = Ok([msg1, msg2]);
      devices.written.addAll([
        '/app/files/v1/Note.m4a',
        '/app/files/v2/Note.m4a',
      ]);

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: factory),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);
      // Finish first playback
      factory.made.last.finish(const Duration(seconds: 41));
      await frames(t);
      await frames(t);

      expect(
        factory.made.any(
          (p) =>
              p.openedPath == '/app/files/v2/Note.m4a' &&
              p.calls.contains('play'),
        ),
        isTrue,
      );

      await noticeGone(t);
    });

    testWidgets('5. Speed carries to next message', (WidgetTester t) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg1 = voice('v1', at: DateTime(2026, 10, 9, 10));
      final msg2 = voice('v2', at: DateTime(2026, 10, 9, 11));
      chat.messagesResult = Ok([msg1, msg2]);
      devices.written.addAll([
        '/app/files/v1/Note.m4a',
        '/app/files/v2/Note.m4a',
      ]);

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: factory),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);

      // Set speed to 1.5x before finish
      await t.tap(find.byKey(const ValueKey('voice-speed-v1')));
      await frames(t);
      // Finish first playback
      factory.made.last.finish(const Duration(seconds: 41));
      await frames(t);
      await frames(t);

      // The next playback should have speed 1.5
      final nextPlayback = factory.made.last;
      expect(nextPlayback.speed, 1.5);
      expect(nextPlayback.calls, contains('speed:1.5'));

      await noticeGone(t);
    });

    testWidgets('6. Played message is skipped', (WidgetTester t) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg1 = voice('v1', at: DateTime(2026, 10, 9, 10));
      final msg2 = voice('v2', at: DateTime(2026, 10, 9, 11));
      chat.messagesResult = Ok([msg1, msg2]);
      devices.written.addAll([
        '/app/files/v1/Note.m4a',
        '/app/files/v2/Note.m4a',
      ]);

      final factory = VoicePlaybackFactoryFake();
      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(
          playback: factory,
          played: PlayedVoiceStoreFake({'v2'}),
        ),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);
      // Finish first playback
      factory.made.last.finish(const Duration(seconds: 41));
      await frames(t);
      await frames(t);

      expect(
        factory.made.any((p) => p.openedPath == '/app/files/v2/Note.m4a'),
        isFalse,
      );

      await noticeGone(t);
    });

    testWidgets('7. No transcript shows no toggle or transcript', (
      WidgetTester t,
    ) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1', transcript: null);
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      await pumpVideoChat(t, chat, devices: devices, extra: voiceOverrides());

      await frames(t);

      expect(find.byKey(const ValueKey('voice-text-toggle-v1')), findsNothing);
      expect(find.byKey(const ValueKey('voice-transcript-v1')), findsNothing);

      await noticeGone(t);
    });

    testWidgets('8. Transcript toggle shows/hides transcript', (
      WidgetTester t,
    ) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1', transcript: 'hello world');
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      await pumpVideoChat(t, chat, devices: devices, extra: voiceOverrides());

      await frames(t);

      expect(
        find.byKey(const ValueKey('voice-text-toggle-v1')),
        findsOneWidget,
      );
      expect(find.text('Show text'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('voice-text-toggle-v1')));
      await frames(t);

      expect(find.text('hello world'), findsOneWidget);
      expect(find.text('Hide text'), findsOneWidget);

      await noticeGone(t);
    });

    testWidgets('9. Cannot play when playback factory fails to open', (
      WidgetTester t,
    ) async {
      final chat = world();
      final devices = DeviceFilesFake();
      final msg = voice('v1');
      chat.messagesResult = Ok([msg]);
      devices.written.add('/app/files/v1/Note.m4a');

      await pumpVideoChat(
        t,
        chat,
        devices: devices,
        extra: voiceOverrides(playback: VoicePlaybackFactoryFake(opens: false)),
      );

      await frames(t);

      await t.tap(find.byKey(const ValueKey('voice-play-v1')));
      await frames(t);

      expect(find.text('This voice message cannot be played.'), findsOneWidget);

      await noticeGone(t);
    });
  });

  test('10. previewText and localization', () {
    final msg = voice('v1', transcript: 'secret');
    final preview = previewText(msg);
    expect(preview, voicePreview);
    expect(preview.contains('secret'), isFalse);

    final tr = lookupAppLocalizations(const Locale('tr')).voicePreviewLine;
    final en = lookupAppLocalizations(const Locale('en')).voicePreviewLine;
    expect(tr, '🎤 Sesli mesaj');
    expect(en, '🎤 Voice message');
  });
}
