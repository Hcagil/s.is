@Tags(['speed'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../support/fakes.dart';
import '../support/speed_probe.dart';

/// Timing probe, not a test: how much UI-thread work the message screen costs
/// for a short and a long history. flutter_test runs the debug build on the
/// host CPU with no GPU, so the numbers are only good for comparing one screen
/// state with another (and one change with the next); the phone's own figures
/// come from a profile build (see the speed report).
///
/// Run: flutter test --run-skipped --tags speed test/speed
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

const _repeats = 5;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Message _message(int i) => Message(
  id: 'm$i',
  conversationId: 'c1',
  senderId: i.isEven ? 'u1' : 'u2',
  body: switch (i % 3) {
    0 => 'ok',
    1 => 'see you soon, bring the thing we talked about',
    _ =>
      'A longer message that wraps onto a few lines inside its bubble on '
          'any phone, with enough words to be realistic about it.',
  },
  createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
  replyTo: i % 10 == 9 ? 'm${i - 1}' : null,
  attachmentPath: i % 8 == 7 ? 'c1/p$i.jpg' : null,
  attachmentPreview: i % 8 == 7 ? Uint8List.fromList(_png) : null,
);

List<Message> _history(int n) => [for (var i = 0; i < n; i++) _message(i)];

Future<(ProviderContainer, ChatFake)> _open(WidgetTester tester, int n) async {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final chat = ChatFake(self: me.userId)
    ..history['c1'] = _history(n)
    ..roster['c1'] = [me, bob]
    ..membersResult = const Ok([me, bob]);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: sisTheme(Brightness.light),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  return (container, chat);
}

void main() {
  for (final n in [20, 500]) {
    testWidgets('first content, $n messages', (tester) async {
      final samples = Samples('open $n');
      for (var i = 0; i < _repeats; i++) {
        final clock = Stopwatch()..start();
        await _open(tester, n);
        var pumps = 0;
        while (find.byKey(ValueKey('message-m${n - 1}')).evaluate().isEmpty &&
            pumps++ < 50) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        samples.add(clock.elapsed);
        expect(find.byKey(ValueKey('message-m${n - 1}')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
      report(
        'chat screen to newest bubble, $n messages (debug, fake repo)',
        samples,
      );
    });

    testWidgets('one more message arrives, $n messages', (tester) async {
      final (_, chat) = await _open(tester, n);
      await tester.pumpAndSettle();
      final samples = Samples('arrive $n');
      for (var i = 0; i < _repeats; i++) {
        final clock = Stopwatch()..start();
        chat.deliver(_message(n + i));
        await tester.pump();
        samples.add(clock.elapsed);
      }
      report('chat screen, one incoming message, $n messages', samples);
    });
  }

  testWidgets('scroll fling, 500 messages', (tester) async {
    await _open(tester, 500);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(ListView), const Offset(0, 600), 2000);
    final frames = Samples('fling');
    for (var i = 0; i < 120 && tester.binding.hasScheduledFrame; i++) {
      final clock = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      frames.add(clock.elapsed);
    }
    final sorted = [...frames.micros]..sort();
    final p95 =
        sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    report(
      'chat scroll, per frame, 500 messages',
      frames,
      extra: 'frames ${sorted.length} | p95 ${p95 ~/ 1000} ms',
    );
  });
}
