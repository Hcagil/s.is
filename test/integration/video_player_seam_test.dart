@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/video_refused.dart';
import 'package:sis/features/chat/data/file_attachment_cache.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video_embed.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/video_player_sheet.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/service_key.dart';
import '../support/video_fakes.dart';

/// Video link cards across the real seam: ada's [SupabaseChatRepository]
/// stores a video card on the message; ben's message screen, mounted the way
/// `main.dart` mounts it over a real repository, shows the play mark, opens
/// the bottom player, and remembers a refusal for that message only.
///
/// The web view is a fake (it needs a device); auth stays a fake as in every
/// screen seam (Google sign-in has nothing to run against locally). Uses
/// vp-ada and vp-ben (supabase/seed.sql); run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

Future<SupabaseClient> _signedIn(String email) async {
  await setLocalTestPassword(_url, email, localTestPassword);
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
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

class _View {
  final specs = <VideoEmbedViewSpec>[];
  Widget build(VideoEmbedViewSpec spec) {
    specs.add(spec);
    return const SizedBox.expand();
  }
}

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok: $r');
  return (r as Ok<T>).value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient adaClient, benClient;
  late SupabaseChatRepository ada;
  late Member benMember;
  late String chat;
  late Directory tempRoot;

  setUpAll(() async {
    adaClient = await _signedIn('vp-ada@integration.test');
    benClient = await _signedIn('vp-ben@integration.test');
    ada = SupabaseChatRepository(adaClient);
    benMember = Member(
      userId: benClient.auth.currentUser!.id,
      displayName: 'Ben',
    );
    await findByTag(adaClient, [benClient]);
    chat = _ok(await ada.startDirectConversation(benMember.userId));
    tempRoot = await Directory.systemTemp.createTemp('vp-seam-');
  });

  tearDownAll(() async {
    await adaClient.dispose();
    await benClient.dispose();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  Future<String> sendVideo(String url) async {
    final id = randomMessageId();
    _ok(
      await ada.send(
        id: id,
        conversationId: chat,
        body: 'watch $url',
        preview: LinkPreviewDraft(
          preview: LinkPreview(
            url: Uri.parse(url),
            title: 'A video to watch',
            site: 'YouTube',
            video: true,
          ),
        ),
      ),
    );
    return id;
  }

  testWidgets('a video card sent through SIS plays for the reader; a refusal '
      'is remembered for that message only', (t) async {
    final stamp = DateTime.now().microsecondsSinceEpoch % 100000000;
    final idA = 'A${stamp.toString().padLeft(10, '0')}'.substring(0, 11);
    final idB = 'B${stamp.toString().padLeft(10, '0')}'.substring(0, 11);
    final urlA = 'https://youtu.be/$idA';
    final urlB = 'https://www.youtube.com/watch?v=$idB';
    final (m1, m2) = (await t.runAsync(() async {
      final a = await sendVideo(urlA);
      final b = await sendVideo(urlB);
      return (a, b);
    }))!;

    // The flag survives the round trip through the database.
    final read = (await t.runAsync(
      () => SupabaseChatRepository(benClient).messages(chat),
    ))!;
    final got = _ok(read).singleWhere((m) => m.id == m1);
    expect(got.linkPreview?.video, isTrue);
    expect(got.linkPreview?.url, Uri.parse(urlA));

    final view = _View();
    final opener = LinkOpenerFake();
    final cache = FileAttachmentCache(root: () async => tempRoot);
    final container = ProviderContainer(
      overrides: [
        ...videoOverrides(),
        authRepositoryProvider.overrideWithValue(
          FakeAuth(session: true, member: benMember),
        ),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(benClient, cache: cache),
        ),
        attachmentCacheProvider.overrideWithValue(cache),
        presenceRepositoryProvider.overrideWithValue(
          SupabasePresenceRepository(benClient),
        ),
        sessionControllerProvider.overrideWith(() => _SignedIn(benMember)),
        linkOpenerProvider.overrideWithValue(opener),
        videoEmbedViewProvider.overrideWithValue(view.build),
      ],
    );
    await settled(container);
    container.read(openConversationProvider.notifier).open(chat);
    t.view.devicePixelRatio = 3;
    t.view.physicalSize = const Size(390, 844) * 3;
    addTearDown(t.view.reset);
    final handle = t.ensureSemantics();
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: sisTheme(Brightness.light),
          home: const MessageScreen(title: 'Ada'),
        ),
      ),
    );
    Finder card(String id) => find.byKey(ValueKey('link-card-$id'));
    for (var i = 0; i < 100 && card(m2).evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(card(m1), findsOneWidget);
    expect(card(m2), findsOneWidget);
    bool plays(String id) => t.getSemantics(card(id)).label.contains('Play');
    expect(plays(m1), isTrue);
    expect(plays(m2), isTrue);
    expect(view.specs, isEmpty, reason: 'nothing loads before the tap');

    await t.tap(card(m1));
    await t.pump();
    expect(find.byKey(const ValueKey('video-player')), findsOneWidget);
    await t.pumpAndSettle();
    expect(view.specs.last.embed.link, Uri.parse(urlA));
    view.specs.last.onRefused(VideoRefusal.isPrivate);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('video-player-close')));
    await t.pumpAndSettle();

    expect(container.read(videoRefusedProvider), {m1});
    expect(find.byKey(ValueKey('video-open-row-$m1')), findsOneWidget);
    expect(plays(m1), isFalse);
    expect(plays(m2), isTrue, reason: 'only the refused message changes');
    expect(opener.opened, isEmpty);
    handle.dispose();
    // Unmount and let the screen's own timers run out, as message_screen_seam.
    await t.pumpWidget(const SizedBox());
    container.dispose();
    await t.pump(const Duration(seconds: 61));
  });
}
