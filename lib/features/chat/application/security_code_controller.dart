import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../crypto/application/key_directory_controller.dart';
import '../../crypto/domain/security_code.dart';
import '../../crypto/domain/security_code_store.dart';
import 'chat_controllers.dart';

/// The on-phone security code memory; null until main wires it.
final securityCodeStoreProvider = Provider<SecurityCodeStore?>((_) => null);

/// Which chats have held a locked text; null until main wires it.
final cipherChatMemoryProvider = Provider<CipherChatMemory?>((_) => null);

/// Why no code can be shown.
enum SecurityCodeGap { noSecureChat, keyMismatch }

/// What the security code page can show for one contact.
sealed class SecurityCodeState {
  const SecurityCodeState();
}

/// No code: no secure chat yet, or the server key is not the one in use.
final class SecurityCodeUnavailable extends SecurityCodeState {
  const SecurityCodeUnavailable(this.gap);
  final SecurityCodeGap gap;
}

/// A code is ready.
final class SecurityCodeReady extends SecurityCodeState {
  const SecurityCodeReady({
    required this.digits,
    required this.verified,
    required this.peerKeys,
  });

  /// The 60 digits.
  final String digits;

  /// The peer's keys equal the keys marked verified on this phone.
  final bool verified;

  /// The peer's current keys behind the code.
  final VerifiedKeys peerKeys;
}

Future<SecurityCodeState> _load(Ref ref, String peerUserId) async {
  final store = ref.read(securityCodeStoreProvider);
  final me = ref.read(currentUserIdProvider);
  if (store == null || me == null) {
    return const SecurityCodeUnavailable(SecurityCodeGap.noSecureChat);
  }
  final own = await store.ownKeys();
  // The peer's Curve25519 key comes from the stored session, never from the server.
  final peerCurve = await store.sessionPeerKey(peerUserId);
  if (own == null || peerCurve == null) {
    return const SecurityCodeUnavailable(SecurityCodeGap.noSecureChat);
  }
  final looked = await ref
      .read(keyDirectoryControllerProvider.notifier)
      .identityVerified(peerUserId);
  final keys = switch (looked) {
    Ok(:final value) => value,
    _ => null,
  };
  if (keys == null) {
    return const SecurityCodeUnavailable(SecurityCodeGap.noSecureChat);
  }
  if (keys.identityKey != peerCurve) {
    return const SecurityCodeUnavailable(SecurityCodeGap.keyMismatch);
  }
  final digits = securityCode(
    CodeParty(userId: me, curve25519: own.curve25519, ed25519: own.ed25519),
    CodeParty(
      userId: peerUserId,
      curve25519: peerCurve,
      ed25519: keys.signingKey,
    ),
  );
  if (digits == null) {
    return const SecurityCodeUnavailable(SecurityCodeGap.noSecureChat);
  }
  final peerKeys = VerifiedKeys(
    curve25519: peerCurve,
    ed25519: keys.signingKey,
  );
  final marked = await store.verified(peerUserId);
  return SecurityCodeReady(
    digits: digits,
    verified: marked == peerKeys,
    peerKeys: peerKeys,
  );
}

/// The security code state of one contact (by user id).
final securityCodeProvider = FutureProvider.autoDispose
    .family<SecurityCodeState, String>(
      (ref, peerUserId) => _load(ref, peerUserId),
    );

/// Marking and unmarking a contact as verified on this phone.
final securityCodeActionsProvider = Provider<SecurityCodeActions>(
  SecurityCodeActions.new,
);

class SecurityCodeActions {
  SecurityCodeActions(this._ref);
  final Ref _ref;

  /// Marks the peer's CURRENT keys as verified on this phone only. [shownDigits] is the code the person compared; nothing is marked unless the code read again now is the same (the keys may have changed meanwhile).
  Future<void> markVerified(String peerUserId, String shownDigits) async {
    final s = await _load(_ref, peerUserId);
    if (s is SecurityCodeReady && s.digits == shownDigits) {
      await _ref
          .read(securityCodeStoreProvider)
          ?.markVerified(peerUserId, s.peerKeys);
    }
    _ref.invalidate(securityCodeProvider(peerUserId));
  }

  /// Removes the mark.
  Future<void> unmarkVerified(String peerUserId) async {
    await _ref.read(securityCodeStoreProvider)?.clearVerified(peerUserId);
    _ref.invalidate(securityCodeProvider(peerUserId));
  }
}

/// The last key change seen for a contact; reread when the open chat's messages change (a new session appears while messages open).
final keyChangeProvider = FutureProvider.autoDispose.family<KeyChange?, String>(
  (ref, peerUserId) async {
    ref.watch(messagesProvider);
    return ref.read(securityCodeStoreProvider)?.keyChange(peerUserId);
  },
);
