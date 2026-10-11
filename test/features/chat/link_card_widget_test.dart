// Link cards on screen, driven through the real message screen and composer:
// the strip above the composer with its X (link-strip, link-strip-dismiss),
// the card under the bubble text (link-card-<messageId>), tap = open the link
// (never by itself), the real domain for lookalikes, and a reader who never
// contacts the website. Only the repository, the link opener and the page
// fetcher are fakes.
import 'dart:async';
import 'dart:io';
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
import 'package:sis/features/chat/application/link_preview_controller.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/link_preview_fetcher.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
const bob = 'u2';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

/// The website: any HTTP client the app opens is recorded.
class _Web extends HttpOverrides {
  final asked = <String>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    asked.add('client');
    return super.createHttpClient(context);
  }
}

class HeldFetcher implements LinkPreviewFetcher {
  final asked = <Uri>[];
  final answers = <Completer<LinkPreviewDraft?>>[];
  @override
  Future<LinkPreviewDraft?> fetch(Uri url) {
    asked.add(url);
    answers.add(Completer());
    return answers.last.future;
  }
}

LinkPreview cardOf(
  String url, {
  String title = 'Example title',
  String? description = 'Two lines about the page',
  String? site = 'Example',
  String? image,
  bool video = false,
}) => LinkPreview(
  url: Uri.parse(url),
  title: title,
  description: description,
  site: site,
  imagePath: image,
  video: video,
);

Message msg(
  String id, {
  required String body,
  String from = bob,
  LinkPreview? card,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 10, 11, 9, minute),
  linkPreview: card,
);

final field = find.byKey(const ValueKey('composer-field'));
final send = find.byKey(const ValueKey('composer-send'));
final strip = find.byKey(const ValueKey('link-strip'));
final stripX = find.byKey(const ValueKey('link-strip-dismiss'));
Finder card(String id) => find.byKey(ValueKey('link-card-$id'));
Finder body(String id) => find.byKey(ValueKey('body-$id'));

String textIn(Finder of) => [
  for (final e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
].join(' ');

late _Web web;
late LinkOpenerFake opener;
late HeldFetcher fetcher;

Future<ChatFake> pump(
  WidgetTester t,
  List<Message> messages, {
  Map<String, Uint8List> pictures = const {},
  Locale locale = const Locale('en'),
}) async {
  final chat = ChatFake(latency: const Duration(milliseconds: 5))
    ..messagesResult = Ok(messages);
  pictures.forEach(chat.store);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(opener),
        linkPreviewFetcherProvider.overrideWithValue(fetcher),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(Brightness.light),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
  await settleImages(t);
  return chat;
}

void main() {
  setUp(() {
    web = _Web();
    HttpOverrides.global = web;
    opener = LinkOpenerFake();
    fetcher = HeldFetcher();
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDown(() => HttpOverrides.global = null);

  group('the card in a bubble', () {
    testWidgets('a received card sits under the text: title, description, '
        'domain; nothing opens by itself', (t) async {
      await pump(t, [
        msg(
          'm1',
          body: 'look https://example.com/articles/one',
          card: cardOf('https://example.com/articles/one'),
        ),
      ]);
      expect(card('m1'), findsOneWidget);
      final text = textIn(card('m1'));
      expect(text, contains('Example title'));
      expect(text, contains('Two lines about the page'));
      expect(text, contains('example.com'));
      expect(
        t.getTopLeft(card('m1')).dy,
        greaterThanOrEqualTo(t.getBottomLeft(body('m1')).dy - 0.5),
        reason: 'the card is UNDER the message text',
      );
      expect(opener.opened, isEmpty, reason: 'no auto-opening');
      expect(web.asked, isEmpty, reason: 'the reader never contacts the site');
    });

    testWidgets('the card is as wide as the bubble text area or wider', (
      t,
    ) async {
      await pump(t, [
        msg(
          'm1',
          body: 'hi https://example.com/a',
          card: cardOf('https://example.com/a'),
        ),
      ]);
      expect(
        t.getSize(card('m1')).width,
        greaterThanOrEqualTo(t.getSize(body('m1')).width - 0.5),
      );
    });

    testWidgets('tapping the card opens exactly its link', (t) async {
      await pump(t, [
        msg(
          'm1',
          body: 'https://example.com/a?b=1',
          card: cardOf('https://example.com/a?b=1'),
        ),
      ]);
      await t.tap(card('m1'));
      await t.pumpAndSettle();
      expect(opener.opened, [Uri.parse('https://example.com/a?b=1')]);
    });

    testWidgets('a video card also opens outside the app on tap', (t) async {
      await pump(t, [
        msg(
          'm1',
          body: 'https://www.youtube.com/watch?v=abc',
          card: cardOf('https://www.youtube.com/watch?v=abc', video: true),
        ),
      ]);
      expect(card('m1'), findsOneWidget);
      await t.tap(card('m1'));
      await t.pumpAndSettle();
      expect(opener.opened, [Uri.parse('https://www.youtube.com/watch?v=abc')]);
    });

    testWidgets('a video card carries a play mark a plain card lacks', (
      t,
    ) async {
      await pump(t, [
        msg(
          'm1',
          body: 'https://www.youtube.com/watch?v=abc',
          card: cardOf(
            'https://www.youtube.com/watch?v=abc',
            video: true,
            image: 'c1/m1.jpg',
          ),
        ),
        msg(
          'm2',
          minute: 1,
          body: 'https://www.youtube.com/watch?v=abd',
          card: cardOf('https://www.youtube.com/watch?v=abd', image: 'c1/m2.jpg'),
        ),
      ], pictures: {'c1/m1.jpg': pngBytes, 'c1/m2.jpg': pngBytes});
      int marks(String id) => find
          .descendant(of: card(id), matching: find.byType(Icon))
          .evaluate()
          .length;
      expect(marks('m1'), greaterThan(marks('m2')));
    });

    testWidgets('a lookalike domain shows its real (xn--) form on the card', (
      t,
    ) async {
      await pump(t, [
        msg(
          'm1',
          body: 'https://аpple.com/login',
          card: cardOf('https://аpple.com/login', site: null),
        ),
      ]);
      final text = textIn(card('m1'));
      expect(text, contains('xn--pple-43d.com'));
      expect(text, isNot(contains('apple.com/')));
    });

    testWidgets('the link in a card message is shortened in the bubble', (
      t,
    ) async {
      const url =
          'https://example.com/articles/2026/10/a-very-long-slug-that-goes-on';
      await pump(t, [msg('m1', body: 'read $url', card: cardOf(url))]);
      final shown = textIn(body('m1'));
      expect(shown, contains(shortLink(Uri.parse(url))));
      expect(shown, isNot(contains(url)));
    });

    testWidgets('an old message without a card keeps its full link', (t) async {
      await pump(t, [msg('m1', body: 'read https://example.com/a/b/c/d')]);
      expect(card('m1'), findsNothing);
      expect(textIn(body('m1')), contains('https://example.com/a/b/c/d'));
    });

    testWidgets('the picture comes from SIS storage, not from the site', (
      t,
    ) async {
      final chat = await pump(
        t,
        [
          msg(
            'm1',
            body: 'https://example.com/a',
            card: cardOf('https://example.com/a', image: 'c1/m1.jpg'),
          ),
        ],
        pictures: {'c1/m1.jpg': pngBytes},
      );
      expect(chat.calls, contains('linkImageBytes:c1/m1.jpg'));
      expect(
        find.descendant(of: card('m1'), matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(web.asked, isEmpty);
    });

    testWidgets('a picture that cannot be read leaves the card, text intact', (
      t,
    ) async {
      await pump(t, [
        msg(
          'm1',
          body: 'https://example.com/a',
          card: cardOf('https://example.com/a', image: 'c1/missing.jpg'),
        ),
      ]);
      expect(card('m1'), findsOneWidget);
      expect(textIn(card('m1')), contains('Example title'));
      expect(t.takeException(), isNull);
    });

    testWidgets('an own message carries its card too', (t) async {
      await pump(t, [
        msg(
          'm1',
          from: 'u1',
          body: 'https://example.com/a',
          card: cardOf('https://example.com/a'),
        ),
      ]);
      expect(card('m1'), findsOneWidget);
    });

    for (final (locale, label) in [
      (const Locale('en'), 'Open link'),
      (const Locale('tr'), 'Bağlantıyı aç'),
    ]) {
      testWidgets('the card has a screen-reader label ($locale)', (t) async {
        final handle = t.ensureSemantics();
        await pump(t, [
          msg(
            'm1',
            body: 'https://example.com/a',
            card: cardOf('https://example.com/a'),
          ),
        ], locale: locale);
        // The label may sit on the card or on the node that wraps it.
        expect(t.getSemantics(card('m1')).label, contains(label));
        handle.dispose();
      });
    }
  });

  group('the strip above the composer', () {
    Future<void> typeLink(WidgetTester t, String text) async {
      await t.enterText(field, text);
      await t.pump(const Duration(milliseconds: 520));
    }

    void answer(int i, {Uint8List? image}) => fetcher.answers[i].complete(
      LinkPreviewDraft(
        preview: cardOf(fetcher.asked[i].toString(), title: 'Strip title'),
        image: image,
      ),
    );

    testWidgets('appears once the card is ready, shows it, and X removes it', (
      t,
    ) async {
      final chat = await pump(t, []);
      await typeLink(t, 'see https://example.com/a');
      expect(fetcher.asked, [Uri.parse('https://example.com/a')]);
      answer(0);
      await t.pumpAndSettle();
      expect(strip, findsOneWidget);
      expect(textIn(strip), contains('Strip title'));
      expect(stripX, findsOneWidget);
      await t.tap(stripX);
      await t.pumpAndSettle();
      expect(strip, findsNothing);
      await t.tap(send);
      await t.pumpAndSettle();
      expect(chat.sentPreviews, [null], reason: 'X = the link goes as plain text');
    });

    for (final (locale, tip) in [
      (const Locale('en'), 'Send as a plain link'),
      (const Locale('tr'), 'Düz bağlantı olarak gönder'),
    ]) {
      testWidgets('X has the plain-link tooltip ($locale)', (t) async {
        await pump(t, [], locale: locale);
        await typeLink(t, 'https://example.com/a');
        answer(0);
        await t.pumpAndSettle();
        expect(
          find.descendant(
            of: stripX,
            matching: find.byTooltip(tip),
            matchRoot: true,
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('sending with a ready strip sends the card and clears the strip', (
      t,
    ) async {
      final chat = await pump(t, []);
      await typeLink(t, 'https://example.com/a');
      answer(0, image: pngBytes);
      await t.pumpAndSettle();
      await t.tap(send);
      await t.pump();
      expect(strip, findsNothing);
      await settleImages(t);
      final sent = chat.sentPreviews.single!;
      expect(sent.preview.url, Uri.parse('https://example.com/a'));
      expect(sent.image, pngBytes);
      expect(sent.preview.imagePath, startsWith('c1/'));
    });

    testWidgets('sending never waits: before the card is ready the message '
        'goes at once, without one', (t) async {
      final chat = await pump(t, []);
      await typeLink(t, 'https://example.com/slow');
      await t.tap(send);
      await t.pump();
      expect(find.textContaining('example.com/slow'), findsWidgets);
      await settleImages(t);
      expect(chat.sentPreviews, [null]);
      answer(0);
      await t.pumpAndSettle();
      expect(strip, findsNothing, reason: 'no late strip after the send');
    });

    testWidgets('the sender sees her card in the pending bubble at once', (
      t,
    ) async {
      await pump(t, []);
      await typeLink(t, 'https://example.com/a');
      answer(0);
      await t.pumpAndSettle();
      await t.tap(send);
      await t.pump();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('link-card-'),
        ),
        findsOneWidget,
      );
      await settleImages(t);
    });
  });
}
