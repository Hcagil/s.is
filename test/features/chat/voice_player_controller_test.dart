import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/voice.dart';

import '../../support/fakes.dart' show settled;
import '../../support/file_fakes.dart';
import '../../support/video_chat.dart' show me, world;
import '../../support/video_fakes.dart';
import '../../support/voice_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Message voice(String id, {DateTime? at, String sender = 'u2'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: sender,
  body: '',
  createdAt: at ?? DateTime(2026, 10, 9, 10),
  attachmentPath: 'c1/$id/Note.m4a',
  file: AttachedFile(
    name: 'Note.m4a',
    mime: voiceMime,
    size: 9000,
    durationMs: 41000,
    waveform: '0123456789abcdef0123456789abcdef01234567',
  ),
);

Future<ProviderContainer> start(
  WidgetTester t,
  List<Message> msgs,
  VoicePlaybackFactoryFake factory, {
  PlayedVoiceStoreFake? played,
}) async {
  final chat = world()..messagesResult = Ok(msgs);
  final devices = DeviceFilesFake();
  for (final m in msgs) {
    devices.written.add('/app/files/${m.id}/Note.m4a');
  }
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      ...voiceOverrides(playback: factory, played: played),
      chatRepositoryProvider.overrideWithValue(chat),
      chatFileRepositoryProvider.overrideWithValue(
        FileRepoFake(devices: devices),
      ),
      deviceFilesProvider.overrideWithValue(devices),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  // Open only once the member is allowed, as the app does.
  await settled(c);
  c.read(openConversationProvider.notifier).open('c1');
  c.listen(messagesProvider, (_, _) {});
  c.listen(voicePlayerProvider, (_, _) {});
  await hop(t);
  return c;
}

void main() {
  testWidgets('toggle opens and plays', (WidgetTester t) async {
    final v1 = voice('v1');
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);

    expect(factory.made.length, 1);
    final p = factory.made[0];
    expect(p.openedPath, '/app/files/v1/Note.m4a');
    expect(p.calls, containsAll(['open', 'play']));

    final state = c.read(voicePlayerProvider);
    expect(state.messageId, 'v1');
    expect(state.playing, true);
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('toggle again pauses', (WidgetTester t) async {
    final v1 = voice('v1');
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);
    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);

    final p = factory.made[0];
    expect(p.calls, contains('pause'));
    expect(factory.made.length, 1);

    final state = c.read(voicePlayerProvider);
    expect(state.playing, false);
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('cycleSpeed changes speed', (WidgetTester t) async {
    final v1 = voice('v1');
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);

    // 1x -> 1.5x
    unawaited(c.read(voicePlayerProvider.notifier).cycleSpeed());
    await hop(t);
    expect(c.read(voicePlayerProvider).speed, 1.5);
    expect(factory.made[0].calls, contains('speed:1.5'));

    // 1.5x -> 2x
    unawaited(c.read(voicePlayerProvider.notifier).cycleSpeed());
    await hop(t);
    expect(c.read(voicePlayerProvider).speed, 2.0);
    expect(factory.made[0].calls, contains('speed:2.0'));

    // 2x -> 1x
    unawaited(c.read(voicePlayerProvider.notifier).cycleSpeed());
    await hop(t);
    expect(c.read(voicePlayerProvider).speed, 1.0);
    expect(factory.made[0].calls, contains('speed:1.0'));
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('auto-play next message', (WidgetTester t) async {
    final v1 = voice('v1', at: DateTime(2026, 10, 9, 10));
    final v2 = voice('v2', at: DateTime(2026, 10, 9, 11));
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1, v2], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);

    // finish v1
    factory.made[0].finish(const Duration(seconds: 41));
    await hop(t);
    await hop(t);

    expect(factory.made.length, 2);
    final p2 = factory.made[1];
    expect(p2.openedPath, '/app/files/v2/Note.m4a');
    expect(p2.calls, contains('play'));

    final state = c.read(voicePlayerProvider);
    expect(state.messageId, 'v2');
    expect(state.played, contains('v1'));
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('speed carries to next message', (WidgetTester t) async {
    final v1 = voice('v1', at: DateTime(2026, 10, 9, 10));
    final v2 = voice('v2', at: DateTime(2026, 10, 9, 11));
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1, v2], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);
    unawaited(c.read(voicePlayerProvider.notifier).cycleSpeed());
    await hop(t);

    // finish v1
    factory.made[0].finish(const Duration(seconds: 41));
    await hop(t);
    await hop(t);

    final p2 = factory.made[1];
    expect(p2.calls, contains('speed:1.5'));
    expect(c.read(voicePlayerProvider).speed, 1.5);
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('own message is not auto-played', (WidgetTester t) async {
    final v1 = voice('v1', sender: 'u2');
    final v2 = voice('v2', sender: 'u1');
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1, v2], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);

    factory.made[0].finish(const Duration(seconds: 41));
    await hop(t);
    await hop(t);

    expect(factory.made.length, 1);
    expect(c.read(voicePlayerProvider).playing, false);
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('played message is skipped', (WidgetTester t) async {
    final v1 = voice('v1', at: DateTime(2026, 10, 9, 10));
    final v2 = voice('v2', at: DateTime(2026, 10, 9, 11));
    final v3 = voice('v3', at: DateTime(2026, 10, 9, 12));
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1, v2, v3], factory);

    // play v2 first
    unawaited(c.read(voicePlayerProvider.notifier).toggle(v2));
    await hop(t);
    factory.made[0].finish(const Duration(seconds: 41));
    await hop(t);
    await hop(t);

    // should play v3 next
    expect(factory.made.length, 2);
    expect(factory.made[1].openedPath, '/app/files/v3/Note.m4a');

    // stop after v3
    unawaited(c.read(voicePlayerProvider.notifier).stop());
    await hop(t);

    // play v1
    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);
    factory.made[2].finish(const Duration(seconds: 41));
    await hop(t);
    await hop(t);

    // ensure no new player for v2 after v1 finishes
    final pathsAfterIndex2 = factory.made
        .sublist(3)
        .map((p) => p.openedPath)
        .where((p) => p == '/app/files/v2/Note.m4a')
        .toList();
    expect(pathsAfterIndex2.isEmpty, true);
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });

  testWidgets('stop disposes player', (WidgetTester t) async {
    final v1 = voice('v1');
    final factory = VoicePlaybackFactoryFake();
    final c = await start(t, [v1], factory);

    unawaited(c.read(voicePlayerProvider.notifier).toggle(v1));
    await hop(t);
    unawaited(c.read(voicePlayerProvider.notifier).stop());
    await hop(t);

    final state = c.read(voicePlayerProvider);
    expect(state.messageId, null);
    expect(state.playing, false);
    expect(factory.made[0].calls, contains('dispose'));
    await t.pump(const Duration(seconds: 10));
    await hop(t);
  });
}
