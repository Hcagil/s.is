// Links in message bubbles and the full-screen photo viewer, written from the
// contract and driven through the real message screen. Only the repository
// and the link opener are fakes; the providers, the controller and the
// widgets between them are the production ones.
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = 'u2';

Message msg(
  String id, {
  String body = '',
  String from = 'u1',
  String? attachment,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
  attachmentPath: attachment,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final theme = sisTheme(Brightness.light);

ProviderContainer scope(ChatFake chat, LinkOpenerFake opener) =>
    ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentSourceProvider.overrideWithValue(PickerFake.cancels()),
        linkOpenerProvider.overrideWithValue(opener),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    );

Future<void> pump(
  WidgetTester tester,
  ChatFake chat, {
  LinkOpenerFake? opener,
  bool decode = true,
}) async {
  final container = scope(chat, opener ?? LinkOpenerFake());
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  // A photo still decoding shows a spinner, which never settles under the
  // fake clock; step the clock instead, then let decoding finish for real.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (decode) await settleImages(tester);
}

ChatFake chatWith(List<Message> messages) {
  final chat = ChatFake(latency: const Duration(milliseconds: 5))
    ..messagesResult = Ok(messages);
  for (final m in messages) {
    if (m.attachmentPath case final path?) chat.store(path);
  }
  return chat;
}

typedef Span = ({String text, TextStyle? style, GestureRecognizer? tap});

/// Every text run rendered under [of], with the style it is painted in.
List<Span> spansIn(Finder of) {
  final out = <Span>[];
  void walk(InlineSpan span, TextStyle? inherited) {
    final style = inherited == null ? span.style : inherited.merge(span.style);
    if (span is! TextSpan) return;
    if (span.text case final text? when text.isNotEmpty) {
      out.add((text: text, style: style, tap: span.recognizer));
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  for (final rich
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate()
          .map((e) => e.widget as RichText)) {
    walk(rich.text, null);
  }
  return out;
}

bool underlined(Span s) =>
    s.style?.decoration?.contains(TextDecoration.underline) ?? false;

Finder body(String id) => find.byKey(ValueKey('body-$id'));

Span spanOf(String id, String text) =>
    spansIn(body(id)).singleWhere((s) => s.text == text);

Future<void> tapText(WidgetTester tester, String id, String text) async {
  await tester.tapOnText(
    find.textRange.ofSubstring(text, descendentOf: body(id)),
  );
  await tester.pumpAndSettle();
}

Finder inViewer(Finder f) =>
    find.descendant(of: find.byType(PhotoViewer), matching: f);

String position(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byKey(const ValueKey('viewer-position')),
      matching: find.byType(Text),
      matchRoot: true,
    ),
  );
  return text.data ?? text.textSpan!.toPlainText();
}

Finder viewerImage(String path) =>
    inViewer(find.byKey(ValueKey('viewer-image-$path')));

Future<void> openPhoto(WidgetTester tester, String path) async {
  final photo = find.byKey(ValueKey('attachment-$path'));
  await settleImages(tester);
  final list = find
      .ancestor(
        of: find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('message-'),
            )
            .first,
        matching: find.byType(Scrollable),
      )
      .first;
  // Older photos can be scrolled out of a lazily built list, in either
  // direction depending on how the list is laid out.
  for (final delta in [200.0, -200.0]) {
    if (photo.evaluate().isNotEmpty) break;
    try {
      await tester.scrollUntilVisible(photo, delta, scrollable: list);
    } on StateError {
      // Not that way; try the other.
    }
  }
  await settleImages(tester);
  await tester.ensureVisible(photo);
  await tester.pumpAndSettle();
  await tester.tap(photo);
  await tester.pumpAndSettle();
  expect(find.byType(PhotoViewer), findsOneWidget);
}

Future<void> swipe(WidgetTester tester, {bool forward = true}) async {
  final pages = find.byKey(const ValueKey('viewer-pages'));
  final width = tester.getSize(pages).width;
  await tester.fling(pages, Offset(forward ? -width : width, 0), 2000);
  await tester.pumpAndSettle();
  await settleImages(tester);
}

void expectNoRawException() {
  final leaked = find.byWidgetPredicate((w) {
    final data = w is Text ? (w.data ?? w.textSpan?.toPlainText() ?? '') : '';
    return data.contains('Instance of') ||
        data.contains('Failure(') ||
        data.contains('Exception');
  });
  expect(leaked, findsNothing, reason: 'a raw exception string reached the UI');
}

void main() {
  setUpAll(() => HttpOverrides.global = ImageServer(missing: {'gone'}));
  tearDownAll(() => HttpOverrides.global = null);
  // Every test starts with nothing decoded, as a freshly opened app does.
  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  group('links in a bubble', () {
    testWidgets('a link is underlined and tappable; the rest is not', (
      tester,
    ) async {
      await pump(
        tester,
        chatWith([
          msg('m1', from: bob, body: 'bak https://example.com/a?b=1 güzel'),
        ]),
      );

      final link = spanOf('m1', 'https://example.com/a?b=1');
      expect(underlined(link), isTrue, reason: 'a link must look like one');
      expect(link.tap, isNotNull, reason: 'a link must be tappable');
      for (final s in spansIn(body('m1')).where((s) => s != link)) {
        expect(underlined(s), isFalse, reason: '"${s.text}" is not a link');
        expect(s.tap, isNull, reason: '"${s.text}" is not a link');
      }
      expect(
        spansIn(body('m1')).map((s) => s.text).join(),
        'bak https://example.com/a?b=1 güzel',
        reason: 'the body must read exactly as it was sent',
      );
    });

    testWidgets('tapping a link opens exactly that link', (tester) async {
      final opener = LinkOpenerFake(latency: const Duration(milliseconds: 30));
      await pump(
        tester,
        chatWith([
          msg(
            'm1',
            from: bob,
            body: 'first https://one.example/x then www.two.example/y end',
          ),
        ]),
        opener: opener,
      );

      await tapText(tester, 'm1', 'www.two.example/y');
      await tapText(tester, 'm1', 'https://one.example/x');

      expect(opener.opened, [
        Uri.parse('https://www.two.example/y'),
        Uri.parse('https://one.example/x'),
      ]);
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'a link that opened is not an error',
      );
    });

    testWidgets('tapping the words around a link opens nothing', (
      tester,
    ) async {
      final opener = LinkOpenerFake();
      await pump(
        tester,
        chatWith([msg('m1', from: bob, body: 'bak https://example.com güzel')]),
        opener: opener,
      );

      await tapText(tester, 'm1', 'güzel');
      await tapText(tester, 'm1', 'bak');

      expect(opener.opened, isEmpty);
      expect(find.byType(PhotoViewer), findsNothing);
    });

    testWidgets('a link that will not open says which host', (tester) async {
      final opener = LinkOpenerFake(
        opens: false,
        latency: const Duration(milliseconds: 30),
      );
      await pump(
        tester,
        chatWith([
          msg('m1', from: bob, body: 'see https://blocked.example.org/page'),
        ]),
        opener: opener,
      );

      await tapText(tester, 'm1', 'https://blocked.example.org/page');

      expect(opener.opened, [Uri.parse('https://blocked.example.org/page')]);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Could not open blocked.example.org'),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('link colour: white on my bubbles, primary on theirs', (
      tester,
    ) async {
      await pump(
        tester,
        chatWith([
          msg('mine', body: 'mine https://a.example', minute: 1),
          msg('theirs', from: bob, body: 'theirs https://b.example', minute: 2),
        ]),
      );

      expect(
        spanOf('mine', 'https://a.example').style?.color?.toARGB32(),
        Colors.white.toARGB32(),
        reason: 'on the gradient bubble a link is white',
      );
      expect(
        spanOf('theirs', 'https://b.example').style?.color?.toARGB32(),
        theme.colorScheme.primary.toARGB32(),
        reason: 'on their bubble a link takes the primary colour',
      );
    });

    testWidgets('a dangerous scheme is shown as plain text', (tester) async {
      final opener = LinkOpenerFake();
      await pump(
        tester,
        chatWith([
          msg('m1', from: bob, body: 'tap javascript:alert(1) or mailto:a@b.c'),
        ]),
        opener: opener,
      );

      for (final s in spansIn(body('m1'))) {
        expect(s.tap, isNull, reason: '"${s.text}" must not be tappable');
        expect(underlined(s), isFalse);
      }
      await tapText(tester, 'm1', 'javascript:alert(1)');
      expect(opener.opened, isEmpty);
    });

    testWidgets('text with no link renders as before', (tester) async {
      await pump(
        tester,
        chatWith([msg('m1', from: bob, body: 'just words, no link.')]),
      );

      expect(find.text('just words, no link.'), findsOneWidget);
      for (final s in spansIn(find.byKey(const ValueKey('message-m1')))) {
        expect(s.tap, isNull);
        expect(underlined(s), isFalse);
      }
    });
  });

  group('the photo viewer', () {
    // Oldest first, with text-only messages between the photos.
    final history = [
      msg('m1', attachment: 'c1/a.png', minute: 1),
      msg('m2', body: 'no photo here', from: bob, minute: 2),
      msg('m3', attachment: 'c1/b.png', from: bob, body: 'bu', minute: 3),
      msg('m4', attachment: 'c1/c.png', minute: 4),
    ];

    testWidgets('opens at the tapped photo, among all of them', (tester) async {
      await pump(tester, chatWith(history));

      await openPhoto(tester, 'c1/b.png');

      expect(position(tester), '2 of 3');
      expect(viewerImage('c1/b.png'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byKey(const ValueKey('viewer-image-c1/b.png')),
        ),
        findsOneWidget,
        reason: 'the photo must be pinch-zoomable',
      );
      final zoom = tester.widget<InteractiveViewer>(
        find.ancestor(
          of: viewerImage('c1/b.png'),
          matching: find.byType(InteractiveViewer),
        ),
      );
      expect(zoom.scaleEnabled, isTrue);
      expect(zoom.maxScale, greaterThan(1), reason: 'pinching must zoom in');
      final image = tester.widget<Image>(
        find.descendant(
          of: viewerImage('c1/b.png'),
          matching: find.byType(Image),
          matchRoot: true,
        ),
      );
      expect(
        (image.image as NetworkImage).url,
        contains('attachments/c1/b.png'),
        reason: 'the page must show the URL signed for its own path',
      );
      expectNoRawException();
    });

    testWidgets('swiping walks the photos oldest first', (tester) async {
      await pump(tester, chatWith(history));
      await openPhoto(tester, 'c1/a.png');

      expect(position(tester), '1 of 3');
      expect(viewerImage('c1/a.png'), findsOneWidget);

      await swipe(tester);
      expect(position(tester), '2 of 3');
      expect(viewerImage('c1/b.png'), findsOneWidget);
      expect(viewerImage('c1/a.png'), findsNothing);

      await swipe(tester);
      expect(position(tester), '3 of 3');
      expect(viewerImage('c1/c.png'), findsOneWidget);

      await swipe(tester);
      expect(position(tester), '3 of 3', reason: 'there is no fourth photo');

      await swipe(tester, forward: false);
      expect(position(tester), '2 of 3');
      expect(viewerImage('c1/b.png'), findsOneWidget);
    });

    testWidgets('a photo still decoding is a real tap target that opens it', (
      tester,
    ) async {
      // No settleImages: under the fake clock the engine never finishes
      // decoding, which is a slow phone on a slow network.
      await pump(tester, chatWith(history), decode: false);
      final photo = find.byKey(const ValueKey('attachment-c1/b.png'));
      await tester.ensureVisible(photo);
      await tester.pump(const Duration(milliseconds: 500));

      final size = tester.getSize(photo);
      expect(
        size.width * size.height,
        greaterThan(40 * 40),
        reason: 'an undecoded photo must still occupy a tappable area',
      );

      expect(
        find.descendant(
          of: photo,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: 'this test is about the moment before the photo has decoded',
      );

      final fatal = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = fatal);
      await tester.tap(photo);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(position(tester), '2 of 3');
    });

    testWidgets('the last photo opens at the end', (tester) async {
      await pump(tester, chatWith(history));
      await openPhoto(tester, 'c1/c.png');
      expect(position(tester), '3 of 3');
      expect(viewerImage('c1/c.png'), findsOneWidget);
    });

    testWidgets('a photo that arrived over Realtime is included', (
      tester,
    ) async {
      final chat = chatWith(history)..store('c1/d.png');
      await pump(tester, chat);

      chat.deliver(msg('m5', attachment: 'c1/d.png', from: bob, minute: 5));
      await settleImages(tester);

      await openPhoto(tester, 'c1/d.png');
      expect(position(tester), '4 of 4');

      await swipe(tester, forward: false);
      expect(position(tester), '3 of 4');
      expect(viewerImage('c1/c.png'), findsOneWidget);
    });

    testWidgets('has a black background', (tester) async {
      await pump(tester, chatWith(history));
      await openPhoto(tester, 'c1/a.png');

      final scaffold = tester.widget<Scaffold>(inViewer(find.byType(Scaffold)));
      expect(scaffold.backgroundColor?.toARGB32(), Colors.black.toARGB32());
    });

    testWidgets('a photo whose URL cannot be issued says why', (tester) async {
      final chat = chatWith(history);
      chat.urlFailures['c1/b.png'] = const NetworkFailure(
        'signing refused for this photo',
      );
      await pump(tester, chat);
      await openPhoto(tester, 'c1/a.png');

      await swipe(tester);

      expect(position(tester), '2 of 3');
      expect(
        inViewer(find.textContaining('signing refused for this photo')),
        findsOneWidget,
        reason: 'a page that cannot load must show the reason',
      );
      expect(
        inViewer(find.byType(CircularProgressIndicator)),
        findsNothing,
        reason: 'a failed page must not spin forever',
      );
      expect(chat.urlRequests, contains('c1/b.png'));
      expectNoRawException();
    });

    testWidgets('a broken image says it is unavailable', (tester) async {
      final chat = chatWith([
        msg('m1', attachment: 'c1/a.png', minute: 1),
        msg('m2', attachment: 'c1/gone.png', minute: 2),
      ]);
      await pump(tester, chat);
      await openPhoto(tester, 'c1/a.png');
      expect(inViewer(find.text('Image unavailable')), findsNothing);

      await swipe(tester);
      await tester.pumpAndSettle();

      expect(position(tester), '2 of 2');
      expect(inViewer(find.text('Image unavailable')), findsOneWidget);
      expectNoRawException();
    });

    testWidgets('closing the viewer returns to the conversation', (
      tester,
    ) async {
      await pump(tester, chatWith(history));
      await openPhoto(tester, 'c1/b.png');

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.byKey(const ValueKey('message-m3')), findsOneWidget);
    });
  });

  group('attachmentUrlProvider', () {
    test('is the repository\'s signed URL for that path', () async {
      final chat = ChatFake()..store('c1/a.png');
      final c = scope(chat, LinkOpenerFake());

      final url = await c.read(attachmentUrlProvider('c1/a.png').future);

      expect(url.path, endsWith('attachments/c1/a.png'));
      expect(chat.urlRequests, ['c1/a.png']);
    });

    test('an Err becomes an AsyncError carrying the Failure itself', () async {
      const failure = NetworkFailure('storage is down');
      final chat = ChatFake()..urlFailures['c1/a.png'] = failure;
      final c = scope(chat, LinkOpenerFake());
      c.listen(attachmentUrlProvider('c1/a.png'), (_, _) {});

      await expectLater(
        c.read(attachmentUrlProvider('c1/a.png').future),
        throwsA(same(failure)),
      );
      final state = c.read(attachmentUrlProvider('c1/a.png'));
      expect(state, isA<AsyncError<Uri>>());
      expect(state.error, same(failure));
    });

    test('a failure is not retried behind the screen\'s back', () async {
      final chat = ChatFake()..urlFailures['c1/a.png'] = const DeniedFailure();
      final c = scope(chat, LinkOpenerFake());
      c.listen(attachmentUrlProvider('c1/a.png'), (_, _) {});

      await Future<void>.delayed(const Duration(seconds: 2));

      expect(chat.urlRequests, ['c1/a.png']);
      expect(c.read(attachmentUrlProvider('c1/a.png')), isA<AsyncError<Uri>>());
    });
  });
}
