import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/voice.dart';

import '../../support/file_fakes.dart';
import '../../support/video_chat.dart';
import '../../support/voice_fakes.dart';

String _composerFieldText(WidgetTester t) {
  final finder = find.descendant(
    of: byKey('composer-field'),
    matching: find.byType(TextField),
  );
  if (finder.evaluate().isNotEmpty) {
    return t.widget<TextField>(finder).controller!.text;
  }
  return t.widget<TextField>(byKey('composer-field')).controller!.text;
}

void main() {
  group('Voice button', () {
    testWidgets('tap switches mode', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final voiceBtn = byKey('composer-voice');
      await t.tap(voiceBtn);
      await frames(t);
      expect(byKey('voice-mode-dictation'), findsOneWidget);
      await t.tap(voiceBtn);
      await frames(t);
      expect(byKey('voice-mode-voice'), findsOneWidget);
      expect(rec.calls, isEmpty);

      await noticeGone(t);
    });

    testWidgets('hold + release sends', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t); // now held
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.held);
      expect(byKey('voice-bar'), findsOneWidget);
      expect(byKey('voice-timer'), findsOneWidget);

      await g.up();
      await frames(t);

      expect(repo.sends.length, 1);
      final file = repo.sends.first.file;
      expect(file.mime, 'audio/mp4');
      expect(file.durationMs, 4200);
      expect(byKey('voice-bar'), findsNothing);
      expect(byKey('voice-timer'), findsNothing);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);
      expect(rec.calls, contains('stop'));

      await noticeGone(t);
    });

    testWidgets('slide left cancels', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t); // held

      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(-20, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await frames(t);

      expect(repo.sends, isEmpty);
      expect(rec.calls, contains('cancel'));
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('short slide left still sends', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t); // held

      for (var i = 0; i < 2; i++) {
        await g.moveBy(const Offset(-20, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await frames(t);

      expect(repo.sends.length, 1);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('swipe up locks and sends on tap', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t); // held

      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -10));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await frames(t);

      expect(container.read(voiceCaptureProvider).phase, VoicePhase.locked);
      expect(byKey('voice-cancel'), findsOneWidget);
      expect(byKey('voice-circle-send'), findsOneWidget);
      expect(repo.sends, isEmpty);

      await t.tap(byKey('voice-circle-send'));
      await frames(t);

      expect(repo.sends.length, 1);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('locked then tap cancel', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      // Lock first
      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t);
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -10));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await frames(t);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.locked);

      await t.tap(byKey('voice-cancel'));
      await frames(t);

      expect(rec.calls, contains('cancel'));
      expect(repo.sends, isEmpty);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('locked: composer-attach ignored', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      // Lock
      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t);
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -10));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await frames(t);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.locked);

      await t.tap(byKey('composer-attach'), warnIfMissed: false);
      await frames(t);
      expect(byKey('attach-menu'), findsNothing);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.locked);
      await t.tap(byKey('voice-cancel'));
      await frames(t);

      await noticeGone(t);
    });

    testWidgets('move left before hold does not record', (
      WidgetTester t,
    ) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 2; i++) {
        await g.moveBy(const Offset(-20, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await t.pump(const Duration(milliseconds: 200));
      await g.up();
      await frames(t);

      expect(rec.calls.where((c) => c.startsWith('start:')), isEmpty);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);
      expect(repo.sends, isEmpty);

      await noticeGone(t);
    });

    testWidgets('too short recording yields no send', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake(nothingUsable: true);
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t);
      await g.up();
      await frames(t);

      expect(repo.sends, isEmpty);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('denied microphone shows notice', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake(startResult: VoiceStart.denied);
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      // The notice shows for about 2 s, so look while it is up.
      expect(
        find.text('Allow the microphone in Settings to record.'),
        findsOneWidget,
      );
      await g.up();
      await frames(t);
      expect(repo.sends, isEmpty);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);

      await noticeGone(t);
    });

    testWidgets('dictation mode captures text', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      // Switch to dictation
      await t.tap(byKey('composer-voice'));
      await frames(t);
      expect(byKey('voice-mode-dictation'), findsOneWidget);

      // Hold to start dictation
      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t);
      expect(byKey('voice-dictation-card'), findsOneWidget);

      // Simulate dictation input
      dict.hear('hello there');
      await t.pump();
      await g.up();
      await frames(t);

      expect(_composerFieldText(t), 'hello there');
      expect(repo.sends, isEmpty);
      expect(rec.calls, isEmpty);

      await noticeGone(t);
    });

    testWidgets('typing text hides voice button', (WidgetTester t) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final rec = VoiceRecorderFake();
      final dict = DictationFake();
      await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: rec, dictation: dict),
      );

      await t.enterText(byKey('composer-field'), 'hi');
      await frames(t);

      expect(byKey('composer-voice'), findsNothing);
      expect(byKey('composer-send'), findsOneWidget);

      await noticeGone(t);
    });
  });
}
