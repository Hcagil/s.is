// A photo bubble's box (0.30.17). A photo that came with a preview takes
// ONE box from the first frame that has the preview to the decoded photo:
// the preview's shape fitted into 280 x 260. A photo without a preview keeps
// the old sizes. Older pages get their previews too, in one batched read.
//
// The previews here are what the sender really makes: a PNG 24 pixels wide
// (see tinyPreview), so a box that only ever shrinks to fit would be 24 px.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// An older page that arrives without previews, as the first page does (the
/// contract of 0.30.17: older pages are filled by the same batched read).
/// Note: the real messagesAround selects attachment_preview today, so on the
/// real stack the page already carries them; newest_page_integration_test
/// shows that side. This fake pins the batched fill should a page ever come
/// bare.
class _BarePages extends ChatFake {
  @override
  Future<Result<List<Message>>> messagesAround(
    String conversationId,
    Message anchor,
  ) async => switch (await super.messagesAround(conversationId, anchor)) {
    Ok(:final value) => Ok([for (final m in value) m.withPreview(null)]),
    final failed => failed,
  };
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

/// A real PNG of [w] x [h], as a phone encodes one.
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

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  Future<ProviderContainer> container(ChatFake fake) async {
    final box = await settled(
      ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(fake),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );
    addTearDown(box.dispose);
    return box;
  }

  /// Real time passes (runAsync): images decode on the engine, not on the
  /// fake clock.
  Future<void> frames(WidgetTester t, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  final photo = find.byKey(const ValueKey('attachment-c1/0.jpg'));

  /// Opens a chat whose newest message is a photo, its bytes held back.
  Future<void> open(WidgetTester t, Uint8List? preview) async {
    chat = ChatFake()
      ..history['c1'] = [
        _msg(0, path: 'c1/0.jpg', preview: preview),
        for (var i = 1; i < 4; i++) _msg(i),
      ]
      ..holdBytes();
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
    await frames(t);
  }

  /// The box of the photo while its bytes are in flight, then once the
  /// photo [decoded] has arrived and drawn.
  Future<(Size, Size)> boxes(WidgetTester t, Uint8List decoded) async {
    final before = t.getSize(photo);
    chat
      ..attachmentBytesResult = Ok(decoded)
      ..releaseBytes();
    await frames(t, 10);
    expect(
      find.descendant(
        of: photo,
        matching: find.byKey(const ValueKey('attachment-image')),
      ),
      findsOneWidget,
      reason: 'the photo itself decoded and drew',
    );
    return (before, t.getSize(photo));
  }

  for (final (name, pw, ph, want) in [
    ('a wide', 24, 12, const Size(280, 140)),
    ('a tall', 12, 24, const Size(130, 260)),
    ('a square', 24, 24, const Size(260, 260)),
  ]) {
    testWidgets('$name preview: the photo box is the preview shape fitted '
        'into 280 x 260, the same before and after the photo decodes', (
      t,
    ) async {
      await t.runAsync(() async {
        final preview = await _png(pw, ph);
        await open(t, preview);
        expect(
          c
              .read(messagesProvider)
              .requireValue
              .firstWhere((m) => m.id == 'c1-0')
              .attachmentPreview,
          isNotNull,
          reason: 'the batched preview read has answered',
        );
        expect(
          find.descendant(
            of: photo,
            matching: find.byKey(const ValueKey('attachment-preview')),
          ),
          findsOneWidget,
          reason: 'the blurred preview shows while the photo is in flight',
        );
        final (before, after) = await boxes(t, await _png(pw * 25, ph * 25));
        expect(before, want, reason: 'the preview box');
        expect(after, want, reason: 'the decoded photo keeps the same box');
      });
    });
  }

  testWidgets('a decoded photo of another shape than its preview still keeps '
      'the preview box: nothing on the way to the newest message moves', (
    t,
  ) async {
    await t.runAsync(() async {
      await open(t, await _png(24, 12));
      final (before, after) = await boxes(t, await _png(600, 600));
      expect(before, const Size(280, 140));
      expect(after, before);
    });
  });

  testWidgets('a photo without a preview keeps the old sizes: a 120 px '
      'placeholder, then the photo fitted into 280 x 260', (t) async {
    await t.runAsync(() async {
      await open(t, null);
      expect(t.getSize(photo).height, 120, reason: 'the placeholder');
      final (_, after) = await boxes(t, await _png(600, 300));
      expect(after, const Size(280, 140), reason: 'the decoded photo');
    });
  });

  test('an older page gets its previews in one batched read, as the first '
      'page does', () async {
    final previews = {
      for (var i = 0; i < 120; i += 10) i: Uint8List(8)..[0] = i,
    };
    final fake = _BarePages()
      ..history['c1'] = [
        for (var i = 0; i < 120; i++)
          _msg(
            i,
            path: previews.containsKey(i) ? 'c1/$i.jpg' : null,
            preview: previews[i],
          ),
      ];
    c = await container(fake);
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final firstCalls = fake.previewCalls.length;
    final shown = c.read(messagesProvider).requireValue;
    final oldestShown = int.parse(shown.first.id.split('-').last);
    expect(oldestShown, greaterThan(0), reason: 'older history exists');

    await c.read(messagesProvider.notifier).loadOlder();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final rows = c.read(messagesProvider).requireValue;
    final olderPhotos = [
      for (final m in rows)
        if (m.attachmentPath != null &&
            int.parse(m.id.split('-').last) < oldestShown)
          m,
    ];
    expect(olderPhotos, isNotEmpty, reason: 'the older page has photos');
    for (final m in olderPhotos) {
      final i = int.parse(m.id.split('-').last);
      expect(m.attachmentPreview, previews[i], reason: '${m.id} preview');
    }
    final later = fake.previewCalls.skip(firstCalls).toList();
    expect(later, hasLength(1), reason: 'one batched read for the page');
    expect(later.single.toSet(), {
      for (final m in olderPhotos) m.id,
    }, reason: 'that read names exactly the page photos still without one');
  });
}
