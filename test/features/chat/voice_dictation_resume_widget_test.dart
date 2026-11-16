// locked dictation: pause then resume through the button above the circle

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
  group('Dictation pause button while locked', () {
    testWidgets(
      'locked dictation: a second tap on the pause button resumes the engine and appends words',
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
          reason: 'locked dictation shows the pause button above the circle',
        );

        // First tap: pause
        await t.tap(byKey('voice-pause-button'));
        await frames(t);

        expect(
          container.read(voiceCaptureProvider).paused,
          isTrue,
          reason: 'paused flag should be true after first tap',
        );
        expect(
          dict.calls.where((c) => c == 'stop').length,
          greaterThanOrEqualTo(1),
          reason: 'stop should have been called at least once',
        );
        expect(
          byKey('voice-resume-icon'),
          findsOneWidget,
          reason: 'resume icon should appear when paused',
        );
        expect(
          container.read(voiceCaptureProvider).phase,
          VoicePhase.locked,
          reason: 'phase should remain locked',
        );
        expect(
          _composerFieldText(t),
          'one two three',
          reason: 'text should remain unchanged after pause',
        );

        final starts = dict.calls.where((c) => c == 'start').length;

        // Second tap: resume
        await t.tap(byKey('voice-pause-button'));
        await frames(t);

        expect(
          dict.calls.where((c) => c == 'start').length,
          starts + 1,
          reason: 'start should be called once more after resume',
        );
        expect(
          container.read(voiceCaptureProvider).paused,
          isFalse,
          reason: 'paused flag should be false after resume',
        );
        expect(
          byKey('voice-pause-icon'),
          findsOneWidget,
          reason: 'pause icon should reappear when running',
        );

        // Hear new words
        dict.hear('four');
        await frames(t);

        final text = _composerFieldText(t);
        expect(
          text,
          contains('one two three'),
          reason: 'text should contain previous words',
        );
        expect(text, contains('four'), reason: 'text should contain new words');
        expect(
          text.indexOf('one two three'),
          lessThan(text.indexOf('four')),
          reason: 'previous words should come before new words',
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
