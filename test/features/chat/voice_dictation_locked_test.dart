import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

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

bool _shownInFull(WidgetTester t, String words) {
  for (final obj in t.allRenderObjects) {
    if (obj is RenderParagraph) {
      final text = obj.text.toPlainText();
      if (!text.contains(words)) continue;
      if (obj.didExceedMaxLines) continue;
      RenderObject? parent = obj.parent;
      bool invisible = false;
      while (parent != null) {
        if (parent is RenderOpacity && parent.opacity == 0) {
          invisible = true;
          break;
        }
        if (parent is RenderAnimatedOpacity && parent.opacity.value == 0) {
          invisible = true;
          break;
        }
        parent = parent.parent;
      }
      if (!invisible) return true;
    }
  }
  return false;
}

const _long =
    'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty';

void main() {
  group('Dictation after the lock swipe', () {
    testWidgets('held: words go into the box and show in full', (
      WidgetTester t,
    ) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: VoiceRecorderFake(), dictation: dict),
      );
      await t.tap(byKey('composer-voice'));
      await frames(t);
      expect(byKey('voice-mode-dictation'), findsOneWidget);

      final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
      await t.pump(const Duration(milliseconds: 200));
      await frames(t);

      dict.hear(_long);
      await frames(t);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.held);
      expect(_composerFieldText(t), _long);
      expect(
        _shownInFull(t, _long),
        isTrue,
        reason: 'held dictation shows every word',
      );

      await g.up();
      await frames(t);
      await noticeGone(t);
    });

    testWidgets('locked: words keep going into the message box', (
      WidgetTester t,
    ) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: VoiceRecorderFake(), dictation: dict),
      );
      await t.tap(byKey('composer-voice'));
      await frames(t);
      expect(byKey('voice-mode-dictation'), findsOneWidget);

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

      dict.hear('one two');
      await frames(t);
      dict.hear(_long);
      await frames(t);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.locked);
      expect(dict.calls, ['start']);
      expect(_composerFieldText(t), _long);

      await t.tap(byKey('voice-circle-send'));
      await frames(t);
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);
      expect(_composerFieldText(t), _long);
      await noticeGone(t);
    });

    testWidgets('locked: the latest words stay visible', (
      WidgetTester t,
    ) async {
      final devices = DeviceFilesFake();
      final repo = FileRepoFake(devices: devices);
      final dict = DictationFake();
      final container = await pumpVideoChat(
        t,
        world(),
        repo: repo,
        devices: devices,
        extra: voiceOverrides(recorder: VoiceRecorderFake(), dictation: dict),
      );
      await t.tap(byKey('composer-voice'));
      await frames(t);
      expect(byKey('voice-mode-dictation'), findsOneWidget);

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

      dict.hear(_long);
      await frames(t);
      expect(
        _shownInFull(t, _long),
        isTrue,
        reason: 'after the lock the member must still see every recognised word, including the newest ones',
      );

      await t.tap(byKey('voice-circle-send'));
      await frames(t);
      await noticeGone(t);
    });
  });
}
