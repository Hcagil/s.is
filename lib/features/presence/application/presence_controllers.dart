import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../chat/application/chat_controllers.dart';
import '../../profile/application/profile_controller.dart';
import '../domain/presence_repository.dart';

final presenceRepositoryProvider = Provider<PresenceRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// How long a typing signal counts as "typing" without a new one.
const typingLinger = Duration(seconds: 5);

/// How often the composer may re-announce typing while the member types.
const typingEvery = Duration(seconds: 2);

/// Members online now.
///
/// Rebuilds when the member flips "share my online status", which rejoins the
/// channel so the server re-evaluates the send policy. Presence is a nicety:
/// a channel that cannot be joined yields an empty set, never an error screen.
final onlineMembersProvider =
    NotifierProvider.autoDispose<OnlineMembers, Set<String>>(OnlineMembers.new);

class OnlineMembers extends Notifier<Set<String>> {
  /// Bumped on every build. A rebuild does not unmount the notifier, so
  /// `ref.mounted` cannot tell a join that landed after the setting flipped;
  /// the generation can.
  int _generation = 0;

  @override
  Set<String> build() {
    final generation = ++_generation;
    final share = ref.watch(
      ownProfileProvider.select((p) => p.value?.sharePresence),
    );
    if (share == null) return const {}; // profile not loaded yet
    unawaited(_connect(share, generation));
    return const {};
  }

  Future<void> _connect(bool share, int generation) async {
    final opened = await ref
        .read(presenceRepositoryProvider)
        .online(share: share);
    if (!ref.mounted || generation != _generation) {
      // Rebuilt while joining (the setting flipped): this channel is stale.
      // Listening and cancelling at once runs its teardown instead of
      // leaving it joined and announcing with the old setting.
      if (opened case Ok(:final value)) unawaited(value.listen(null).cancel());
      return;
    }
    if (opened case Ok(:final value)) {
      final sub = value.listen((online) {
        if (ref.mounted) state = online;
      }, onError: (Object _) {});
      ref.onDispose(sub.cancel);
    }
  }
}

/// Who is typing in the open conversation, as member ids.
final typingProvider = NotifierProvider.autoDispose<Typing, Set<String>>(
  Typing.new,
);

class Typing extends Notifier<Set<String>> {
  TypingChannel? _channel;
  int _generation = 0; // see OnlineMembers._generation
  final _expiry = <String, Timer>{};
  DateTime? _lastSignal;

  @override
  Set<String> build() {
    final conversationId = ref.watch(openConversationProvider);
    final generation = ++_generation;
    ref.onDispose(() {
      for (final t in _expiry.values) {
        t.cancel();
      }
      _expiry.clear();
      final channel = _channel;
      _channel = null;
      if (channel != null) unawaited(channel.close());
    });
    if (conversationId != null) {
      unawaited(_connect(conversationId, generation));
    }
    return const {};
  }

  Future<void> _connect(String conversationId, int generation) async {
    final opened = await ref
        .read(presenceRepositoryProvider)
        .typing(conversationId);
    // Landed after the conversation closed or changed: close it rather than
    // leave a private channel receiving for a screen that is gone.
    if (!ref.mounted || generation != _generation) {
      if (opened case Ok(:final value)) unawaited(value.close());
      return;
    }
    if (opened case Ok(:final value)) {
      _channel = value;
      final sub = value.typists.listen(_saw, onError: (Object _) {});
      ref.onDispose(sub.cancel);
    }
  }

  void _saw(String userId) {
    if (!ref.mounted) return;
    _expiry[userId]?.cancel();
    _expiry[userId] = Timer(typingLinger, () {
      _expiry.remove(userId);
      if (ref.mounted) state = {...state}..remove(userId);
    });
    if (!state.contains(userId)) state = {...state, userId};
  }

  /// A message from someone ends their "typing…" at once instead of letting
  /// it linger over the message they just sent.
  void messageFrom(String userId) {
    _expiry.remove(userId)?.cancel();
    if (state.contains(userId)) state = {...state}..remove(userId);
  }

  /// Called as the member types. Throttled, and silent when they chose not to
  /// share typing -- the server would refuse it anyway.
  void signalTyping() {
    final shares = ref.read(ownProfileProvider).value?.shareTyping ?? false;
    final channel = _channel;
    if (!shares || channel == null) return;
    final now = DateTime.now();
    final last = _lastSignal;
    if (last != null && now.difference(last) < typingEvery) return;
    _lastSignal = now;
    unawaited(channel.signal());
  }
}

/// When [userId] was last online, as far as the server will say (null when
/// hidden by either side). Re-asked when they go offline and when the
/// member's own last-seen switch flips, since both change the answer.
final lastSeenProvider = FutureProvider.autoDispose.family<DateTime?, String>((
  ref,
  userId,
) async {
  ref.watch(onlineMembersProvider.select((online) => online.contains(userId)));
  ref.watch(ownProfileProvider.select((p) => p.value?.shareLastSeen));
  return switch (await ref
      .read(presenceRepositoryProvider)
      .lastSeenOf(userId)) {
    Ok(:final value) => value,
    // A missing "last seen" is not worth an error on screen.
    Err() => null,
  };
});

/// Tells the server "seen now". Called when the app opens and when it goes
/// to the background; best effort, since a missed update only makes the
/// shown time a little older.
final lastSeenReporterProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => ref.read(presenceRepositoryProvider).touchLastSeen(),
);
