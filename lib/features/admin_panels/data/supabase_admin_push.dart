import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/realtime_channels.dart';
import '../domain/admin_push.dart';

/// [AdminPush] over the private Realtime topic 'admin_view' (sent by the database, owner only).
final class SupabaseAdminPush implements AdminPush {
  SupabaseAdminPush(this._client);
  final SupabaseClient _client;

  @override
  Future<Result<Stream<void>>> listen() async {
    final channel = _client.channel(
      'admin_view',
      opts: const RealtimeChannelConfig(private: true),
    );
    final c = StreamController<void>();
    channel.onBroadcast(
      event: 'down',
      callback: (_) {
        if (!c.isClosed) c.add(null);
      },
    );
    c.onCancel = () => leaveChannel(_client, channel);
    try {
      // A reconnect may have missed a push: nudge a refresh.
      await joinChannel(
        channel,
        onRejoin: () {
          if (!c.isClosed) c.add(null);
        },
      );
    } catch (e) {
      leaveChannel(_client, channel, c);
      return Err(readableFailure(e));
    }
    return Ok(c.stream);
  }
}
