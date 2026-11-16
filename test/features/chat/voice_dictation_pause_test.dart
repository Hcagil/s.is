// Locked dictation pause tests – contract only.
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
  group('locked dictation pause', () {
    testWidgets('0 pause stops the engine, keeps text and bar', (
      WidgetTester t,
    ) async {
      final chat = HeldSendChat();
      final files = FileRepoFake();
      final rec = PausableVoiceRecorderFake();
      final tr = VoiceTranscriberFake();
      final dict = DictationFake();
      final c = await start(t, chat, files, rec, tr, dict);
      final notifier = c.read(voiceCaptureProvider.notifier);
      notifier.toggleMode(); // dictation
      c.read(draftsProvider.notifier).setText('c1', 'Hi');
      unawaited(notifier.begin('c1', 'en_US'));
      await settle(t);
      notifier.lock();
      expect(c.read(voiceCaptureProvider).phase, VoicePhase.locked);
      await settle(t);
      dict.hear('one two');
      await hop(t);
      final pauseFuture = notifier.pause();
      expect(c.read(voiceCaptureProvider).paused, true);
      await settle(t);
      await pauseFuture;
      expect(dict.calls, contains('stop'));
      final text = c.read(draftsProvider.notifier).draftFor('c1').text;
      expect(text, contains('one two'));
      expect(text.startsWith('Hi'), true);
      unawaited(notifier.cancel());
      await settle(t);
      await t.pump(const Duration(minutes: 11));
    });

    testWidgets('a resume appends new words', (WidgetTester t) async {
      final chat = HeldSendChat();
      final files = FileRepoFake();
      final rec = PausableVoiceRecorderFake();
      final tr = VoiceTranscriberFake();
      final dict = DictationFake();
      final c = await start(t, chat, files, rec, tr, dict);
      final notifier = c.read(voiceCaptureProvider.notifier);
      notifier.toggleMode();
      c.read(draftsProvider.notifier).setText('c1', 'Hi');
      unawaited(notifier.begin('c1', 'en_US'));
      await settle(t);
      notifier.lock();
      await settle(t);
      dict.hear('one two');
      await hop(t);
      final pauseFuture = notifier.pause();
      await settle(t);
      await pauseFuture;
      await settle(t);
      final resumeFuture = notifier.resume();
      expect(c.read(voiceCaptureProvider).paused, false);
      await settle(t);
      await resumeFuture;
      expect(dict.calls.where((c) => c == 'start').length, 2);
      dict.hear('three');
      await hop(t);
      final text = c.read(draftsProvider.notifier).draftFor('c1').text;
      expect(text.contains('one two'), true);
      expect(text.contains('three'), true);
      expect(text.indexOf('one two') < text.indexOf('three'), true);
      expect('one two'.allMatches(text).length, 1);
      unawaited(notifier.cancel());
      await settle(t);
      await t.pump(const Duration(minutes: 11));
    });

    testWidgets('b engine end signal while paused keeps the bar', (
      WidgetTester t,
    ) async {
      final chat = HeldSendChat();
      final files = FileRepoFake();
      final rec = PausableVoiceRecorderFake();
      final tr = VoiceTranscriberFake();
      final dict = DictationFake();
      final c = await start(t, chat, files, rec, tr, dict);
      final notifier = c.read(voiceCaptureProvider.notifier);
      notifier.toggleMode();
      c.read(draftsProvider.notifier).setText('c1', 'Hi');
      unawaited(notifier.begin('c1', 'en_US'));
      await settle(t);
      notifier.lock();
      await settle(t);
      dict.hear('one two');
      await hop(t);
      final pauseFuture = notifier.pause();
      await settle(t);
      await pauseFuture;
      await settle(t);
      dict.endByItself();
      await settle(t);
      expect(c.read(voiceCaptureProvider).phase, VoicePhase.locked);
      expect(c.read(voiceCaptureProvider).paused, true);
      unawaited(notifier.cancel());
      await settle(t);
      await t.pump(const Duration(minutes: 11));
    });

    testWidgets(
      'c resume with failed start stays paused and shows the notice',
      (WidgetTester t) async {
        final chat = HeldSendChat();
        final files = FileRepoFake();
        final rec = PausableVoiceRecorderFake();
        final tr = VoiceTranscriberFake();
        final dict = DictationFake();
        final c = await start(t, chat, files, rec, tr, dict);
        final notifier = c.read(voiceCaptureProvider.notifier);
        notifier.toggleMode();
        c.read(draftsProvider.notifier).setText('c1', 'Hi');
        unawaited(notifier.begin('c1', 'en_US'));
        await settle(t);
        notifier.lock();
        await settle(t);
        dict.hear('one two');
        await hop(t);
        final pauseFuture = notifier.pause();
        await settle(t);
        await pauseFuture;
        await settle(t);
        dict.startResult = VoiceStart.failed;
        final resumeFuture = notifier.resume();
        await settle(t);
        await resumeFuture;
        expect(c.read(voiceCaptureProvider).paused, true);
        expect(
          c.read(voiceCaptureProvider).notice,
          VoiceNotice.dictationUnavailable,
        );
        expect(c.read(voiceCaptureProvider).phase, VoicePhase.locked);
        unawaited(notifier.cancel());
        await settle(t);
        await t.pump(const Duration(minutes: 11));
      },
    );

    testWidgets(
      'd cancel after pause restores the text from before dictation',
      (WidgetTester t) async {
        final chat = HeldSendChat();
        final files = FileRepoFake();
        final rec = PausableVoiceRecorderFake();
        final tr = VoiceTranscriberFake();
        final dict = DictationFake();
        final c = await start(t, chat, files, rec, tr, dict);
        final notifier = c.read(voiceCaptureProvider.notifier);
        notifier.toggleMode();
        c.read(draftsProvider.notifier).setText('c1', 'Hi');
        unawaited(notifier.begin('c1', 'en_US'));
        await settle(t);
        notifier.lock();
        await settle(t);
        dict.hear('one two');
        await hop(t);
        final pauseFuture = notifier.pause();
        await settle(t);
        await pauseFuture;
        await settle(t);
        unawaited(notifier.cancel());
        await settle(t);
        final text = c.read(draftsProvider.notifier).draftFor('c1').text;
        expect(text, 'Hi');
        expect(c.read(voiceCaptureProvider).phase, VoicePhase.idle);
        // No further cancel to avoid double cancel.
      },
    );
  });
}
