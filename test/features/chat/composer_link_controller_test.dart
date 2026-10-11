// ComposerLinkController and the send queue's side of link cards, written
// from the contract: onTextChanged (500 ms pause), dismiss (the link goes as
// plain text), takeForSend(body) (sending never waits: whatever is ready at
// that moment, else nothing), reset; SendQueueController.enqueue(preview:)
// and pendingLinkImage(path).
//
// The fake fetcher answers only when the test says so: a page that is slow,
// one that answers after the link was edited away, one with no card.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/link_preview_controller.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/link_preview_fetcher.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

/// A fetcher whose every page answers when the test completes it.
class HeldFetcher implements LinkPreviewFetcher {
  final asked = <Uri>[];
  final _answers = <Completer<LinkPreviewDraft?>>[];

  @override
  Future<LinkPreviewDraft?> fetch(Uri url) {
    asked.add(url);
    final c = Completer<LinkPreviewDraft?>();
    _answers.add(c);
    return c.future;
  }

  /// Answers fetch [i] with a card for its url (or [draft] when given).
  void answer(int i, {LinkPreviewDraft? draft, bool none = false}) =>
      _answers[i].complete(none ? null : (draft ?? card(asked[i])));
}

final picture = Uint8List.fromList([9, 8, 7]);

LinkPreviewDraft card(Uri url, {bool withPicture = true}) => LinkPreviewDraft(
  preview: LinkPreview(url: url, title: 'Title of ${url.path}', site: 'Ex'),
  image: withPicture ? picture : null,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

const _me = Member(userId: 'u1', displayName: 'Maya');
const debounce = Duration(milliseconds: 500);

void main() {
  late HeldFetcher fetcher;
  late ChatFake chat;
  late ProviderContainer c;

  Future<void> start(WidgetTester t) async {
    fetcher = HeldFetcher();
    chat = ChatFake();
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        linkPreviewFetcherProvider.overrideWithValue(fetcher),
      ],
    );
    c.listen(composerLinkProvider, (_, _) {});
    await t.runAsync(() => c.read(sessionControllerProvider.future));
  }

  ComposerLinkController link() => c.read(composerLinkProvider.notifier);
  ComposerLink? strip() => c.read(composerLinkProvider);
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.pump();
    }
  }

  group('onTextChanged', () {
    testWidgets('no page is read before the 500 ms pause; one after it', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('look https://example.com/a');
      await t.pump(debounce - const Duration(milliseconds: 50));
      expect(fetcher.asked, isEmpty);
      await t.pump(const Duration(milliseconds: 60));
      expect(fetcher.asked, [Uri.parse('https://example.com/a')]);
    });

    testWidgets(
      'typing keeps restarting the pause; only the last link is read',
      (t) async {
        await start(t);
        link().onTextChanged('https://example.com/x');
        await t.pump(const Duration(milliseconds: 300));
        link().onTextChanged('https://example.com/xy');
        await t.pump(const Duration(milliseconds: 300));
        link().onTextChanged('https://example.com/xyz');
        await t.pump(debounce + const Duration(milliseconds: 10));
        expect(fetcher.asked, [Uri.parse('https://example.com/xyz')]);
      },
    );

    testWidgets('the strip shows the card once the page answered', (t) async {
      await start(t);
      link().onTextChanged('see https://example.com/a now');
      await t.pump(debounce);
      expect(strip(), isNull, reason: 'not ready yet: no strip');
      fetcher.answer(0);
      await settle(t);
      expect(strip()?.url, Uri.parse('https://example.com/a'));
      expect(strip()?.draft.preview.title, 'Title of /a');
    });

    testWidgets('only the first link of the text is read', (t) async {
      await start(t);
      link().onTextChanged(
        'https://first.example/a and https://second.example/b',
      );
      await t.pump(debounce);
      expect(fetcher.asked, [Uri.parse('https://first.example/a')]);
    });

    testWidgets('text without a link reads nothing', (t) async {
      await start(t);
      link().onTextChanged('hello there, no link');
      await t.pump(debounce * 2);
      expect(fetcher.asked, isEmpty);
      expect(strip(), isNull);
    });

    testWidgets('a link is read once: more typing around it asks nothing new', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().onTextChanged('https://example.com/a is nice');
      await t.pump(debounce * 2);
      expect(fetcher.asked, hasLength(1));
      expect(strip()?.url, Uri.parse('https://example.com/a'));
    });

    testWidgets('a page with no card shows no strip', (t) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0, none: true);
      await settle(t);
      expect(strip(), isNull);
    });

    testWidgets('a late answer for a link that was edited away is dropped', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/old');
      await t.pump(debounce);
      link().onTextChanged('no link any more');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      expect(strip(), isNull);
    });

    testWidgets(
      'a late answer for the previous link never replaces the new one',
      (t) async {
        await start(t);
        link().onTextChanged('https://example.com/old');
        await t.pump(debounce);
        link().onTextChanged('https://example.com/new');
        await t.pump(debounce);
        expect(fetcher.asked.last, Uri.parse('https://example.com/new'));
        fetcher.answer(1);
        await settle(t);
        fetcher.answer(0);
        await settle(t);
        expect(strip()?.url, Uri.parse('https://example.com/new'));
      },
    );

    testWidgets('removing the link hides a ready strip', (t) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().onTextChanged('');
      await t.pump(debounce);
      expect(strip(), isNull);
    });
  });

  group('dismiss', () {
    testWidgets('X hides the strip and the message goes as plain text', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().dismiss();
      expect(strip(), isNull);
      expect(link().takeForSend('https://example.com/a'), isNull);
    });

    testWidgets('a dismissed link is not read or shown again while typing on', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().dismiss();
      link().onTextChanged('https://example.com/a more words');
      await t.pump(debounce * 2);
      expect(fetcher.asked, hasLength(1));
      expect(strip(), isNull);
      expect(link().takeForSend('https://example.com/a more words'), isNull);
    });

    testWidgets('after a reset (sent, other chat) the same link gets a card '
        'again', (t) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().dismiss();
      link().reset();
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      expect(fetcher.asked, hasLength(2));
      fetcher.answer(1);
      await settle(t);
      expect(strip(), isNotNull);
    });

    testWidgets('X while the page is still loading: its answer is dropped', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      link().dismiss();
      fetcher.answer(0);
      await settle(t);
      expect(strip(), isNull);
      expect(link().takeForSend('https://example.com/a'), isNull);
    });
  });

  group('takeForSend (sending never waits)', () {
    testWidgets('a ready card is handed over once, then the strip is gone', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      final taken = link().takeForSend('https://example.com/a');
      expect(taken?.preview.url, Uri.parse('https://example.com/a'));
      expect(taken?.image, picture);
      expect(strip(), isNull);
      expect(link().takeForSend('https://example.com/a'), isNull);
    });

    testWidgets(
      'a card still loading: null at once, and its answer is dropped',
      (t) async {
        await start(t);
        link().onTextChanged('https://example.com/a');
        await t.pump(debounce);
        expect(link().takeForSend('https://example.com/a'), isNull);
        fetcher.answer(0);
        await settle(t);
        expect(
          strip(),
          isNull,
          reason: 'the sent text must not get a late strip',
        );
      },
    );

    testWidgets(
      'sent before the pause ended: null, and nothing is read after',
      (t) async {
        await start(t);
        link().onTextChanged('https://example.com/a');
        await t.pump(const Duration(milliseconds: 100));
        expect(link().takeForSend('https://example.com/a'), isNull);
        await t.pump(debounce * 2);
        expect(fetcher.asked, isEmpty);
      },
    );

    testWidgets('a card for another link than the one sent is not attached', (
      t,
    ) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      expect(link().takeForSend('now https://other.example/b'), isNull);
    });

    testWidgets('reset clears the strip and a pending read', (t) async {
      await start(t);
      link().onTextChanged('https://example.com/a');
      await t.pump(debounce);
      fetcher.answer(0);
      await settle(t);
      link().reset();
      expect(strip(), isNull);
      link().onTextChanged('https://example.com/b');
      await t.pump(const Duration(milliseconds: 100));
      link().reset();
      await t.pump(debounce * 2);
      expect(fetcher.asked, hasLength(1));
    });
  });

  group('send queue with a card', () {
    testWidgets('the pending bubble carries the card; the picture path is '
        '<conversation>/<message id>.jpg; the server gets the card', (t) async {
      await start(t);
      final draft = card(Uri.parse('https://example.com/a'));
      final m = c
          .read(sendQueueProvider.notifier)
          .enqueue('c1', body: 'https://example.com/a', preview: draft);
      expect(m.linkPreview?.title, 'Title of /a');
      expect(m.linkPreview?.imagePath, linkImagePath('c1', m.id));
      expect(
        c
            .read(sendQueueProvider.notifier)
            .pendingLinkImage(linkImagePath('c1', m.id)),
        picture,
        reason: 'the sender sees her own picture before the upload',
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(t);
      expect(chat.sentIds, [m.id]);
      final sent = chat.sentPreviews.single!;
      expect(sent.preview.imagePath, linkImagePath('c1', m.id));
      expect(sent.image, picture);
      expect(sent.preview.url, Uri.parse('https://example.com/a'));
    });

    testWidgets('a card without a picture names no picture path', (t) async {
      await start(t);
      final m = c
          .read(sendQueueProvider.notifier)
          .enqueue(
            'c1',
            body: 'https://example.com/a',
            preview: card(
              Uri.parse('https://example.com/a'),
              withPicture: false,
            ),
          );
      expect(m.linkPreview, isNotNull);
      expect(m.linkPreview!.imagePath, isNull);
    });

    testWidgets('without a card the message has none', (t) async {
      await start(t);
      final m = c
          .read(sendQueueProvider.notifier)
          .enqueue('c1', body: 'https://example.com/a');
      expect(m.linkPreview, isNull);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(t);
      expect(chat.sentPreviews, [null]);
    });

    testWidgets('the sender\'s own card picture comes from the queue, not '
        'from storage', (t) async {
      await start(t);
      final m = c
          .read(sendQueueProvider.notifier)
          .enqueue(
            'c1',
            body: 'https://example.com/a',
            preview: card(Uri.parse('https://example.com/a')),
          );
      final path = linkImagePath('c1', m.id);
      final shown = c.read(linkImageProvider(path).future);
      expect(await t.runAsync(() => shown), picture);
      expect(chat.calls, isNot(contains('linkImageBytes:$path')));
    });

    testWidgets('a received card picture is read from storage', (t) async {
      await start(t);
      chat.store('c1/m9.jpg', picture);
      final shown = c.read(linkImageProvider('c1/m9.jpg').future);
      expect(await t.runAsync(() => shown), picture);
      expect(chat.calls, contains('linkImageBytes:c1/m9.jpg'));
    });

    testWidgets('pendingLinkImage knows only queued pictures', (t) async {
      await start(t);
      expect(
        c.read(sendQueueProvider.notifier).pendingLinkImage('c1/nope.jpg'),
        isNull,
      );
    });
  });
}
