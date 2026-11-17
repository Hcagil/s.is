// Repro test for the photo box size jump bug.
// It verifies that a photo with a preview keeps the preview‑fitted size
// from the first frame, both on cold and warm opens.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final _t0 = DateTime.utc(2026, 9, 1, 8);

Message _msg(int i, {String? path, Uint8List? preview}) => Message(
  id: 'c1-$i',
  conversationId: 'c1',
  senderId: i.isEven ? 'u1' : 'u2',
  body: 'line $i',
  createdAt: _t0.add(Duration(minutes: i)),
  attachmentPath: path,
  attachmentPreview: preview,
);

Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF3366AA),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<ProviderContainer> container(ChatFake fake) async {
  final box = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(fake),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  addTearDown(box.dispose);
  return box;
}

Future<void> frames(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 50));
  }
}

final photo = find.byKey(const ValueKey('attachment-c1/0.jpg'));

Future<Size> firstPaint(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await t.pump(const Duration(milliseconds: 16));
    if (find.byKey(const ValueKey('attachment-c1/0.jpg')).evaluate().length ==
        1) {
      return t.getSize(photo);
    }
  }
  fail('the photo never painted');
}

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  for (final (name, pw, ph, want) in [
    ('a tall', 12, 24, const Size(130, 260)),
    ('a wide', 24, 12, const Size(280, 140)),
  ]) {
    testWidgets(
      '$name preview: the photo box at first paint is already the preview box (cold open)',
      (t) async {
        await t.runAsync(() async {
          final preview = await _png(pw, ph);
          chat = ChatFake()
            ..history['c1'] = [
              _msg(0, path: 'c1/0.jpg', preview: preview),
              for (var i = 1; i < 4; i++) _msg(i),
            ]
            ..holdBytes();
          final held = chat.holdPreviews();
          c = await container(chat);
          c.read(openConversationProvider.notifier).open('c1');
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: const MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: MessageScreen(title: 'Bob'),
              ),
            ),
          );
          final first = await firstPaint(t);
          held.complete();
          await frames(t, 10);
          final settled = t.getSize(photo);
          expect(settled, want, reason: 'the settled box is the preview box');
          expect(
            first,
            settled,
            reason:
                'no size jump: the first painted box equals the settled box',
          );
        });
      },
    );

    testWidgets(
      '$name preview: reopening a chat that already showed its previews does not jump either (warm open)',
      (t) async {
        await t.runAsync(() async {
          final preview = await _png(pw, ph);
          chat = ChatFake()
            ..history['c1'] = [
              _msg(0, path: 'c1/0.jpg', preview: preview),
              for (var i = 1; i < 4; i++) _msg(i),
            ]
            ..holdBytes();
          chat.history['c2'] = [];
          c = await container(chat);
          c.read(openConversationProvider.notifier).open('c1');
          await t.pumpWidget(
            UncontrolledProviderScope(
              container: c,
              child: const MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: MessageScreen(title: 'Bob'),
              ),
            ),
          );
          await frames(t, 10);
          expect(
            t.getSize(photo),
            want,
            reason: 'precondition: preview box already set',
          );

          final held = chat.holdPreviews();
          c.read(openConversationProvider.notifier).open('c2');
          await frames(t, 4);
          c.read(openConversationProvider.notifier).open('c1');
          final first = await firstPaint(t);
          held.complete();
          await frames(t, 10);
          final settled = t.getSize(photo);
          expect(first, settled, reason: 'no jump on warm open');
          expect(settled, want, reason: 'final size matches preview box');
        });
      },
    );
  }
}
