// tester bug, iPhone, app 26.11.330: after the lock swipe in dictation mode, the stop button shown above the circle does nothing when tapped.

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

void main() {
  group('Dictation stop button while locked', () {
    testWidgets(
      'locked dictation: the stop button above the circle stops the speech engine and keeps the words',
      (WidgetTester t) async {
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

        dict.hear('one two three');
        await frames(t);

        expect(
          byKey('voice-pause-button'),
          findsOneWidget,
          reason: 'locked dictation shows the stop button above the circle',
        );

        final center = t.getCenter(byKey('voice-pause-button'));
        final hit = t.hitTestOnBinding(center);
        final target = t.renderObject(byKey('voice-pause-button'));
        expect(
          hit.path.any((e) => e.target == target),
          isTrue,
          reason: 'a tap on the stop button must reach it, not a widget drawn over it',
        );

        await t.tap(byKey('voice-pause-button'));
        await frames(t);

        expect(
          dict.calls.skip(1).any((c) => c == 'stop' || c == 'cancel'),
          isTrue,
          reason:
              'the stop-dictation button must stop the speech engine; engine calls: ${dict.calls}, phase: ${container.read(voiceCaptureProvider).phase}',
        );

        expect(
          _composerFieldText(t),
          'one two three',
          reason: 'stopping keeps the dictated words in the message box',
        );

        if (byKey('voice-circle-send').evaluate().isNotEmpty) {
          await t.tap(byKey('voice-circle-send'), warnIfMissed: false);
          await frames(t);
        }
        await noticeGone(t);
      },
    );
  });
}
