import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart'
    show WebSocketChannelException;

import '../core/failure.dart';

/// No network or the server did not answer in time.
const offlineMessage = 'No connection. Check your internet and try again.';

/// The server answered with an error.
const serverMessage = 'The server could not do that. Try again.';

/// Anything else.
const genericMessage = 'Something went wrong. Try again.';

/// The one place an SDK error becomes words a member reads. The raw error goes to the device log, never to the screen.
Failure readableFailure(Object e) {
  log('$e', name: 'sis.data', error: e);

  final message = switch (e) {
    IOException() || TimeoutException() || ClientException() => offlineMessage,
    AuthRetryableFetchException() => offlineMessage,
    // A refused Realtime socket: the SocketException comes wrapped.
    WebSocketChannelException() => offlineMessage,
    PostgrestException() ||
    StorageException() ||
    AuthException() => serverMessage,
    RealtimeSubscribeStatus.timedOut => offlineMessage,
    _ => genericMessage,
  };

  return NetworkFailure(message);
}
