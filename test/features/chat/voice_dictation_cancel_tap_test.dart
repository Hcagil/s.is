import 'package:flutter/material.dart';
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

const _long =
    'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty';

void main() {
  group('Cancel in locked dictation', () {
    testWidgets('locked: a tap on the middle of Cancel cancels the dictation', (
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

      // Lock: start gesture at center, pump 200ms, move up 8 times
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

      // Dictate long text
      dict.hear(_long);
      await frames(t);

      // Ensure Cancel center is reachable
      expect(
        byKey('voice-cancel').hitTestable(),
        findsOneWidget,
        reason:
            'the middle of Cancel must not be covered by the live text preview',
      );

      // Tap Cancel
      await t.tap(byKey('voice-cancel'), warnIfMissed: true);
      await frames(t);

      // Verify cancellation
      expect(container.read(voiceCaptureProvider).phase, VoicePhase.idle);
      expect(dict.calls, contains('cancel'));
      expect(_composerFieldText(t), '');

      await noticeGone(t);
    });
  });
}
