import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../domain/presence_repository.dart';

/// [PresenceRepository] over private Realtime channels.
///
/// Topic names must match the realtime.messages policies exactly:
/// `presence:members` and `typing:<conversation id>`.
final class SupabasePresenceRepository implements PresenceRepository {
  SupabasePresenceRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => NetworkFailure('$e');

  /// Joins [channel] and resolves when the server confirms it -- or refuses
  /// it, which for a private channel is how an unauthorised join ends.
  Future<void> _join(RealtimeChannel channel) {
    final joined = Completer<void>();
    channel.subscribe((status, error) {
      if (joined.isCompleted) return;
      if (status == RealtimeSubscribeStatus.subscribed) {
        joined.complete();
      } else if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut ||
          error != null) {
        joined.completeError(error ?? status);
      }
    });
    return joined.future.timeout(const Duration(seconds: 15));
  }

  /// Leaves [channel] without waiting: on a dead socket the unsubscribe
  /// handshake never completes (see SupabaseChatRepository.incoming).
  void _leave(RealtimeChannel channel) {
    unawaited(() async {
      try {
        await _client.removeChannel(channel);
      } catch (_) {}
    }());
  }

  @override
  Future<Result<Stream<Set<String>>>> online({required bool share}) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    // The presence key is the user id, so the set of keys IS the set of
    // members online, however many devices or reconnects each has.
    final channel = _client.channel(
      'presence:members',
      opts: RealtimeChannelConfig(private: true, key: me),
    );
    final controller = StreamController<Set<String>>();
    channel.onPresenceSync((_) {
      if (controller.isClosed) return;
      controller.add({for (final s in channel.presenceState()) s.key});
    });
    controller.onCancel = () => _leave(channel);
    try {
      await _join(channel);
      if (share) {
        await channel.track({
          'online_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } catch (e) {
      _leave(channel);
      // Not awaited: close() on a stream nobody ever listened to completes
      // only once someone does, so awaiting it hung this failure path forever.
      unawaited(controller.close());
      return Err(_asFailure(e));
    }
    return Ok(controller.stream);
  }

  @override
  Future<Result<TypingChannel>> typing(String conversationId) async {
    final me = _uid;
    if (me == null) return const Err(DeniedFailure());
    final channel = _client.channel(
      'typing:$conversationId',
      opts: const RealtimeChannelConfig(private: true),
    );
    final typists = StreamController<String>.broadcast();
    channel.onBroadcast(
      event: 'typing',
      callback: (payload) {
        final who = payload['user_id'];
        // Echo is off by default; the check also ignores a spoofed "me".
        if (who is String && who != me && !typists.isClosed) typists.add(who);
      },
    );
    try {
      await _join(channel);
    } catch (e) {
      _leave(channel);
      await typists.close();
      return Err(_asFailure(e));
    }
    return Ok(_SupabaseTypingChannel(channel, typists, me, _leave));
  }
}

final class _SupabaseTypingChannel implements TypingChannel {
  _SupabaseTypingChannel(this._channel, this._typists, this._me, this._leave);

  final RealtimeChannel _channel;
  final StreamController<String> _typists;
  final String _me;
  final void Function(RealtimeChannel) _leave;

  @override
  Stream<String> get typists => _typists.stream;

  @override
  Future<void> signal() async {
    try {
      await _channel.sendBroadcastMessage(
        event: 'typing',
        payload: {'user_id': _me},
      );
    } catch (_) {
      // Best effort by contract.
    }
  }

  @override
  Future<void> close() async {
    _leave(_channel);
    await _typists.close();
  }
}
