@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/data/supabase_presence_repository.dart';
import 'package:sis/features/presence/domain/presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/data/supabase_profile_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Online status and typing against the real stack: the REAL controllers on
/// the REAL [SupabasePresenceRepository], over real private Realtime channels
/// that the server authorises with the policies on realtime.messages.
///
/// The unit tests prove the controllers react correctly to what a fake hands
/// them. Only this suite can show that the server really announces, refuses,
/// and withholds — including against a client that ignores the app's own
/// settings, which is what "enforced by the server" has to mean.
///
/// Where a raw client imitates the app, it uses the wire shape the real
/// repository was observed to produce (presence key = user id; broadcast
/// event `typing` with `user_id`), and every such imitation has a positive
/// control showing the same message IS delivered when the sender is allowed.
/// Without that, a refusal could just be a malformed message.
///
/// Requires a running local Supabase and the warmup probe. Accounts
/// yara/zane/abby are this suite's own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

SupabaseClient _client() => SupabaseClient(
  _url,
  _key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signIn(String email) async {
  final client = _client();
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  return client;
}

Future<SupabaseClient> _signedIn(String email) async {
  final client = await _signIn(email);
  expect(
    await client.rpc('activate_session'),
    isTrue,
    reason: 'activate_session refused an allowlisted user',
  );
  return client;
}

/// Polls [read] until [matches] holds; Realtime has no callback here.
Future<T> eventually<T>(
  T Function() read,
  bool Function(T) matches, {
  Duration timeout = const Duration(seconds: 25),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (matches(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('timed out after $timeout: $reason');
}

/// Holds for the whole window: the thing never happens.
Future<void> never<T>(
  T Function() read,
  bool Function(T) happened, {
  Duration window = const Duration(seconds: 5),
  required String reason,
}) async {
  final deadline = DateTime.now().add(window);
  while (DateTime.now().isBefore(deadline)) {
    if (happened(read())) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Joins [topic] the way any client could, and reports what the server said.
Future<(RealtimeChannel, RealtimeSubscribeStatus)> _join(
  SupabaseClient client,
  String topic, {
  bool private = true,
  String presenceKey = '',
  void Function(RealtimeChannel)? bind,
}) async {
  final channel = client.channel(
    topic,
    opts: RealtimeChannelConfig(private: private, key: presenceKey),
  );
  bind?.call(channel);
  final first = Completer<RealtimeSubscribeStatus>();
  channel.subscribe((status, _) {
    if (!first.isCompleted) first.complete(status);
  });
  final status = await first.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => RealtimeSubscribeStatus.timedOut,
  );
  return (channel, status);
}

/// The presence keys a raw channel currently sees.
Set<String> _keys(RealtimeChannel c) => {
  for (final s in c.presenceState()) s.key,
};

/// Confirms `online()` only after [gate] opens — AFTER the real channel is
/// joined and tracked. That is a join the controller is still waiting for,
/// widened from milliseconds to as long as the test needs.
class _LateConfirm implements PresenceRepository {
  _LateConfirm(this.real);
  final PresenceRepository real;
  final gate = Completer<void>();
  int joined = 0;

  @override
  Future<Result<Stream<Set<String>>>> online({required bool share}) async {
    final result = await real.online(share: share);
    joined++;
    await gate.future;
    return result;
  }

  @override
  Future<Result<TypingChannel>> typing(String conversationId) =>
      real.typing(conversationId);
}

class Account {
  Account(this.client);
  final SupabaseClient client;
  String get id => client.auth.currentUser!.id;
  final _containers = <ProviderContainer>[];

  /// The overrides `main.dart` installs, over this account's client.
  ProviderContainer container({PresenceRepository? presence}) {
    final c = ProviderContainer.test(
      overrides: [
        presenceRepositoryProvider.overrideWithValue(
          presence ?? SupabasePresenceRepository(client),
        ),
        profileRepositoryProvider.overrideWithValue(
          SupabaseProfileRepository(client),
        ),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
      ],
    );
    c.listen(ownProfileProvider, (_, _) {});
    _containers.add(c);
    return c;
  }

  /// Sets both choices straight through the real repository.
  Future<void> share({required bool presence, required bool typing}) async {
    final r = await SupabaseProfileRepository(client)
        .save(sharePresence: presence, shareTyping: typing);
    expect(r, isA<Ok<OwnProfile>>(), reason: 'could not set sharing');
  }

  Future<void> reset() async {
    for (final c in _containers) {
      c.dispose();
    }
    _containers.clear();
    await client.removeAllChannels();
    await share(presence: true, typing: true);
  }
}

void main() {
  // Integration tests reach the network: flutter_test answers every HTTP
  // request with 400 unless this is lifted.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Account yara;
  late Account zane;
  late Account abby;
  late String cid;
  final extra = <SupabaseClient>[];

  setUpAll(() async {
    yara = Account(await _signedIn('yara@integration.test'));
    zane = Account(await _signedIn('zane@integration.test'));
    abby = Account(await _signedIn('abby@integration.test'));
    final started = await SupabaseChatRepository(yara.client)
        .startDirectConversation(zane.id);
    cid = (started as Ok<String>).value;
  });

  setUp(() async {
    await yara.share(presence: true, typing: true);
    await zane.share(presence: true, typing: true);
    await abby.share(presence: true, typing: true);
  });

  tearDown(() async {
    await yara.reset();
    await zane.reset();
    await abby.reset();
    for (final c in extra) {
      await c.removeAllChannels();
      await c.dispose();
    }
    extra.clear();
  });

  tearDownAll(() async {
    await yara.client.dispose();
    await zane.client.dispose();
    await abby.client.dispose();
  });

  test(
    'the sharing choices persist through the real profile repository',
    () async {
      final c = zane.container();
      await c.read(ownProfileProvider.future);

      final r = await c
          .read(ownProfileProvider.notifier)
          .setSharing(presence: false);
      expect(r, isA<Ok<OwnProfile>>());

      final fresh = zane.container();
      final p = await fresh.read(ownProfileProvider.future);
      expect(p.sharePresence, isFalse);
      expect(p.shareTyping, isTrue, reason: 'one switch changed the other');

      await c.read(ownProfileProvider.notifier).setSharing(typing: false);
      final again = await zane.container().read(ownProfileProvider.future);
      expect((again.sharePresence, again.shareTyping), (false, false));
    },
  );

  test('yara sees zane online; when he turns sharing off she stops seeing '
      'him, and he still sees her', () async {
    final y = yara.container();
    y.listen(onlineMembersProvider, (_, _) {});
    final z = zane.container();
    z.listen(onlineMembersProvider, (_, _) {});

    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => s.contains(zane.id),
      reason: 'yara never saw zane online',
    );
    await eventually(
      () => z.read(onlineMembersProvider),
      (s) => s.contains(yara.id),
      reason: 'zane never saw yara online',
    );

    final r = await z
        .read(ownProfileProvider.notifier)
        .setSharing(presence: false);
    expect(r, isA<Ok<OwnProfile>>());

    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => !s.contains(zane.id),
      reason: 'zane opted out and yara still sees him online',
    );
    await eventually(
      () => z.read(onlineMembersProvider),
      (s) => s.contains(yara.id),
      reason: 'a hidden member must still see others',
    );

    await z.read(ownProfileProvider.notifier).setSharing(presence: true);
    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => s.contains(zane.id),
      reason: 'zane opted back in and never reappeared',
    );
  });

  test('the server refuses to announce a member who opted out, whatever his '
      'client does', () async {
    final y = yara.container();
    y.listen(onlineMembersProvider, (_, _) {});

    // Control: abby, sharing, announces herself with a raw client in the
    // app's own wire shape — and yara's real controller sees her.
    final (abbyRaw, abbyStatus) = await _join(
      abby.client,
      'presence:members',
      presenceKey: abby.id,
      bind: (c) => c.onPresenceSync((_) {}),
    );
    expect(abbyStatus, RealtimeSubscribeStatus.subscribed);
    await abbyRaw.track({'online_at': DateTime.now().toIso8601String()});
    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => s.contains(abby.id),
      reason: 'the control failed: a raw track in this shape is not seen',
    );

    // Zane opted out; his client ignores that and tracks anyway.
    await zane.share(presence: false, typing: true);
    final (zaneRaw, zaneStatus) = await _join(
      zane.client,
      'presence:members',
      presenceKey: zane.id,
      bind: (c) => c.onPresenceSync((_) {}),
    );
    final tracked = await zaneRaw.track({
      'online_at': DateTime.now().toIso8601String(),
    });
    // ignore: avoid_print
    print('opted-out raw client: join=$zaneStatus track=$tracked');

    await never(
      () => y.read(onlineMembersProvider),
      (s) => s.contains(zane.id),
      reason: 'the server announced a member who turned sharing off',
    );
  });

  test('a sharing join the controller is still waiting for when sharing is '
      'turned off does not keep the member online', () async {
    final y = yara.container();
    y.listen(onlineMembersProvider, (_, _) {});

    final slow = _LateConfirm(SupabasePresenceRepository(zane.client));
    final z = zane.container(presence: slow);
    z.listen(onlineMembersProvider, (_, _) {});
    await z.read(ownProfileProvider.future);
    await eventually(() => slow.joined, (n) => n >= 1, reason: 'no join');
    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => s.contains(zane.id),
      reason: 'the real channel never announced zane',
    );

    // Zane turns sharing off while the controller still awaits that join.
    await z.read(ownProfileProvider.notifier).setSharing(presence: false);
    await eventually(() => slow.joined, (n) => n >= 2, reason: 'no rejoin');
    slow.gate.complete();

    await eventually(
      () => y.read(onlineMembersProvider),
      (s) => !s.contains(zane.id),
      reason:
          'the join that landed after the rebuild was never left: zane '
          'turned sharing off and stays online',
    );
  });

  test('yara sees zane typing in their conversation, and it lapses', () async {
    final y = yara.container();
    y.listen(typingProvider, (_, _) {});
    y.read(openConversationProvider.notifier).open(cid);
    final z = zane.container();
    z.listen(typingProvider, (_, _) {});
    z.read(openConversationProvider.notifier).open(cid);
    await z.read(ownProfileProvider.future);

    // Keep typing until the channels are up; the throttle paces it.
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!y.read(typingProvider).contains(zane.id) &&
        DateTime.now().isBefore(deadline)) {
      z.read(typingProvider.notifier).signalTyping();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    expect(
      y.read(typingProvider),
      contains(zane.id),
      reason: 'yara never saw zane typing',
    );
    expect(
      z.read(typingProvider),
      isNot(contains(zane.id)),
      reason: 'a member\'s own typing was echoed back',
    );

    await eventually(
      () => y.read(typingProvider),
      (s) => !s.contains(zane.id),
      timeout: typingLinger + const Duration(seconds: 5),
      reason: 'typing never lapsed',
    );
  });

  test('the server drops typing from a member who opted out, whatever his '
      'client does', () async {
    final y = yara.container();
    y.listen(typingProvider, (_, _) {});
    y.read(openConversationProvider.notifier).open(cid);

    Future<void> rawTyping() async {
      final (ch, status) = await _join(zane.client, 'typing:$cid');
      expect(status, RealtimeSubscribeStatus.subscribed);
      for (var i = 0; i < 8; i++) {
        await ch.sendBroadcastMessage(
          event: 'typing',
          payload: {'user_id': zane.id},
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await zane.client.removeChannel(ch);
    }

    // Control: the same raw broadcast from zane while he shares is seen.
    await Future.wait([
      rawTyping(),
      eventually(
        () => y.read(typingProvider),
        (s) => s.contains(zane.id),
        reason: 'the control failed: a raw typing broadcast is not seen',
      ),
    ]);
    await eventually(
      () => y.read(typingProvider),
      (s) => s.isEmpty,
      timeout: typingLinger + const Duration(seconds: 5),
    );

    // Zane opts out; his client ignores it, rejoins and keeps signalling.
    await zane.share(presence: true, typing: false);
    await Future.wait([
      rawTyping(),
      never(
        () => y.read(typingProvider),
        (s) => s.contains(zane.id),
        reason: 'the server relayed typing from a member who opted out',
      ),
    ]);
  });

  test('a non-member cannot join the typing channel', () async {
    final r = await SupabasePresenceRepository(abby.client).typing(cid);
    expect(r, isA<Err<TypingChannel>>(), reason: 'abby joined typing:$cid');

    final (_, status) = await _join(abby.client, 'typing:$cid');
    expect(status, isNot(RealtimeSubscribeStatus.subscribed));

    // Control: a member's join of the very same topic succeeds.
    final ok = await SupabasePresenceRepository(zane.client).typing(cid);
    expect(ok, isA<Ok<TypingChannel>>());
  });

  group('clients without app access', () {
    // anon: the publishable key alone. stranger: signed in, confirmed, not
    // allowlisted -- authenticated, so only has_app_access() refuses him.
    final who = <String, Future<SupabaseClient> Function()>{
      'anon': () async => _client(),
      'stranger': () async {
        final c = await _signIn('stranger-presence@integration.test');
        expect(
          await c.rpc('activate_session'),
          isFalse,
          reason: 'the stranger fixture must not be allowlisted',
        );
        return c;
      },
    };

    for (final MapEntry(key: name, value: make) in who.entries) {
      test('$name: the server refuses both private channels', () async {
        final c = await make();
        extra.add(c);
        // Bound to presence, as the app's channel is: without a presence
        // binding Realtime authorises the join as broadcast only, and the
        // presence branch of the policy would never be asked.
        final (_, p) = await _join(
          c,
          'presence:members',
          bind: (ch) => ch.onPresenceSync((_) {}),
        );
        expect(p, RealtimeSubscribeStatus.channelError);
        // A second socket: a refused join can hold up the next one on the
        // same connection, which would turn a refusal into a timeout.
        final c2 = await make();
        extra.add(c2);
        final (_, t) = await _join(c2, 'typing:$cid');
        expect(t, isNot(RealtimeSubscribeStatus.subscribed));
        final typing = await SupabasePresenceRepository(c).typing(cid);
        expect(typing, isA<Err<TypingChannel>>());
      }, timeout: const Timeout(Duration(minutes: 1)));

      test(
        '$name: online() reports the refusal instead of waiting forever',
        () async {
          final c = await make();
          extra.add(c);
          final online = await SupabasePresenceRepository(c)
              .online(share: true)
              .timeout(
                const Duration(seconds: 20),
                onTimeout: () => fail(
                  'online() never resolved, though the server refused the '
                  'join (a raw join of the same topic reports channelError '
                  'within seconds)',
                ),
              );
          expect(online, isA<Err<Stream<Set<String>>>>());
        },
        timeout: const Timeout(Duration(minutes: 1)),
      );
    }
  });

  // What an outsider can do with a PUBLIC channel of the same name. The
  // answer decides whether public Realtime access must be turned off.
  group('public channels of the same name', () {
    late SupabaseClient anon;

    setUp(() {
      anon = _client();
      extra.add(anon);
    });

    for (final outsider in ['anon', 'abby (member of the app, not the chat)']) {
      SupabaseClient who() => outsider == 'anon' ? anon : abby.client;

      test('$outsider: hears no typing and cannot inject any', () async {
        final heard = <Map<String, dynamic>>[];
        final (pub, status) = await _join(
          who(),
          'typing:$cid',
          private: false,
          bind: (c) => c.onBroadcast(event: '*', callback: heard.add),
        );
        // ignore: avoid_print
        print('$outsider public typing:<cid> join: $status');

        final y = yara.container();
        y.listen(typingProvider, (_, _) {});
        y.read(openConversationProvider.notifier).open(cid);
        final z = zane.container();
        z.listen(typingProvider, (_, _) {});
        z.read(openConversationProvider.notifier).open(cid);
        await z.read(ownProfileProvider.future);

        // Real typing flows between the members (control) ...
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!y.read(typingProvider).contains(zane.id) &&
            DateTime.now().isBefore(deadline)) {
          z.read(typingProvider.notifier).signalTyping();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        expect(y.read(typingProvider), contains(zane.id));
        // ... and none of it reached the public channel.
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(heard, isEmpty, reason: '$outsider overheard private typing');

        await eventually(
          () => y.read(typingProvider),
          (s) => s.isEmpty,
          timeout: typingLinger + const Duration(seconds: 5),
        );
        if (status != RealtimeSubscribeStatus.subscribed) return;

        // A second public listener: proof the spoof below is really on the
        // wire, so yara not seeing it is isolation, not a dead channel.
        final witnessed = <Map<String, dynamic>>[];
        final witness = _client();
        extra.add(witness);
        final (_, ws) = await _join(
          witness,
          'typing:$cid',
          private: false,
          bind: (c) => c.onBroadcast(event: '*', callback: witnessed.add),
        );
        expect(ws, RealtimeSubscribeStatus.subscribed);

        // Spoof zane typing, in the app's own shape.
        await Future.wait([
          () async {
            for (var i = 0; i < 8; i++) {
              await pub.sendBroadcastMessage(
                event: 'typing',
                payload: {'user_id': zane.id},
              );
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
          }(),
          never(
            () => y.read(typingProvider),
            (s) => s.contains(zane.id),
            reason: '$outsider injected typing into the private channel',
          ),
        ]);
        expect(
          witnessed,
          isNotEmpty,
          reason: 'control: the public spoof never went out at all',
        );
      });

      test('$outsider: sees nobody online and cannot appear online', () async {
        final y = yara.container();
        y.listen(onlineMembersProvider, (_, _) {});
        final z = zane.container();
        z.listen(onlineMembersProvider, (_, _) {});
        await eventually(
          () => y.read(onlineMembersProvider),
          (s) => s.contains(zane.id),
          reason: 'control: members never saw each other',
        );

        // A public listener that should see the pose below: proof the track
        // really happened, so yara not seeing it is isolation.
        final witness = _client();
        extra.add(witness);
        final (wch, _) = await _join(
          witness,
          'presence:members',
          private: false,
          bind: (c) => c.onPresenceSync((_) {}),
        );

        // Pose as someone who is not online: abby has no channel open when
        // she is the outsider, and anon poses as her too.
        final (pub, status) = await _join(
          who(),
          'presence:members',
          private: false,
          presenceKey: abby.id,
          bind: (c) => c.onPresenceSync((_) {}),
        );
        // ignore: avoid_print
        print('$outsider public presence:members join: $status');
        if (status == RealtimeSubscribeStatus.subscribed) {
          await pub.track({'online_at': DateTime.now().toIso8601String()});
        }

        await never(
          () => y.read(onlineMembersProvider),
          (s) => s.contains(abby.id),
          reason: '$outsider appeared online through a public channel',
        );
        expect(
          _keys(pub).intersection({yara.id, zane.id}),
          isEmpty,
          reason: '$outsider saw who is online',
        );
        if (status == RealtimeSubscribeStatus.subscribed) {
          expect(
            _keys(wch),
            contains(abby.id),
            reason: 'control: the public pose never went out at all',
          );
        }
      });
    }
  });
}
