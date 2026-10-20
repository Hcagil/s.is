// Pause and resume of a locked voice recording, from the contract only.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';

import '../../support/file_fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';
import '../../support/voice_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> settle(WidgetTester t) async {
  await hop(t);
  await t.pump(const Duration(milliseconds: 60));
  await hop(t);
}

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump();
  }
}

Future<ProviderContainer> start(
  WidgetTester t,
  HeldSendChat chat,
  FileRepoFake files,
  VoiceRecorderFake rec,
  VoiceTranscriberFake tr,
  DictationFake dict,
) async {
  final devices = DeviceFilesFake();
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      ...voiceOverrides(recorder: rec, transcriber: tr, dictation: dict),
      chatRepositoryProvider.overrideWithValue(chat),
      chatFileRepositoryProvider.overrideWithValue(files),
      deviceFilesProvider.overrideWithValue(devices),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(voiceCaptureProvider, (_, _) {});
  c.listen(draftsProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  expect(c.read(sessionControllerProvider).value, isA<Allowed>());
  return c;
}

void main() {
  testWidgets('pause while locked', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.locked);
    final pauseFuture = notifier.pause();
    expect(c.read(voiceCaptureProvider).paused, true);
    await settle(t);
    await pauseFuture;
    expect(rec.calls, contains('pause'));
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, true);
    expect(c.read(voiceCaptureProvider).notice, isNull);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('resume after pause', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, true);
    final resumeFuture = notifier.resume();
    expect(c.read(voiceCaptureProvider).paused, false);
    await settle(t);
    await resumeFuture;
    expect(rec.calls, contains('resume'));
    expect(c.read(voiceCaptureProvider).notice, isNull);
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, false);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('pause when held (not locked)', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    final pauseFuture = notifier.pause();
    await settle(t);
    await pauseFuture;
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(rec.calls, isNot(contains('pause')));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('pause in dictation mode', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    notifier.toggleMode(); // dictation
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    final pauseFuture = notifier.pause();
    await settle(t);
    await pauseFuture;
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(rec.calls, isNot(contains('pause')));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('pause when already paused', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    final pauseFuture = notifier.pause();
    await settle(t);
    await pauseFuture;
    await settle(t);
    expect(rec.calls.where((c) => c == 'pause').length, 1);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('plain VoiceRecorderFake pause does nothing', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    final pauseFuture = notifier.pause();
    await settle(t);
    await pauseFuture;
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(rec.calls, isNot(contains('pause')));
    final resumeFuture = notifier.resume();
    await settle(t);
    await resumeFuture;
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(rec.calls, isNot(contains('resume')));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('resume when not paused does nothing', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    final resumeFuture = notifier.resume();
    await settle(t);
    await resumeFuture;
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(rec.calls, isNot(contains('resume')));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('elapsedMs frozen while paused', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pump(const Duration(milliseconds: 120));
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    await settle(t);
    final v = c.read(voiceCaptureProvider).elapsedMs;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(c.read(voiceCaptureProvider).elapsedMs, v);
    unawaited(notifier.resume());
    await settle(t);
    await settle(t);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(c.read(voiceCaptureProvider).elapsedMs, greaterThan(v));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('pause fails (pauseOk:false)', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake(pauseOk: false);
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, false);
    expect(c.read(voiceCaptureProvider).notice, VoiceNotice.micFailed);
    final v = c.read(voiceCaptureProvider).elapsedMs;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(c.read(voiceCaptureProvider).elapsedMs, greaterThan(v));
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('resume fails (resumeOk:false)', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake(resumeOk: false);
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    await settle(t);
    unawaited(notifier.resume());
    await settle(t);
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, true);
    expect(c.read(voiceCaptureProvider).notice, VoiceNotice.micFailed);
    final v = c.read(voiceCaptureProvider).elapsedMs;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(c.read(voiceCaptureProvider).elapsedMs, v);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('finish while paused', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    unawaited(notifier.finish());
    await settle(t);
    await settle(t);
    expect(files.sends.length, 1);
    expect(rec.calls, contains('stop'));
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    expect(c.read(voiceCaptureProvider).paused, false);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('cancel while paused', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = PausableVoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    notifier.lock();
    unawaited(notifier.pause());
    await settle(t);
    unawaited(notifier.cancel());
    await settle(t);
    await settle(t);
    expect(rec.calls, contains('cancel'));
    expect(files.sends.isEmpty, true);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    expect(c.read(voiceCaptureProvider).paused, false);
    // start again
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    expect(c.read(voiceCaptureProvider).paused, false);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });
}
