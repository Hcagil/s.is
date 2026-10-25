import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../crypto/application/key_directory_controller.dart';
import '../../crypto/domain/key_directory.dart';

class PeerKeyCache {
  PeerKeyCache(
    this._fetch, {
    this.ttl = const Duration(minutes: 5),
    this.timeout = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final Future<Result<ClaimedKeys?>> Function(String userId) _fetch;
  final Duration ttl;
  final Duration timeout;
  final DateTime Function() _now;
  final Map<String, ({ClaimedKeys keys, DateTime until})> _hits = {};

  /// A peer's already verified keys for a few minutes, so a long list of locked rows asks the server once. Only an Ok with keys is kept (never an Err, never Ok(null)). [fresh] skips the kept copy and asks the server again (always used for a pre-key message, which can create a session). A fetch that does not answer within [timeout] gives Err(NetworkFailure('timeout', retryable: true)); the caller keeps the row locked.
  Future<Result<ClaimedKeys?>> get(String userId, {bool fresh = false}) async {
    if (!fresh) {
      final hit = _hits[userId];
      if (hit != null && _now().isBefore(hit.until)) return Ok(hit.keys);
    }
    final Result<ClaimedKeys?> r;
    try {
      r = await _fetch(userId).timeout(timeout);
    } on TimeoutException {
      return const Err(NetworkFailure('timeout', retryable: true));
    }
    if (r case Ok(:final value?)) {
      _hits[userId] = (keys: value, until: _now().add(ttl));
    } else {
      _hits.remove(userId);
    }
    return r;
  }

  /// Forgets the kept keys of [userId] (a row failed to open, so the key may have changed).
  void drop(String userId) => _hits.remove(userId);

  /// Forgets every kept key (the signed-in member changed).
  void clear() => _hits.clear();
}

/// The one cache shared by the message and reaction openers.
final peerKeyCacheProvider = Provider<PeerKeyCache>(
  (ref) => PeerKeyCache(
    (id) =>
        ref.read(keyDirectoryControllerProvider.notifier).identityVerified(id),
  ),
);
