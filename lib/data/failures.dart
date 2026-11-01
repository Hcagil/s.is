import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart'
    show WebSocketChannelException;

import '../core/failure.dart';

/// No network or the server did not answer in time.
String get offlineMessage => failureText(
  'No connection. Check your internet and try again.',
  'Bağlantı yok. İnternetini kontrol edip tekrar dene.',
);

/// The server answered with an error.
String get serverMessage => failureText(
  'Something went wrong on our side. Try again.',
  'Bizden kaynaklı bir sorun oluştu. Tekrar dene.',
);

/// Anything else.
String get genericMessage => failureText(
  'Something went wrong. Try again.',
  'Bir şeyler ters gitti. Tekrar dene.',
);

/// The one place an SDK error becomes words a member reads. The raw error goes to the device log, never to the screen.
Failure readableFailure(Object e) {
  // A ClientException carries the request URL, which can hold the Maps key (the Geocoding and Static Maps APIs only take it as ?key=). Mask it before it reaches the log.
  log(
    '$e'.replaceAll(RegExp(r'key=[^&\s,)]+'), 'key=<hidden>'),
    name: 'sis.data',
  );

  final retryable = switch (e) {
    IOException() || TimeoutException() || ClientException() => true,
    AuthRetryableFetchException() => true,
    // A refused Realtime socket: the SocketException comes wrapped.
    WebSocketChannelException() => true,
    PostgrestException() || StorageException() || AuthException() => false,
    RealtimeSubscribeStatus.timedOut => true,
    _ => false,
  };
  final message = retryable
      ? offlineMessage
      : switch (e) {
          PostgrestException() ||
          StorageException() ||
          AuthException() => serverMessage,
          _ => genericMessage,
        };

  return NetworkFailure(message, retryable: retryable);
}
