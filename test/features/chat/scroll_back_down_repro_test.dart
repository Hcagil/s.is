// Scrolling back down a long chat (0.30.17). After paging up through older
// messages, dragging toward the newest message must always move toward it
// and reach it. On 0.30.16 a photo bubble that grew (placeholder -> decoded
// photo) between the viewport and the newest message shoved the rows on
// screen the other way: the reversed list anchors on its first laid-out
// child, not on what is visible. Photo bubbles now take their final box
// from the preview, so nothing on the way down changes height.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final _t0 = DateTime.utc(2026, 9, 1, 8);

/// Bubbles of varying height, as a real chat has.
List<Message> _history(int n, {bool photos = false, Uint8List? preview}) => [
  for (var i = 0; i < n; i++)
    Message(
      id: 'c1-$i',
      conversationId: 'c1',
      senderId: i.isEven ? 'u1' : 'u2',
      body: 'hay $i ${'word ' * (i % 7) * 4}',
      createdAt: _t0.add(Duration(minutes: i)),
      attachmentPath: photos && i % 3 == 0 ? 'c1/$i.jpg' : null,
      attachmentPreview: photos && i % 3 == 0 ? preview : null,
    ),
];

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  Future<void> frames(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester t, {
    int count = 300,
    bool photos = false,
    TargetPlatform? platform,
    Duration latency = const Duration(milliseconds: 150),
    Uint8List? preview,
  }) async {
    chat = ChatFake(latency: latency)
      ..history['c1'] = _history(count, photos: photos, preview: preview)
      ..attachmentBytesResult = Ok(pngBytes);
    c = await settled(
      ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );
    addTearDown(c.dispose);
    c.read(openConversationProvider.notifier).open('c1');
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(platform: platform),
          home: const MessageScreen(title: 'Bob'),
        ),
      ),
    );
    await frames(t);
  }

  final scrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  ScrollPosition position(WidgetTester t) =>
      t.state<ScrollableState>(scrollable).position;

  Future<void> scrollUpPages(WidgetTester t, int pages) async {
    for (var page = 0; page < pages; page++) {
      for (var i = 0; i < 30 && position(t).extentAfter >= 600; i++) {
        await t.drag(scrollable, const Offset(0, 400));
        await t.pump();
      }
      await frames(t, 3);
    }
  }

  /// Drags toward the newest message, as a thumb does, until the list
  /// reports it is at the bottom or gives up.
  Future<int> scrollDown(WidgetTester t) async {
    var drags = 0;
    while (position(t).pixels > 0 && drags < 400) {
      await t.drag(scrollable, const Offset(0, -500));
      await t.pump();
      drags++;
    }
    await t.pump(const Duration(seconds: 1));
    return drags;
  }

  testWidgets('after paging up through history, scrolling back down reaches '
      'the newest message', (t) async {
    await open(t);
    expect(find.textContaining('hay 299', findRichText: true), findsOneWidget);
    await scrollUpPages(t, 4);
    expect(c.read(messagesProvider).requireValue.length, greaterThan(200));
    final drags = await scrollDown(t);
    expect(position(t).pixels, 0, reason: 'after $drags drags');
    expect(
      find.textContaining('hay 299', findRichText: true),
      findsOneWidget,
      reason: 'the newest message is on screen again',
    );
  });

  testWidgets('photo bubbles that load while scrolling back down do not stop '
      'the way to the newest message', (t) async {
    await open(t, photos: true);
    await scrollUpPages(t, 4);
    final drags = await scrollDown(t);
    expect(position(t).pixels, 0, reason: 'after $drags drags');
    expect(
      find.textContaining('hay 299', findRichText: true),
      findsOneWidget,
      reason: 'the newest message is on screen again',
    );
    await frames(t, 20); // the last photo reads answer
  });

  /// Flings, as a thumb does on glass: up through several pages, then down.
  Future<void> flingUpPages(WidgetTester t, int pages) async {
    for (var page = 0; page < pages; page++) {
      for (var i = 0; i < 6 && position(t).extentAfter >= 600; i++) {
        await t.fling(scrollable, const Offset(0, 600), 3000);
        await t.pumpAndSettle();
      }
      await frames(t, 3);
    }
  }

  Future<int> flingDown(WidgetTester t) async {
    var flings = 0;
    while (position(t).pixels > 0 && flings < 200) {
      await t.fling(scrollable, const Offset(0, -600), 3000);
      await t.pumpAndSettle();
      flings++;
    }
    await t.pump(const Duration(seconds: 1));
    return flings;
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform: flinging up through photo history and back down '
        'reaches the newest message', (t) async {
      await open(t, photos: true, platform: platform);
      await flingUpPages(t, 4);
      expect(c.read(messagesProvider).requireValue.length, greaterThan(200));
      final flings = await flingDown(t);
      expect(position(t).pixels, 0, reason: 'after $flings flings');
      expect(
        find.textContaining('hay 299', findRichText: true),
        findsOneWidget,
        reason: 'the newest message is on screen again',
      );
    });
  }

  testWidgets('a resume catch-up while scrolled up, then rows the live '
      'subscription missed, do not stop the way back down', (t) async {
    await open(t, photos: true);
    await scrollUpPages(t, 4);
    // App came back to the foreground: the controller reads again.
    c.read(messagesProvider.notifier).catchUp();
    await frames(t, 5);
    expect(c.read(messagesProvider).requireValue.length, greaterThan(200));
    // Rows that reached the server while Realtime was down: only a verify
    // read (triggered near the bottom) can bring them in.
    for (var k = 0; k < 4; k++) {
      chat.history['c1']!.add(
        Message(
          id: 'missed-$k',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'missed $k',
          createdAt: _t0.add(Duration(minutes: 300 + k)),
        ),
      );
    }
    final drags = await scrollDown(t);
    expect(position(t).pixels, 0, reason: 'after $drags drags');
    await frames(t, 5);
    final again = await scrollDown(t);
    expect(position(t).pixels, 0, reason: 'after $again more drags');
    expect(find.textContaining('missed 3', findRichText: true), findsOneWidget);
  });

  /// A real 240x240 picture, so a photo bubble grows from its 120 px
  /// placeholder to its full 260 px once the bytes decode -- as on a phone.
  Future<Uint8List> picture(int side) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3366AA),
    );
    final image = await recorder.endRecording().toImage(side, side);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  testWidgets('photos that decode and grow while scrolling back down do not '
      'stop the way to the newest message', (t) async {
    await t.runAsync(() async {
      final photo = await picture(600);
      final tiny = await picture(24); // the preview sent with each photo
      // No fake timers: inside runAsync only real time passes.
      await open(t, photos: true, latency: Duration.zero, preview: tiny);
      chat.attachmentBytesResult = Ok(photo);
      await scrollUpPages(t, 4);
      var drags = 0;
      var stalls = 0;
      var last = position(t).pixels;
      while (position(t).pixels > 0 && drags < 200) {
        await t.drag(scrollable, const Offset(0, -500));
        // Let the images decode and lay out, as frames do on a phone.
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await t.pump(const Duration(milliseconds: 50));
        }
        drags++;
        final now = position(t).pixels;
        if (now >= last - 1) stalls++;
        last = now;
      }
      expect(position(t).pixels, 0, reason: 'after $drags drags');
      expect(
        find.textContaining('hay 299', findRichText: true),
        findsOneWidget,
        reason: 'the newest message is on screen again',
      );
      expect(
        stalls,
        0,
        reason:
            'a 500 px drag toward the newest message must move the list '
            'toward it, never away',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await t.pump();
    });
  });

  testWidgets('a message that arrives while scrolled up does not stop the '
      'way back down', (t) async {
    await open(t);
    await scrollUpPages(t, 3);
    for (var k = 0; k < 3; k++) {
      chat.deliver(
        Message(
          id: 'live-$k',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'live $k',
          createdAt: _t0.add(Duration(minutes: 300 + k)),
        ),
      );
      await frames(t, 2);
    }
    final drags = await scrollDown(t);
    expect(position(t).pixels, 0, reason: 'after $drags drags');
    expect(find.text('live 2', findRichText: true), findsOneWidget);
  });
}
