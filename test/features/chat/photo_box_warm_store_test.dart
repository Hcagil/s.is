// test/features/chat/photo_box_warm_store_test.dart
// Repro test for the photo box size jump bug using the real on‑phone store.
// It verifies that a photo with a stored preview keeps the preview‑fitted size
// from the first frame, both on cold and warm opens, when the server read is
// held.

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
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'data/store/store_harness.dart';

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

Future<ProviderContainer> container(
  ChatFake fake,
  DriftMessageStore store,
) async {
  final box = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(fake),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        messageStoreProvider.overrideWithValue(store),
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
  for (final (name, pw, ph, want) in [
    ('a tall', 12, 24, const Size(130, 260)),
    ('a wide', 24, 12, const Size(280, 140)),
  ]) {
    testWidgets(
      '$name preview: the first painted box is the stored preview box while the server read is held',
      (t) async {
        await t.runAsync(() async {
          final preview = await _png(pw, ph);
          final h = await StoreHarness.create();
          final real = h.open(owner: 'me', key: await h.newKey());
          addTearDown(real.close);
          final rows = [
            _msg(0, path: 'c1/0.jpg', preview: preview),
            for (var i = 1; i < 4; i++) _msg(i),
          ];
          await real.upsertAll(rows);
          final chat = ChatFake()
            ..history['c1'] = rows
            ..holdBytes()
            ..holdMessages();
          final c = await container(chat, real);
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
          chat.releaseMessages();
          await frames(t, 10);
          final settled = t.getSize(photo);
          expect(settled, want, reason: 'settled box matches preview box');
          expect(
            first,
            settled,
            reason: 'no size jump: first painted box equals settled box',
          );
          final stored = (await real.newest('c1'))
              .firstWhere((m) => m.id == 'c1-0');
          expect(stored.attachmentPreview, preview);
        });
      },
    );
  }

  testWidgets('a stored photo without a preview opens at the default box', (
    t,
  ) async {
    await t.runAsync(() async {
      final h = await StoreHarness.create();
      final real = h.open(owner: 'me', key: await h.newKey());
      addTearDown(real.close);
      final rows = [
        _msg(0, path: 'c1/0.jpg', preview: null),
        for (var i = 1; i < 4; i++) _msg(i),
      ];
      await real.upsertAll(rows);
      final chat = ChatFake()
        ..history['c1'] = rows
        ..holdBytes()
        ..holdMessages();
      final c = await container(chat, real);
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
      chat.releaseMessages();
      await frames(t, 10);
      final settled = t.getSize(photo);
      expect(
        settled,
        const Size(240, 240),
        reason: 'default box size when no preview',
      );
      expect(
        first,
        settled,
        reason: 'no size jump: first painted box equals settled box',
      );
      final stored = (await real.newest('c1'))
          .firstWhere((m) => m.id == 'c1-0');
      expect(stored.attachmentPreview, isNull);
    });
  });
}
