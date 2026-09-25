@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
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
import 'package:sis/features/chat/data/file_attachment_cache.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

/// The message screen mounted exactly as `main.dart` wires it, over a real
/// [SupabaseChatRepository] and a real [FileAttachmentCache] on a temporary
/// directory.
///
/// Every provider-level test proves that bytes come back correctly; none of
/// them can prove that the *screen*, wired the way production wires it, ever
/// shows the preview and then the photo, or that reopening the conversation
/// asks the real on-disk cache first rather than the network.
///
/// Google sign-in has nothing to run against locally (docs/ARCHITECTURE.md),
/// so auth stays a fake; presence is a real, reachable client so nothing
/// about it needs a reason of its own. Only the photo picker is a fake
/// (nothing is sent from this screen).
///
/// Requires `docker compose run --rm supabase start`. Uses walt and xena
/// (supabase/seed.sql); run with --concurrency=1 like the rest of the suite.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

/// A real 1x1 PNG, used as both the photo and its own "preview": the
/// constraint only cares that a preview decodes as base64 PNG data starting
/// with the signature, not that it is actually smaller than the photo.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Wraps a real [AttachmentCache] so a test can hold its next [read] open --
/// the moment before a fetch answers, which a real download never skips but
/// a fake finishing synchronously always would.
class _HoldableCache implements AttachmentCache {
  _HoldableCache(this._inner);
  final AttachmentCache _inner;
  Completer<void>? _hold;

  void holdRead() => _hold = Completer<void>();
  void releaseRead() {
    _hold?.complete();
    _hold = null;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final held = _hold;
    if (held != null) await held.future;
    return _inner.read(path);
  }

  @override
  Future<void> write(String path, Uint8List bytes) => _inner.write(path, bytes);
  @override
  Future<void> remove(String path) => _inner.remove(path);
  @override
  Future<void> clear() => _inner.clear();
}

/// Wraps a real [AttachmentCache], recording every [read] as a hit or a
/// miss -- proof that a call answered from disk, never that it merely
/// happened to be fast.
class _SpyCache implements AttachmentCache {
  _SpyCache(this._inner);
  final AttachmentCache _inner;
  final hits = <String>[];
  final misses = <String>[];

  @override
  Future<Uint8List?> read(String path) async {
    final value = await _inner.read(path);
    (value != null ? hits : misses).add(path);
    return value;
  }

  @override
  Future<void> write(String path, Uint8List bytes) => _inner.write(path, bytes);
  @override
  Future<void> remove(String path) => _inner.remove(path);
  @override
  Future<void> clear() => _inner.clear();
}

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

class _SignedIn extends SessionController {
  _SignedIn(this.member);
  final Member member;
  @override
  Future<SessionState> build() async => Allowed(member);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late SupabaseClient waltClient;
  late SupabaseClient xenaClient;
  late SupabaseChatRepository walt;
  late Member xenaMember;
  late String conversationId;
  late Directory tempRoot;

  setUpAll(() async {
    waltClient = await _signedIn('walt@integration.test');
    xenaClient = await _signedIn('xena@integration.test');
    walt = SupabaseChatRepository(waltClient);
    xenaMember = Member(
      userId: xenaClient.auth.currentUser!.id,
      displayName: 'Xena',
    );

    final started = await walt.startDirectConversation(xenaMember.userId);
    expect(started, isA<Ok<String>>());
    conversationId = (started as Ok<String>).value;
    tempRoot = await Directory.systemTemp.createTemp('seam-cache-');
  });

  tearDownAll(() async {
    await waltClient.dispose();
    await xenaClient.dispose();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  /// Xena's screen, wired the way `main.dart` wires it: a real chat
  /// repository over [cache], a real presence repository. Only auth and the
  /// photo picker are fakes.
  ProviderContainer containerFor(AttachmentCache cache) => ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: xenaMember),
      ),
      chatRepositoryProvider.overrideWithValue(
        SupabaseChatRepository(xenaClient, cache: cache),
      ),
      attachmentCacheProvider.overrideWithValue(cache),
      presenceRepositoryProvider.overrideWithValue(
        SupabasePresenceRepository(xenaClient),
      ),
      sessionControllerProvider.overrideWith(() => _SignedIn(xenaMember)),
    ],
  );

  Future<void> mount(WidgetTester t, ProviderContainer container) async {
    await settled(container);
    container.read(openConversationProvider.notifier).open(conversationId);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: sisTheme(Brightness.light),
          home: const MessageScreen(title: 'Walt'),
        ),
      ),
    );
  }

  Future<void> until(WidgetTester t, bool Function() ok, String what) async {
    for (var i = 0; i < 100; i++) {
      if (ok()) return;
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
    fail('never happened: $what');
  }

  testWidgets('shows a photo sent by the other member: preview first, then the '
      'photo; opening it again does not download it again', (t) async {
    final pickedImage = PickedImage(
      bytes: _png,
      contentType: 'image/png',
      extension: 'png',
      preview: _png,
    );
    final caption = 'seam ${DateTime.now().microsecondsSinceEpoch}';
    final sent = await t.runAsync(
      () => walt.sendImage(
        conversationId: conversationId,
        image: pickedImage,
        body: caption,
      ),
    ) as Ok<Message>;
    final path = sent.value.attachmentPath!;
    // Scoped to this message's own bubble: the conversation can carry
    // other photo messages (from earlier test runs against the same
    // local stack), and every bubble's preview/image share the same key.
    final bubble = find.byKey(ValueKey('message-${sent.value.id}'));
    final preview = find.descendant(
      of: bubble,
      matching: find.byKey(const ValueKey('attachment-preview')),
    );
    final photo = find.descendant(
      of: bubble,
      matching: find.byKey(const ValueKey('attachment-image')),
    );

    final cacheDir = (await t.runAsync(() => tempRoot.createTemp('first-')))!;
    final realCache = FileAttachmentCache(root: () async => cacheDir);
    final cache = _HoldableCache(realCache);
    // Held before the screen even builds: the real download must not run
    // ahead of the assertion that the preview is what shows meanwhile.
    cache.holdRead();
    final container = containerFor(cache);
    addTearDown(container.dispose);

    await mount(t, container);
    await until(t, () => bubble.evaluate().isNotEmpty, 'the message to load');

    expect(
      preview,
      findsOneWidget,
      reason:
          'bytes cannot possibly be here yet -- the cache read is held '
          'open -- so the preview that travelled with the message is '
          'what must be on screen',
    );
    expect(photo, findsNothing);

    cache.releaseRead();
    await until(
      t,
      () => photo.evaluate().isNotEmpty,
      'the real photo replacing the preview',
    );
    expect(preview, findsNothing);

    // Really on disk, not only in the provider's own memory.
    expect(
      await t.runAsync(() => realCache.read(path)),
      _png,
      reason: 'the fetched bytes must be written to the real file cache',
    );

    await t.pumpWidget(const SizedBox());
    container.dispose();
    await t.runAsync(() => xenaClient.removeAllChannels());
    await t.runAsync(() => xenaClient.realtime.disconnect());
    await t.pump(const Duration(seconds: 61));

    // A second screen, over a brand-new cache instance pointed at the
    // SAME directory: nothing but the file on disk connects it to the
    // first one, exactly as a cold app start would find it.
    final spy = _SpyCache(FileAttachmentCache(root: () async => cacheDir));
    final second = containerFor(spy);
    addTearDown(second.dispose);
    await mount(t, second);
    await until(
      t,
      () => photo.evaluate().isNotEmpty,
      'the photo to show from the cache',
    );

    expect(
      spy.hits,
      contains(path),
      reason: 'the cache must be asked, and answer, before any download',
    );
    expect(
      spy.misses,
      isNot(contains(path)),
      reason:
          'a miss here would mean the second screen fell through to the '
          'network for a photo it already has on disk',
    );

    await t.pumpWidget(const SizedBox());
    second.dispose();
    await t.runAsync(() => xenaClient.removeAllChannels());
    await t.runAsync(() => xenaClient.realtime.disconnect());
    await t.pump(const Duration(seconds: 61));
  });
}
