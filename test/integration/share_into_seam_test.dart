@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as img;
import 'package:sis/app/notice.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/link_preview_controller.dart';
import 'package:sis/features/chat/application/share_controller.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/link_preview_fetcher.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/shared_content.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/presentation/share_page.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/dead_host.dart';
import '../support/fakes.dart';
import '../support/l10n.dart';
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// Share into SIS across the real seam: what another app shared waits in the
/// intake (a stand-in for the platform door, below), [ShareHost] shows it in
/// the Forward picker as SisApp mounts it, reid ticks chats and taps Send, and
/// cora -- a member of every chat -- reads back what the real
/// [SupabaseChatRepository] stored. Nothing is sent before Send; the
/// unticked chat gains nothing; files are discarded once handled.
///
/// Requires `docker compose run --rm supabase start`. Uses reid and cora
/// (supabase/seed.sql), new groups each run; run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client(_key);
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

/// The platform door as the contract describes it: one share waits until
/// taken (then forgotten), photos are read from their cache file (a missing
/// file is unreadable), discard deletes the files. Every call is recorded.
class _Intake implements ShareIntake {
  _Intake(this.waiting);
  SharedContent? waiting;
  final discarded = <SharedContent>[];
  final arrived = StreamController<void>.broadcast();
  var takes = 0;

  @override
  Future<SharedContent?> take() async {
    takes++;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final c = waiting;
    waiting = null;
    return c;
  }

  @override
  Stream<void> get arrivals => arrived.stream;

  @override
  Future<PickedImage?> readPhoto(SharedItem item) async {
    final f = File(item.path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    return PickedImage(
      bytes: bytes,
      contentType: 'image/jpeg',
      extension: 'jpg',
    );
  }

  @override
  Future<void> discard(SharedContent content) async {
    discarded.add(content);
    for (final i in content.items) {
      final f = File(i.path);
      if (f.existsSync()) f.deleteSync();
    }
  }
}

/// Imports like FileVideoImporter: a video named `long*` is over the limit;
/// any other gets its own copy in a new folder per call.
class _Importer implements SharedVideoImporter {
  _Importer(this.dir);
  final Directory dir;
  final calls = <SharedItem>[];
  final copies = <String>[];

  @override
  Future<({VideoSource? source, bool tooLong})> importVideo(
    SharedItem item,
  ) async {
    calls.add(item);
    if (item.name.startsWith('long')) return (source: null, tooLong: true);
    final own = Directory('${dir.path}/v${calls.length}')..createSync();
    final copy = File(item.path).copySync('${own.path}/video.mp4');
    copies.add(copy.path);
    File('${own.path}/thumb.jpg').writeAsBytesSync(_jpeg(4, 3, 1));
    return (
      source: VideoSource(
        id: 'v${calls.length}',
        path: copy.path,
        name: item.name,
        size: copy.lengthSync(),
        durationMs: 2000,
        width: 320,
        height: 240,
        thumbPath: '${own.path}/thumb.jpg',
      ),
      tooLong: false,
    );
  }
}

/// Reads a page as the real fetcher would, without the network: a card for
/// every link, every fetch recorded.
class _Fetcher implements LinkPreviewFetcher {
  final fetched = <Uri>[];
  @override
  Future<LinkPreviewDraft?> fetch(Uri url) async {
    fetched.add(url);
    return LinkPreviewDraft(
      preview: LinkPreview(
        url: url,
        title: 'Shared page',
        description: 'about it',
        site: 'Example',
      ),
    );
  }
}

/// A real JPEG of [w] x [h], tagged by its first pixel so each is its own.
Uint8List _jpeg(int w, int h, int tag) {
  final im = img.Image(width: w, height: h);
  im.setPixelRgb(0, 0, tag, 0, 0);
  return img.encodeJpg(im);
}

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  SupabaseClient? reidClient;
  SupabaseClient? coraClient;
  late SupabaseChatRepository reid;
  late SupabaseChatRepository cora;
  late Member reidMember;
  late Directory dir;
  final l = l10nEn;

  setUpAll(() async {
    // Own accounts (seed.sql): files with a fixed password are locked out of any account localTestPassword moves.
    reidClient = await _signedIn('shr-a@integration.test');
    coraClient = await _signedIn('shr-b@integration.test');
    reid = SupabaseChatRepository(reidClient!);
    cora = SupabaseChatRepository(coraClient!);
    reidMember = Member(
      userId: reidClient!.auth.currentUser!.id,
      displayName: 'Reid',
    );
    await findByTag(reidClient!, [coraClient!]);
    dir = await Directory.systemTemp.createTemp('share-into-');
  });

  tearDownAll(() async {
    await reidClient?.dispose();
    await coraClient?.dispose();
  });

  Future<String> group(String title) async {
    final r = await reid.startGroupConversation(
      title: title,
      memberIds: [coraClient!.auth.currentUser!.id],
    );
    return (r as Ok<String>).value;
  }

  Future<List<Message>> seen(String c) async =>
      ((await cora.messages(c)) as Ok<List<Message>>).value;

  /// Notice texts seen while waiting (each lasts about 2 s).
  final notices = <String>{};
  void collect(WidgetTester t) {
    for (final e in find.byType(SisNotice).evaluate()) {
      notices.add((e.widget as SisNotice).message);
    }
  }

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 600; i++) {
      collect(t);
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail('never happened: $what');
  }

  Future<List<Message>> untilSeen(
    WidgetTester t,
    String c,
    bool Function(List<Message>) ok,
    String what,
  ) async {
    var got = <Message>[];
    for (var i = 0; i < 150; i++) {
      got = (await t.runAsync(() => seen(c)))!;
      if (ok(got)) return got;
      collect(t);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump();
    }
    fail(
      'never happened in $c: $what; have ${got.map((m) => m.body)}; notices $notices',
    );
  }

  Future<ProviderContainer> mount(
    WidgetTester t,
    _Intake intake,
    _Importer importer,
    _Fetcher fetcher,
  ) async {
    notices.clear();
    final container = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(reid),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
        shareIntakeProvider.overrideWithValue(intake),
        sharedVideoImporterProvider.overrideWithValue(importer),
        linkPreviewFetcherProvider.overrideWithValue(fetcher),
      ],
    );
    await t.runAsync(() => settled(container));
    // Held from the start, as SessionGate holds it.
    container.listen(pendingShareProvider, (_, _) {});
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: sisTheme(Brightness.light),
          home: const ShareHost(child: Scaffold(body: Text('home'))),
        ),
      ),
    );
    await until(
      t,
      () => find.byKey(const ValueKey('forward-page')).evaluate().isNotEmpty,
      'the share picker',
    );
    return container;
  }

  /// Finds [c] through the search box (the group title) and ticks it.
  Future<void> tick(WidgetTester t, String title, String c) async {
    await t.enterText(find.byKey(const ValueKey('forward-search')), title);
    final row = find.byKey(ValueKey('forward-$c'));
    await until(t, () => row.hitTestable().evaluate().isNotEmpty, 'row $c');
    await t.tap(row);
    await t.pump();
    await t.enterText(find.byKey(const ValueKey('forward-search')), '');
    await t.pump();
  }

  Future<void> unmount(WidgetTester t, ProviderContainer c) async {
    await t.pumpWidget(const SizedBox());
    c.dispose();
    await t.runAsync(() => reidClient!.removeAllChannels());
    await t.runAsync(() => reidClient!.realtime.disconnect());
  }

  testWidgets('text with a link, photos, a caption: each ticked chat gets '
      'them; nothing before Send; the unticked chat nothing', (t) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g0 = (await t.runAsync(() => group('SH0 $stamp')))!;
    final g1 = (await t.runAsync(() => group('SH1 $stamp')))!;
    final g2 = (await t.runAsync(() => group('SH2 $stamp')))!;

    // A tall and a wide photo: aspect must survive (no forced square crop).
    final tall = _jpeg(4, 8, 10);
    final wide = _jpeg(8, 4, 20);
    final a = File('${dir.path}/a$stamp.jpg')..writeAsBytesSync(tall);
    final b = File('${dir.path}/b$stamp.jpg')..writeAsBytesSync(wide);
    final longVideo = File('${dir.path}/long$stamp.mp4')
      ..writeAsBytesSync([0, 0, 0, 1]);
    final link = 'https://example.com/share-$stamp';
    final text = 'have a look $link';
    final content = SharedContent(
      text: text,
      items: [
        SharedItem(path: a.path, name: 'a.jpg', isVideo: false),
        SharedItem(
          path: '${dir.path}/gone$stamp.jpg',
          name: 'gone.jpg',
          isVideo: false,
        ),
        SharedItem(path: b.path, name: 'b.jpg', isVideo: false),
        SharedItem(path: longVideo.path, name: 'long.mp4', isVideo: true),
      ],
    );
    final intake = _Intake(content);
    final importer = _Importer(dir);
    final fetcher = _Fetcher();
    final container = await mount(t, intake, importer, fetcher);

    expect(find.byKey(const ValueKey('share-strip-thumb')), findsWidgets);
    await tick(t, 'SH1 $stamp', g1);
    await tick(t, 'SH2 $stamp', g2);
    await t.enterText(
      find.byKey(const ValueKey('share-caption')),
      'caption $stamp',
    );
    await t.pump();

    // Nothing leaves before Send.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    for (final c in [g1, g2]) {
      expect(
        await t.runAsync(() => seen(c)),
        isEmpty,
        reason: 'sent before Send ($c)',
      );
    }
    expect(intake.discarded, isEmpty, reason: 'discarded before Send');

    await t.tap(find.byKey(const ValueKey('forward-send')));
    await t.pump();
    // Same frame: the picker answers at once with the sending state.
    expect(
      find.text(l.shareSending).evaluate().isNotEmpty ||
          find.byKey(const ValueKey('forward-page')).evaluate().isEmpty,
      isTrue,
      reason: 'Send gave no answer in the frame of the tap',
    );

    for (final c in [g1, g2]) {
      final got = await untilSeen(
        t,
        c,
        (ms) =>
            ms.where((m) => m.attachmentPath != null).length >= 2 &&
            ms.any((m) => m.body.contains(link)) &&
            ms.any((m) => m.body.contains('caption $stamp')),
        'two photos, the text and the caption',
      );
      final photos = got.where((m) => m.attachmentPath != null).toList();
      expect(photos, hasLength(2), reason: 'photos in $c (one unreadable)');
      final shapes = <(int, int)>{};
      for (final p in photos) {
        final bytes = await t.runAsync(
          () => cora.attachmentBytes(p.attachmentPath!),
        );
        final im = img.decodeJpg((bytes! as Ok<Uint8List>).value);
        shapes.add((im.width, im.height));
      }
      expect(shapes, {
        (4, 8),
        (8, 4),
      }, reason: 'a shared photo lost its shape in $c');
      final withLink = got.where((m) => m.body.contains(link)).toList();
      expect(withLink, hasLength(1), reason: 'the shared text in $c');
      expect(
        withLink.single.linkPreview?.url,
        Uri.parse(link),
        reason: 'the link card did not reach $c',
      );
      expect(
        got.where((m) => m.body.contains('caption $stamp')),
        hasLength(1),
        reason: 'the caption in $c, once',
      );
    }
    expect(
      await t.runAsync(() => seen(g0)),
      isEmpty,
      reason: 'the unticked chat got a message',
    );

    await until(t, () => intake.discarded.isNotEmpty, 'the files discarded');
    expect(intake.discarded.single, same(content));
    expect(a.existsSync() || b.existsSync(), isFalse);
    expect(container.read(pendingShareProvider), isNull);
    await until(
      t,
      () => notices.contains(l.videoTooLong(1)),
      'the over-long video notice',
    );
    expect(
      notices.contains(l.videoTooLong(2)),
      isFalse,
      reason: 'one over-long video counted once per chat',
    );
    await until(
      t,
      () => notices.contains(l.shareUnreadable(1)),
      'the unreadable photo notice',
    );
    await unmount(t, container);
  });

  testWidgets('a video gets its own copy for each message', (t) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = (await t.runAsync(() => group('SV1 $stamp')))!;
    final g2 = (await t.runAsync(() => group('SV2 $stamp')))!;
    final v = File('${dir.path}/clip$stamp.mp4')
      ..writeAsBytesSync(List.filled(64, 7));
    final intake = _Intake(
      SharedContent(
        items: [SharedItem(path: v.path, name: 'clip.mp4', isVideo: true)],
      ),
    );
    final importer = _Importer(dir);
    final container = await mount(t, intake, importer, _Fetcher());
    await tick(t, 'SV1 $stamp', g1);
    await tick(t, 'SV2 $stamp', g2);
    await t.tap(find.byKey(const ValueKey('forward-send')));
    await until(t, () => intake.discarded.isNotEmpty, 'the share handled');
    expect(
      importer.calls,
      hasLength(2),
      reason: 'one import (own folder) per message',
    );
    expect(importer.copies.toSet(), hasLength(2));
    await unmount(t, container);
  });

  for (final (n, want) in [(3000, null), (5000, 4000)]) {
    testWidgets(
      'shared text of $n characters arrives ${want == null ? 'whole' : 'cut to $want'}',
      (t) async {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final g1 = (await t.runAsync(() => group('SL1 $stamp')))!;
        final head = 'L$stamp ';
        final text = head + 'x' * (n - head.length);
        final intake = _Intake(SharedContent(text: text));
        final container = await mount(t, intake, _Importer(dir), _Fetcher());
        await tick(t, 'SL1 $stamp', g1);
        await t.tap(find.byKey(const ValueKey('forward-send')));
        final got = await untilSeen(
          t,
          g1,
          (ms) => ms.any((m) => m.body.startsWith(head)),
          'the $n-character text',
        );
        final m = got.singleWhere((m) => m.body.startsWith(head));
        expect(m.body, text.substring(0, want ?? n));
        await unmount(t, container);
      },
    );
  }

  testWidgets('shared text whose unit 3999 is a lead surrogate arrives cut to '
      '3999 units', (t) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = (await t.runAsync(() => group('SS1 $stamp')))!;
    final head = 'S$stamp ';
    final text = '$head${'x' * (3999 - head.length)}\u{1F600}${'y' * 100}';
    expect(text.codeUnitAt(3999), inInclusiveRange(0xD800, 0xDBFF));
    final intake = _Intake(SharedContent(text: text));
    final container = await mount(t, intake, _Importer(dir), _Fetcher());
    await tick(t, 'SS1 $stamp', g1);
    await t.tap(find.byKey(const ValueKey('forward-send')));
    final got = await untilSeen(
      t,
      g1,
      (ms) => ms.any((m) => m.body.startsWith(head)),
      'the surrogate-cut text',
    );
    expect(
      got.singleWhere((m) => m.body.startsWith(head)).body,
      text.substring(0, 3999),
    );
    await unmount(t, container);
  });

  testWidgets('the caption arrives even when the first photo is unreadable', (
    t,
  ) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = (await t.runAsync(() => group('SU1 $stamp')))!;
    final b = File('${dir.path}/u$stamp.jpg')..writeAsBytesSync(_jpeg(3, 2, 5));
    final intake = _Intake(
      SharedContent(
        items: [
          SharedItem(
            path: '${dir.path}/gone-u$stamp.jpg',
            name: 'gone.jpg',
            isVideo: false,
          ),
          SharedItem(path: b.path, name: 'u.jpg', isVideo: false),
        ],
      ),
    );
    final container = await mount(t, intake, _Importer(dir), _Fetcher());
    await tick(t, 'SU1 $stamp', g1);
    await t.enterText(
      find.byKey(const ValueKey('share-caption')),
      'ucap $stamp',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('forward-send')));
    await until(t, () => intake.discarded.isNotEmpty, 'the share handled');
    await untilSeen(
      t,
      g1,
      (ms) =>
          ms.any((m) => m.attachmentPath != null) &&
          ms.any((m) => m.body.contains('ucap $stamp')),
      'the readable photo and the one caption',
    );
    await unmount(t, container);
  });

  testWidgets('the caption arrives when no shared photo can be read', (
    t,
  ) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = (await t.runAsync(() => group('SU2 $stamp')))!;
    final intake = _Intake(
      SharedContent(
        items: [
          SharedItem(
            path: '${dir.path}/gone-v$stamp.jpg',
            name: 'gone.jpg',
            isVideo: false,
          ),
        ],
      ),
    );
    final container = await mount(t, intake, _Importer(dir), _Fetcher());
    await tick(t, 'SU2 $stamp', g1);
    await t.enterText(
      find.byKey(const ValueKey('share-caption')),
      'vcap $stamp',
    );
    await t.pump();
    await t.tap(find.byKey(const ValueKey('forward-send')));
    await until(t, () => intake.discarded.isNotEmpty, 'the share handled');
    await untilSeen(
      t,
      g1,
      (ms) => ms.any((m) => m.body.contains('vcap $stamp')),
      'the typed caption',
    );
    await unmount(t, container);
  });

  test('offline: shared text is queued like a typed message', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = await group('SO1 $stamp');
    final dead = await deadButSignedIn(reidClient!);
    addTearDown(dead.dispose);
    final store = SendQueueStoreFake();
    final container = ProviderContainer(
      overrides: [
        ...videoOverrides(store: store),
        chatRepositoryProvider.overrideWithValue(SupabaseChatRepository(dead)),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
        shareIntakeProvider.overrideWithValue(_Intake(null)),
        sharedVideoImporterProvider.overrideWithValue(_Importer(dir)),
        linkPreviewFetcherProvider.overrideWithValue(_Fetcher()),
      ],
    );
    addTearDown(container.dispose);
    await settled(container);
    container.listen(pendingShareProvider, (_, _) {});
    final out = await container
        .read(pendingShareProvider.notifier)
        .send(
          SharedContent(text: 'offline $stamp'),
          chatIds: [g1],
          personIds: const [],
          caption: '',
        );
    expect(out.result, isA<Ok<void>>(), reason: 'offline text is not an error');
    for (var i = 0; i < 50; i++) {
      if (store.records(reidMember.userId).isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final queued = store.records(reidMember.userId);
    expect(
      queued.map((r) => (r.conversationId, r.body)),
      contains((g1, 'offline $stamp')),
      reason: 'not kept in the send queue for later',
    );
  });

  testWidgets('Cancel sends nothing and discards the files', (t) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final g1 = (await t.runAsync(() => group('SC1 $stamp')))!;
    final a = File('${dir.path}/c$stamp.jpg')..writeAsBytesSync(_jpeg(2, 2, 1));
    final content = SharedContent(
      text: 'cancel $stamp',
      items: [SharedItem(path: a.path, name: 'c.jpg', isVideo: false)],
    );
    final intake = _Intake(content);
    final container = await mount(t, intake, _Importer(dir), _Fetcher());
    await tick(t, 'SC1 $stamp', g1);
    final nav = t.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.maybePop());
    await until(
      t,
      () => find.byKey(const ValueKey('forward-page')).evaluate().isEmpty,
      'the picker closed',
    );
    await until(t, () => intake.discarded.isNotEmpty, 'the files discarded');
    expect(intake.discarded.single, same(content));
    expect(a.existsSync(), isFalse, reason: 'the photo file is left behind');
    expect(container.read(pendingShareProvider), isNull);
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    expect(
      await t.runAsync(() => seen(g1)),
      isEmpty,
      reason: 'Cancel sent the share',
    );
    await unmount(t, container);
  });

  testWidgets('a share arriving while the app runs is shown', (t) async {
    final intake = _Intake(null);
    final container = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(reid),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(() => _SignedIn(reidMember)),
        shareIntakeProvider.overrideWithValue(intake),
        sharedVideoImporterProvider.overrideWithValue(_Importer(dir)),
        linkPreviewFetcherProvider.overrideWithValue(_Fetcher()),
      ],
    );
    await t.runAsync(() => settled(container));
    container.listen(pendingShareProvider, (_, _) {});
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: localizedApp(
          home: const ShareHost(child: Scaffold(body: Text('home'))),
        ),
      ),
    );
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pump();
    expect(find.byKey(const ValueKey('forward-page')), findsNothing);
    intake.waiting = const SharedContent(text: 'later');
    intake.arrived.add(null);
    await until(
      t,
      () => find.byKey(const ValueKey('forward-page')).evaluate().isNotEmpty,
      'the late share shown',
    );
    await unmount(t, container);
  });
}
