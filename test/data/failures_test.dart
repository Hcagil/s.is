import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' show ClientException;
import 'package:sis/core/failure.dart';
import 'package:sis/data/failures.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart'
    show WebSocketChannelException;

/// `readableFailure()` is the one place an SDK error becomes words a member
/// reads. Every case below must return exactly one of the three public
/// sentences, in a [NetworkFailure], and never the raw error text.
void main() {
  void expectOffline(Object e) {
    final f = readableFailure(e);
    expect(f, isA<NetworkFailure>());
    expect(f.message, offlineMessage);
  }

  void expectServer(Object e) {
    final f = readableFailure(e);
    expect(f, isA<NetworkFailure>());
    expect(f.message, serverMessage);
  }

  void expectGeneric(Object e) {
    final f = readableFailure(e);
    expect(f, isA<NetworkFailure>());
    expect(f.message, genericMessage);
  }

  group('offline', () {
    test('a dart:io IOException (SocketException)', () {
      expectOffline(const SocketException('Failed host lookup: nope'));
    });

    test('a dart:io IOException (HandshakeException)', () {
      expectOffline(const HandshakeException('bad certificate'));
    });

    test('a dart:async TimeoutException', () {
      expectOffline(TimeoutException('took too long'));
    });

    test('a package:http ClientException', () {
      expectOffline(ClientException('Connection closed'));
    });

    test('AuthRetryableFetchException, even though it is an AuthException', () {
      expectOffline(AuthRetryableFetchException(message: 'network error'));
    });

    test('RealtimeSubscribeStatus.timedOut', () {
      expectOffline(RealtimeSubscribeStatus.timedOut);
    });

    test('WebSocketChannelException, wrapping a refused Realtime socket', () {
      expectOffline(
        WebSocketChannelException.from(
          const SocketException('Connection refused'),
        ),
      );
    });
  });

  group('server', () {
    test('PostgrestException', () {
      expectServer(
        const PostgrestException(message: 'permission denied', code: '42501'),
      );
    });

    test('StorageException', () {
      expectServer(const StorageException('object not found'));
    });

    test('a plain AuthException (not retryable)', () {
      expectServer(const AuthException('invalid grant'));
    });
  });

  group('generic', () {
    test('a StateError', () {
      expectGeneric(StateError('bad state'));
    });

    test('a bare String', () {
      expectGeneric('just a string');
    });

    test('RealtimeSubscribeStatus.channelError', () {
      expectGeneric(RealtimeSubscribeStatus.channelError);
    });
  });

  test('the raw error text never reaches the message', () {
    const needle =
        'ClientException with SocketException: '
        'Failed host lookup: example.invalid';
    final f = readableFailure(const SocketException(needle));
    expect(f.message, isNot(contains('Failed host lookup')));
    expect(f.message, isNot(contains('SocketException')));
    expect(f.message, offlineMessage);
  });

  test(
    'always returns a NetworkFailure, whatever the message ends up being',
    () {
      for (final e in [
        const SocketException('x'),
        const PostgrestException(message: 'x'),
        StateError('x'),
      ]) {
        expect(readableFailure(e), isA<NetworkFailure>());
      }
    },
  );
}
