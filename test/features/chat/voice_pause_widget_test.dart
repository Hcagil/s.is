// The pause button of a locked voice recording, on the chat screen as
// production mounts it, written from the contract only:
//
//  - `voice-pause-button` shows only while locked; a tap pauses, a second tap
//    resumes (the owner's bug: the tap did nothing). 48x48 tap area, 12 dp
//    above the disc of the 82 dp `voice-circle`.
//  - Icons `voice-pause-icon` (running) / `voice-resume-icon` (paused).
//  - `voice-pill` only while held; `voice-circle-send` sends in both states;
//    `voice-cancel` still cancels while paused.
//  - A failed pause shows "Could not start recording." and the pause icon.
//  - `voice-dot` is solid while paused and blinks otherwise.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

import '../../support/file_fakes.dart';
import '../../support/video_chat.dart';
import '../../support/voice_fakes.dart';

class _Rig {
  _Rig(this.container, this.repo, this.rec);
  final ProviderContainer container;
  final FileRepoFake repo;
  final PausableVoiceRecorderFake rec;
  VoiceCaptureState get state => container.read(voiceCaptureProvider);
}

Future<_Rig> _mount(WidgetTester t, {bool pauseOk = true}) async {
  final devices = DeviceFilesFake();
  final repo = FileRepoFake(devices: devices);
  final rec = PausableVoiceRecorderFake(pauseOk: pauseOk);
  final c = await pumpVideoChat(
    t,
    world(),
    repo: repo,
    devices: devices,
    extra: voiceOverrides(recorder: rec, dictation: DictationFake()),
  );
  return _Rig(c, repo, rec);
}

/// Press and hold the mic until recording; returns the held gesture.
Future<TestGesture> _hold(WidgetTester t) async {
  final g = await t.startGesture(t.getCenter(byKey('composer-voice')));
  await t.pump(const Duration(milliseconds: 200));
  await frames(t);
  return g;
}

/// Swipe up from the hold to lock, as a member does.
Future<void> _lock(WidgetTester t, _Rig r) async {
  final g = await _hold(t);
  for (var i = 0; i < 8; i++) {
    await g.moveBy(const Offset(0, -10));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await frames(t);
  expect(r.state.phase, VoicePhase.locked);
}

/// Product of every opacity on the way from [f] to the root and inside it.
double _opacity(WidgetTester t, Finder f) {
  final el = f.evaluate().single;
  var o = 1.0;
  void take(RenderObject? ro) {
    if (ro is RenderOpacity) o *= ro.opacity;
    if (ro is RenderAnimatedOpacity) o *= ro.opacity.value;
  }

  RenderObject? ro = el.renderObject;
  while (ro != null) {
    take(ro);
    ro = ro.parent;
  }
  void down(Element e) {
    e.visitChildren((c) {
      if (c is RenderObjectElement) take(c.renderObject);
      down(c);
    });
  }

  down(el);
  return o;
}

/// The dot's opacity sampled every 100 ms for 1.4 s.
Future<List<double>> _dotSamples(WidgetTester t) async {
  final out = <double>[];
  for (var i = 0; i < 14; i++) {
    await t.pump(const Duration(milliseconds: 100));
    out.add(_opacity(t, byKey('voice-dot')));
  }
  return out;
}

void main() {
  testWidgets('pause button: absent while held, shown when locked; tap pauses '
      'and a second tap resumes, icons swap, pill gone, labels follow', (
    t,
  ) async {
    final haptics = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add('${call.arguments}');
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final r = await _mount(t);

    final g = await _hold(t);
    expect(r.state.phase, VoicePhase.held);
    expect(byKey('voice-pause-button'), findsNothing, reason: 'held: no pause');
    expect(byKey('voice-pill'), findsOneWidget, reason: 'held: pill shows');
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, -10));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await frames(t);
    expect(r.state.phase, VoicePhase.locked);

    expect(byKey('voice-pause-button'), findsOneWidget);
    expect(byKey('voice-pause-icon'), findsOneWidget);
    expect(byKey('voice-resume-icon'), findsNothing);
    expect(byKey('voice-pill'), findsNothing, reason: 'locked: no pill');
    expect(find.bySemanticsLabel('Pause recording'), findsOneWidget);

    haptics.clear(); // the lock itself may buzz
    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.rec.calls, contains('pause'), reason: 'the tap did nothing');
    expect(r.state.paused, isTrue);
    expect(haptics, contains('HapticFeedbackType.selectionClick'));
    expect(byKey('voice-resume-icon'), findsOneWidget);
    expect(byKey('voice-pause-icon'), findsNothing);
    expect(byKey('voice-pill'), findsNothing, reason: 'paused: no pill');
    expect(find.bySemanticsLabel('Resume recording'), findsOneWidget);

    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.rec.calls, contains('resume'));
    expect(r.state.paused, isFalse);
    expect(r.state.phase, VoicePhase.locked);
    expect(byKey('voice-pause-icon'), findsOneWidget);
    expect(byKey('voice-resume-icon'), findsNothing);

    await t.tap(byKey('voice-cancel'));
    await frames(t);
    await noticeGone(t);
  });

  testWidgets('the whole 48 dp area takes the tap, not only the 40 dp circle; '
      'it sits 12 dp above the disc; the circle box stays 82 dp', (t) async {
    final r = await _mount(t);
    await _lock(t, r);
    expect(t.getSize(byKey('voice-circle')), const Size(82, 82));

    final c = t.getCenter(byKey('voice-circle'));
    final area = t.getRect(byKey('voice-pause-button'));
    expect(area.size, const Size(48, 48));
    expect(area.left, closeTo(c.dx - 24, 0.5));
    expect(area.top, closeTo(c.dy - 84, 0.5), reason: 'running: disc 56');

    // A corner of the tap area lies outside the 40 dp visual circle.
    await t.tapAt(area.topLeft + const Offset(2, 2));
    await frames(t);
    expect(r.state.paused, isTrue, reason: 'corner of the tap area missed');
    expect(t.getSize(byKey('voice-circle')), const Size(82, 82));
    final paused = t.getRect(byKey('voice-pause-button'));
    expect(paused.top, closeTo(c.dy - 76, 0.5), reason: 'paused: disc 40');

    await t.tap(byKey('voice-cancel'));
    await frames(t);
    await noticeGone(t);
  });

  testWidgets('send while paused sends the one recording and ends', (t) async {
    final r = await _mount(t);
    await _lock(t, r);
    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.state.paused, isTrue);

    await t.tap(byKey('voice-circle-send'));
    await frames(t);
    expect(r.repo.sends, hasLength(1));
    expect(r.rec.calls, contains('stop'));
    expect(r.state.phase, VoicePhase.idle);
    expect(r.state.paused, isFalse);
    expect(byKey('voice-pause-button'), findsNothing);
    await noticeGone(t);
  });

  testWidgets('send after pause and resume still sends once', (t) async {
    final r = await _mount(t);
    await _lock(t, r);
    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.state.paused, isFalse);

    await t.tap(byKey('voice-circle-send'));
    await frames(t);
    expect(r.repo.sends, hasLength(1));
    expect(r.state.phase, VoicePhase.idle);
    await noticeGone(t);
  });

  testWidgets('cancel while paused cancels, sends nothing', (t) async {
    final r = await _mount(t);
    await _lock(t, r);
    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.state.paused, isTrue);

    await t.tap(byKey('voice-cancel'));
    await frames(t);
    expect(r.rec.calls, contains('cancel'));
    expect(r.repo.sends, isEmpty);
    expect(r.state.phase, VoicePhase.idle);
    expect(r.state.paused, isFalse);
    await noticeGone(t);
  });

  testWidgets('a failed pause shows the mic notice and the pause icon again', (
    t,
  ) async {
    final r = await _mount(t, pauseOk: false);
    await _lock(t, r);
    await t.tap(byKey('voice-pause-button'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(r.rec.calls, contains('pause'));
    expect(find.text('Could not start recording.'), findsOneWidget);
    await frames(t);
    expect(r.state.paused, isFalse);
    expect(byKey('voice-pause-icon'), findsOneWidget);
    expect(byKey('voice-resume-icon'), findsNothing);

    await t.tap(byKey('voice-cancel'));
    await frames(t);
    await noticeGone(t);
  });

  testWidgets('red dot blinks while recording and is solid while paused', (
    t,
  ) async {
    final r = await _mount(t);
    await _lock(t, r);
    expect(byKey('voice-dot'), findsOneWidget);

    final running = await _dotSamples(t);
    final spread =
        running.reduce((a, b) => a > b ? a : b) -
        running.reduce((a, b) => a < b ? a : b);
    expect(spread, greaterThan(0.3), reason: 'no blink: $running');

    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    expect(r.state.paused, isTrue);
    final paused = await _dotSamples(t);
    expect(paused, everyElement(1.0), reason: 'not solid: $paused');

    await t.tap(byKey('voice-pause-button'));
    await frames(t);
    final again = await _dotSamples(t);
    final spread2 =
        again.reduce((a, b) => a > b ? a : b) -
        again.reduce((a, b) => a < b ? a : b);
    expect(spread2, greaterThan(0.3), reason: 'no blink after resume');

    await t.tap(byKey('voice-cancel'));
    await frames(t);
    await noticeGone(t);
  });
}
