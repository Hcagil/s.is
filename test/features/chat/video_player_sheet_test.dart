// Step 11b: link videos play inside the chat in a card rising from the
// bottom (option B). Driven through the real message screen, as production
// mounts it; only the repository, the link opener, the page fetcher and the
// web view are fakes. The fake web view is built by the sheet and hands back
// the spec, so a test can play the site: loaded, refused, or navigating away.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/link_preview_controller.dart';
import 'package:sis/features/chat/application/video_refused.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/link_preview_fetcher.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video_embed.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/video_player_sheet.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');
const _yt = 'https://youtu.be/dQw4w9WgXcQ';
const _yt2 = 'https://www.youtube.com/watch?v=aaaaaaaaaaa';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

class _NoFetch implements LinkPreviewFetcher {
  @override
  Future<LinkPreviewDraft?> fetch(Uri url) async => null;
}

/// The web view, as the sheet sees it: built from a spec, nothing else. It
/// records every spec it was built with (= every load).
class View {
  final specs = <VideoEmbedViewSpec>[];
  Widget build(VideoEmbedViewSpec spec) {
    specs.add(spec);
    return const SizedBox.expand(key: ValueKey('fake-embed-view'));
  }

  VideoEmbedViewSpec get last => specs.last;
}

LinkPreview _card(String url, {bool video = true, String? image}) =>
    LinkPreview(
      url: Uri.parse(url),
      title: 'Cabin tour by the lake',
      description: 'A weekend away',
      site: 'Site',
      imagePath: image,
      video: video,
    );

Message _msg(String id, String body, {LinkPreview? card, int minute = 0}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: 'u2',
      body: body,
      createdAt: DateTime.utc(2026, 10, 11, 9, minute),
      linkPreview: card,
    );

Finder _key(String k) => find.byKey(ValueKey(k));
Finder card(String id) => _key('link-card-$id');
final player = _key('video-player');
final refused = _key('video-player-refused');
final refusedOpen = _key('video-player-refused-open');

String textIn(Finder of) => [
  for (final e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
].join(' | ');

late View view;
late LinkOpenerFake opener;
late List<String> clipboard;

Future<ProviderContainer> pump(
  WidgetTester t,
  List<Message> messages, {
  Locale locale = const Locale('en'),
  Size phone = const Size(390, 844),
}) async {
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = phone * 3;
  addTearDown(t.view.reset);
  final chat = ChatFake(latency: const Duration(milliseconds: 5))
    ..messagesResult = Ok(messages);
  chat.store('c1/v1.jpg', pngBytes);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(opener),
        linkPreviewFetcherProvider.overrideWithValue(_NoFetch()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        videoEmbedViewProvider.overrideWithValue(view.build),
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
  return container;
}

/// One YouTube video card with a picture.
List<Message> oneVideo() => [
  _msg('v1', 'look $_yt', card: _card(_yt, image: 'c1/v1.jpg')),
];

bool hasPlay(WidgetTester t, String id, {String label = 'Play'}) =>
    t.getSemantics(card(id)).label.contains(label);

Future<void> openPlayer(WidgetTester t, [String id = 'v1']) async {
  await t.tap(card(id));
  await t.pumpAndSettle();
  expect(player, findsOneWidget);
}

Future<void> closeWithButton(WidgetTester t) async {
  await t.tap(_key('video-player-close'));
  await t.pumpAndSettle();
  expect(player, findsNothing);
}

Finder chipText(String site) =>
    find.descendant(of: player, matching: find.text(site));

AnimatedOpacity chipOpacity(WidgetTester t, String site) => t.widget(
  find
      .ancestor(of: chipText(site), matching: find.byType(AnimatedOpacity))
      .first,
);

/// The real fonts (Manrope, Roboto, Material icons), so a layout check
/// measures what a phone draws; copied from chat_delete_ui_test.dart.
Future<void> loadAppFonts() async {
  final manrope = FontLoader('Manrope');
  for (final w in [400, 500, 600, 700, 800]) {
    manrope.addFont(
      File('assets/fonts/Manrope-$w.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  }
  await manrope.load();
  final root = Platform.environment['FLUTTER_ROOT']!;
  final roboto = FontLoader('Roboto');
  final dir = Directory(
    '$root/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto',
  );
  for (final f in dir.listSync().whereType<File>()) {
    if (f.path.endsWith('.ttf')) {
      roboto.addFont(f.readAsBytes().then(ByteData.sublistView));
    }
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  await icons.load();
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    view = View();
    opener = LinkOpenerFake();
    clipboard = [];
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  void mockClipboard(WidgetTester t) => t.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });

  group('the card', () {
    for (final (locale, label) in [
      (const Locale('en'), 'Play'),
      (const Locale('tr'), 'Oynat'),
    ]) {
      testWidgets('an embeddable video card is labelled play ($locale)', (
        t,
      ) async {
        final h = t.ensureSemantics();
        await pump(t, oneVideo(), locale: locale);
        expect(hasPlay(t, 'v1', label: label), isTrue);
        h.dispose();
      });
    }

    testWidgets('nothing loads before the tap', (t) async {
      await pump(t, oneVideo());
      expect(view.specs, isEmpty);
      expect(player, findsNothing);
      expect(opener.opened, isEmpty);
    });

    for (final (name, m) in [
      (
        'a video card whose link cannot be embedded',
        _msg(
          'v1',
          'https://www.youtube.com/watch?v=abc',
          card: _card('https://www.youtube.com/watch?v=abc'),
        ),
      ),
      (
        'an embeddable link whose card is not a video',
        _msg('v1', _yt, card: _card(_yt, video: false)),
      ),
      (
        'a short link (vm.tiktok.com)',
        _msg(
          'v1',
          'https://vm.tiktok.com/ZMabcdef/',
          card: _card('https://vm.tiktok.com/ZMabcdef/'),
        ),
      ),
    ]) {
      testWidgets('$name: no play label, the tap opens it outside', (t) async {
        final h = t.ensureSemantics();
        await pump(t, [m]);
        expect(hasPlay(t, 'v1'), isFalse);
        await t.tap(card('v1'));
        await t.pumpAndSettle();
        expect(player, findsNothing);
        expect(view.specs, isEmpty);
        expect(opener.opened, [m.linkPreview!.url]);
        h.dispose();
      });
    }
  });

  group('opening', () {
    testWidgets('the sheet is there in the same frame as the tap, with the '
        'poster and a play mark, and never a spinner', (t) async {
      await pump(t, oneVideo());
      await t.tap(card('v1'));
      await t.pump();
      expect(player, findsOneWidget, reason: 'same frame as the tap');
      expect(
        find.descendant(of: player, matching: find.byType(Image)),
        findsWidgets,
        reason: 'the poster',
      );
      expect(
        find.descendant(of: player, matching: find.byType(Icon)),
        findsWidgets,
        reason: 'the dimmed play mark',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(opener.opened, isEmpty, reason: 'it plays inside SIS');
    });

    testWidgets('the view is built with the embed of that link', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      expect(view.specs, isNotEmpty);
      final e = view.last.embed;
      expect(e.site, VideoSite.youtube);
      expect(e.link, Uri.parse(_yt));
      expect(e.url, videoEmbedFor(Uri.parse(_yt))!.url);
    });

    testWidgets('the site chip is shown until the video loads, then fades in '
        '200 ms and never takes taps', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      expect(chipOpacity(t, 'YouTube').opacity, 1);
      expect(
        find.ancestor(
          of: chipText('YouTube'),
          matching: find.byWidgetPredicate(
            (w) => w is IgnorePointer && w.ignoring,
          ),
        ),
        findsWidgets,
      );
      view.last.onLoaded();
      await t.pumpAndSettle();
      expect(chipOpacity(t, 'YouTube').opacity, 0);
      expect(
        chipOpacity(t, 'YouTube').duration,
        const Duration(milliseconds: 200),
      );
    });

    testWidgets('the site chip also goes on a refusal', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      view.last.onRefused(VideoRefusal.deleted);
      await t.pumpAndSettle();
      expect(chipOpacity(t, 'YouTube').opacity, 0);
    });

    for (final (locale, line) in [
      (
        const Locale('en'),
        'YouTube sees your IP address and device while you watch. SIS deletes its cookies when you close.',
      ),
      (
        const Locale('tr'),
        'İzlerken YouTube IP adresinizi ve cihazınızı görür. Kapatınca SIS çerezlerini siler.',
      ),
    ]) {
      testWidgets('the privacy line ($locale)', (t) async {
        await pump(t, oneVideo(), locale: locale);
        await openPlayer(t);
        expect(_key('video-player-privacy'), findsOneWidget);
        expect(textIn(_key('video-player-privacy')), contains(line));
      });
    }
  });

  group('closing returns to the same place', () {
    List<Message> many() => [
      _msg('v1', 'look $_yt', card: _card(_yt, image: 'c1/v1.jpg')),
      for (var i = 1; i < 40; i++)
        _msg('p$i', 'message number $i with some words', minute: i),
    ];

    ScrollPosition list(WidgetTester t) => t
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .firstWhere((p) => p.maxScrollExtent > 0);

    for (final (how, close) in [
      ('the close button', closeWithButton),
      (
        'system back',
        (WidgetTester t) async {
          await t.binding.defaultBinaryMessenger.handlePlatformMessage(
            'flutter/navigation',
            const JSONMethodCodec().encodeMethodCall(
              const MethodCall('popRoute'),
            ),
            (_) {},
          );
          await t.pumpAndSettle();
        },
      ),
      (
        'a tap on the dimmed chat',
        (WidgetTester t) async {
          await t.tapAt(const Offset(20, 60));
          await t.pumpAndSettle();
        },
      ),
    ]) {
      testWidgets(how, (t) async {
        await pump(t, many());
        await t.scrollUntilVisible(
          card('v1'),
          200,
          scrollable: find
              .byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.up,
              )
              .first,
        );
        await t.pumpAndSettle();
        final before = list(t).pixels;
        expect(before, isNot(0), reason: 'the chat is scrolled');
        await openPlayer(t);
        await close(t);
        expect(player, findsNothing);
        expect(list(t).pixels, before);
        expect(card('v1'), findsOneWidget);
      });
    }
  });

  group('copy', () {
    testWidgets('copies the link and says so', (t) async {
      mockClipboard(t);
      await pump(t, oneVideo());
      await openPlayer(t);
      await t.tap(_key('video-player-copy'));
      await t.pump();
      expect(clipboard, [_yt]);
      expect(find.text('Link copied'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('a refused video', () {
    for (final (refusal, reason) in [
      (VideoRefusal.isPrivate, 'This video is private.'),
      (VideoRefusal.deleted, 'This video was deleted.'),
      (VideoRefusal.region, 'This video is not available in your region.'),
      (VideoRefusal.login, 'Sign in to watch this video.'),
      (VideoRefusal.other, 'This video could not be loaded.'),
    ]) {
      testWidgets('$refusal says why and offers YouTube', (t) async {
        await pump(t, oneVideo());
        await openPlayer(t);
        view.last.onRefused(refusal);
        await t.pumpAndSettle();
        expect(refused, findsOneWidget);
        final text = textIn(refused);
        expect(text, contains(reason));
        expect(text, contains('It cannot play inside SIS.'));
        expect(textIn(refusedOpen), contains('Open in YouTube'));
        expect(opener.opened, isEmpty, reason: 'nothing opens by itself');
      });
    }

    testWidgets('Turkish reason and button', (t) async {
      await pump(t, oneVideo(), locale: const Locale('tr'));
      await openPlayer(t);
      view.last.onRefused(VideoRefusal.isPrivate);
      await t.pumpAndSettle();
      expect(textIn(refused), contains('Bu video gizli.'));
      expect(textIn(refusedOpen), contains("YouTube'da aç"));
    });

    for (final (link, site, en) in [
      (
        'https://www.instagram.com/reel/C1a2B3c4D5e/',
        'Instagram',
        'Open in Instagram',
      ),
      (
        'https://www.tiktok.com/@u/video/7300000000000000000',
        'TikTok',
        'Open in TikTok',
      ),
      ('https://x.com/u/status/1234567890', 'X', 'Open in X'),
    ]) {
      testWidgets('$site: chip, privacy line and open button name the site', (
        t,
      ) async {
        await pump(t, [_msg('v1', link, card: _card(link))]);
        await openPlayer(t);
        expect(chipText(site), findsOneWidget);
        expect(
          textIn(_key('video-player-privacy')),
          contains(
            '$site sees your IP address and device while you watch. SIS deletes its cookies when you close.',
          ),
        );
        view.last.onRefused(VideoRefusal.other);
        await t.pumpAndSettle();
        expect(textIn(refusedOpen), contains(en));
      });
    }

    testWidgets('the open button opens the original link and closes the '
        'sheet', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      view.last.onRefused(VideoRefusal.region);
      await t.pumpAndSettle();
      await t.tap(refusedOpen);
      await t.pumpAndSettle();
      expect(opener.opened, [Uri.parse(_yt)]);
      expect(player, findsNothing);
    });

    testWidgets('after closing, the card offers opening outside and no '
        'longer plays; only that message is marked', (t) async {
      final h = t.ensureSemantics();
      final c = await pump(t, [
        _msg('v1', 'look $_yt', card: _card(_yt, image: 'c1/v1.jpg')),
        _msg('v2', _yt2, card: _card(_yt2), minute: 1),
      ]);
      await openPlayer(t);
      view.last.onRefused(VideoRefusal.deleted);
      await t.pumpAndSettle();
      expect(c.read(videoRefusedProvider), {'v1'});
      await closeWithButton(t);

      expect(_key('video-open-row-v1'), findsOneWidget);
      expect(hasPlay(t, 'v1'), isFalse);
      expect(_key('video-open-row-v2'), findsNothing);
      expect(hasPlay(t, 'v2'), isTrue, reason: 'refusal is per message');

      final loads = view.specs.length;
      await t.tap(card('v1'));
      await t.pumpAndSettle();
      expect(player, findsNothing);
      expect(view.specs.length, loads, reason: 'no second load');
      expect(opener.opened, [Uri.parse(_yt)]);

      await openPlayer(t, 'v2');
      h.dispose();
    });
  });

  group('the player tries to leave (outside main-frame navigation)', () {
    testWidgets('nothing is launched; the sheet says it could not load, '
        'once', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      view.last.onExternal(Uri.parse('https://evil.io/landing'));
      await t.pumpAndSettle();
      expect(opener.opened, isEmpty);
      expect(refused, findsOneWidget);
      expect(textIn(refused), contains('This video could not be loaded.'));
      view.last.onExternal(Uri.parse('https://evil.io/again'));
      await t.pumpAndSettle();
      expect(refused, findsOneWidget);
      expect(opener.opened, isEmpty);
    });

    testWidgets('the open button opens the ORIGINAL link, then the sheet '
        'closes', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      view.last.onExternal(Uri.parse('https://evil.io/landing'));
      await t.pumpAndSettle();
      await t.tap(refusedOpen);
      await t.pumpAndSettle();
      expect(opener.opened, [Uri.parse(_yt)]);
      expect(player, findsNothing);
    });

    testWidgets('it does not mark the message refused: the card still '
        'plays', (t) async {
      final h = t.ensureSemantics();
      final c = await pump(t, oneVideo());
      await openPlayer(t);
      view.last.onExternal(Uri.parse('https://evil.io/landing'));
      await t.pumpAndSettle();
      await closeWithButton(t);
      expect(c.read(videoRefusedProvider), isEmpty);
      expect(_key('video-open-row-v1'), findsNothing);
      expect(hasPlay(t, 'v1'), isTrue);
      h.dispose();
    });
  });

  group('platform look', () {
    Set<String> labels(WidgetTester t) => {
      for (final e
          in find
              .descendant(of: player, matching: find.byType(Text))
              .evaluate())
        ?(e.widget as Text).data,
    };
    const mixed = {'Close', 'Done', 'Copy link'};

    testWidgets('Android labels are upper-case', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      final shown = labels(t);
      expect(shown.intersection(mixed), isEmpty, reason: '$shown');
      expect(
        shown.intersection({for (final m in mixed) m.toUpperCase()}),
        isNotEmpty,
        reason: '$shown',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('iOS labels keep their case', (t) async {
      await pump(t, oneVideo());
      await openPlayer(t);
      final shown = labels(t);
      expect(shown.intersection(mixed), isNotEmpty, reason: '$shown');
      expect(
        shown.intersection({for (final m in mixed) m.toUpperCase()}),
        isEmpty,
        reason: '$shown',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  testWidgets('the sheet fits a phone held sideways (844 x 390)', (t) async {
    await pump(t, oneVideo(), phone: const Size(844, 390));
    await openPlayer(t);
    expect(t.takeException(), isNull, reason: 'no overflow');
  });

  test('without an override the view provider refuses to build', () {
    final c = ProviderContainer.test();
    expect(() => c.read(videoEmbedViewProvider), throwsA(anything));
  });
}
