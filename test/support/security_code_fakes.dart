// qa-lead fakes for the on-phone security code memory, derived from the
// SecurityCodeStore / CipherChatMemory interfaces (never from an
// implementation). Every call takes a real async hop, as the encrypted store
// file does. [newSession] does what the contract says a new session with a
// different key does on the phone (_retireOthers): the verified mark goes and
// a key change is recorded.
import 'package:sis/features/crypto/domain/security_code_store.dart';

class FakeSecurityCodeStore implements SecurityCodeStore, CipherChatMemory {
  FakeSecurityCodeStore({this.own});

  OwnKeys? own;

  /// Peer id -> identity key of the session in use.
  final sessions = <String, String>{};
  final marks = <String, VerifiedKeys>{};
  final changes = <String, KeyChange>{};
  final held = <String, DateTime>{};
  final calls = <String>[];

  Future<void> _hop(String call) async {
    calls.add(call);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  /// A new session with [peer] on [curve25519]: like the engine, a different
  /// key than the stored one clears the mark and records a change.
  void newSession(String peer, String curve25519, DateTime at) {
    final old = sessions[peer];
    sessions[peer] = curve25519;
    if (old != null && old != curve25519) {
      changes[peer] = KeyChange(at: at, wasVerified: marks.containsKey(peer));
      marks.remove(peer);
    }
  }

  @override
  Future<OwnKeys?> ownKeys() async {
    await _hop('ownKeys');
    return own;
  }

  @override
  Future<String?> sessionPeerKey(String peerUserId) async {
    await _hop('sessionPeerKey:$peerUserId');
    return sessions[peerUserId];
  }

  @override
  Future<VerifiedKeys?> verified(String peerUserId) async {
    await _hop('verified:$peerUserId');
    return marks[peerUserId];
  }

  @override
  Future<void> markVerified(String peerUserId, VerifiedKeys keys) async {
    await _hop('markVerified:$peerUserId');
    marks[peerUserId] = keys;
  }

  @override
  Future<void> clearVerified(String peerUserId) async {
    await _hop('clearVerified:$peerUserId');
    marks.remove(peerUserId);
  }

  @override
  Future<KeyChange?> keyChange(String peerUserId) async {
    await _hop('keyChange:$peerUserId');
    return changes[peerUserId];
  }

  @override
  Future<DateTime?> heldSince(String conversationId) async {
    await _hop('heldSince:$conversationId');
    return held[conversationId];
  }

  @override
  Future<void> markHeld(String conversationId, DateTime at) async {
    await _hop('markHeld:$conversationId');
    final had = held[conversationId];
    if (had == null || at.isBefore(had)) held[conversationId] = at;
  }
}
