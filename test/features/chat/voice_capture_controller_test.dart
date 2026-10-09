import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/voice.dart';

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
  testWidgets('initial state', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final state = c.read(voiceCaptureProvider);
    expect(state.mode, VoiceMode.voice);
    expect(state.phase, VoicePhase.idle);
    expect(state.elapsedMs, 0);
    expect(state.notice, isNull);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('toggleMode when idle', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    notifier.toggleMode();
    expect(c.read(voiceCaptureProvider).mode, VoiceMode.dictation);
    notifier.toggleMode();
    expect(c.read(voiceCaptureProvider).mode, VoiceMode.voice);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('begin in voice mode starts recording', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.held);
    expect(rec.calls.where((c) => c.startsWith('start:')), hasLength(1));
    notifier.toggleMode(); // should not change mode
    expect(c.read(voiceCaptureProvider).mode, VoiceMode.voice);
    unawaited(notifier.cancel());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('hold 1s then finish sends file', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    expect(files.sends.length, 1);
    final send = files.sends[0];
    expect(send.conversationId, 'c1');
    expect(send.file.mime, 'audio/mp4');
    expect(send.file.durationMs, 4200);
    expect(send.file.waveform, '0123456789abcdef0123456789abcdef01234567');
    expect(send.file.transcript, isNull);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('transcriber words trimmed', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake(words: '  hello  ');
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    final send = files.sends[0];
    expect(send.file.transcript, 'hello');
    expect(tr.asked.single.$2, 'en_US');
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('rec.nothingUsable true -> tooShort', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake(nothingUsable: true);
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    final state = c.read(voiceCaptureProvider);
    expect(state.notice, VoiceNotice.tooShort);
    expect(files.sends.isEmpty, true);
    notifier.consumeNotice();
    expect(c.read(voiceCaptureProvider).notice, isNull);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('rec.startResult denied -> micDenied', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake(startResult: VoiceStart.denied);
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await hop(t);
    final state = c.read(voiceCaptureProvider);
    expect(state.notice, VoiceNotice.micDenied);
    expect(state.phase, VoicePhase.idle);
    expect(files.sends.isEmpty, true);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('rec.startResult failed -> micFailed', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake(startResult: VoiceStart.failed);
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await hop(t);
    final state = c.read(voiceCaptureProvider);
    expect(state.notice, VoiceNotice.micFailed);
    expect(state.phase, VoicePhase.idle);
    expect(files.sends.isEmpty, true);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('hold then cancel', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.cancel());
    await settle(t);
    expect(rec.calls, contains('cancel'));
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    expect(files.sends.isEmpty, true);
    expect(c.read(voiceCaptureProvider).notice, isNull);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('lock during hold then finish', (WidgetTester t) async {
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
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.locked);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    expect(files.sends.length, 1);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('elapsedMs grows while held', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump(const Duration(milliseconds: 120));
    expect(c.read(voiceCaptureProvider).elapsedMs, greaterThan(0));
    unawaited(notifier.finish());
    await settle(t);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('dictation mode with draft updates', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    notifier.toggleMode(); // dictation
    final draftNotifier = c.read(draftsProvider.notifier);
    draftNotifier.setText('c1', 'Hi');
    unawaited(notifier.begin('c1', 'tr_TR'));
    await settle(t);
    await hop(t);
    expect(dict.localeTag, 'tr_TR');
    dict.hear('merhaba');
    await hop(t);
    expect(
      c.read(draftsProvider.notifier).draftFor('c1').text,
      contains('merhaba'),
    );
    unawaited(notifier.finish());
    await settle(t);
    await hop(t);
    expect(
      c.read(draftsProvider.notifier).draftFor('c1').text,
      contains('merhaba'),
    );
    expect(files.sends.isEmpty, true);
    expect(rec.calls.isEmpty, true);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('dictation cancel preserves draft', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    notifier.toggleMode(); // dictation
    final draftNotifier = c.read(draftsProvider.notifier);
    draftNotifier.setText('c1', 'Hi');
    unawaited(notifier.begin('c1', 'tr_TR'));
    await settle(t);
    await hop(t);
    dict.hear('merhaba');
    await hop(t);
    unawaited(notifier.cancel());
    await settle(t);
    expect(c.read(draftsProvider.notifier).draftFor('c1').text, 'Hi');
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('dictation startResult failed -> dictationUnavailable', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake(startResult: VoiceStart.failed);
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier)..toggleMode();
    unawaited(notifier.begin('c1', 'tr_TR'));
    await settle(t);
    await hop(t);
    expect(
      c.read(voiceCaptureProvider).notice,
      VoiceNotice.dictationUnavailable,
    );
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('dictation startResult denied -> micDenied', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake();
    final tr = VoiceTranscriberFake();
    final dict = DictationFake(startResult: VoiceStart.denied);
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier)..toggleMode();
    unawaited(notifier.begin('c1', 'tr_TR'));
    await settle(t);
    await hop(t);
    expect(c.read(voiceCaptureProvider).notice, VoiceNotice.micDenied);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('a take under minVoiceMs is dropped as tooShort', (
    WidgetTester t,
  ) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake(
      take: VoiceTake(
        path: '/app/files/v/voice.m4a',
        durationMs: minVoiceMs - 1,
        waveform: '0123456789abcdef0123456789abcdef01234567',
        size: 9000,
      ),
    );
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    expect(c.read(voiceCaptureProvider).notice, VoiceNotice.tooShort);
    expect(files.sends.isEmpty, isTrue);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('a take of exactly minVoiceMs is sent', (WidgetTester t) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final rec = VoiceRecorderFake(
      take: VoiceTake(
        path: '/app/files/v/voice.m4a',
        durationMs: minVoiceMs,
        waveform: '0123456789abcdef0123456789abcdef01234567',
        size: 9000,
      ),
    );
    final tr = VoiceTranscriberFake();
    final dict = DictationFake();
    final c = await start(t, chat, files, rec, tr, dict);
    final notifier = c.read(voiceCaptureProvider.notifier);
    unawaited(notifier.begin('c1', 'en_US'));
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    unawaited(notifier.finish());
    await settle(t);
    expect(files.sends.length, 1);
    expect(files.sends[0].file.durationMs, minVoiceMs);
    expect(c.read(voiceCaptureProvider).notice, isNull);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    await t.pump(const Duration(minutes: 11));
  });

  testWidgets('recording stops by itself at maxVoiceMs', (
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
    await t.pump(const Duration(milliseconds: maxVoiceMs - 1000));
    expect(c.read(voiceCaptureProvider).phase, isNot(VoicePhase.idle));
    expect(files.sends.isEmpty, isTrue);
    await t.pump(const Duration(seconds: 2));
    await settle(t);
    expect(files.sends.length, 1);
    expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
    await t.pump(const Duration(minutes: 11));
  });
}
