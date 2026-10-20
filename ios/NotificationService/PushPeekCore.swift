import Foundation

/// The three Olm steps the extension needs; the real one calls the Rust C API, tests use a fake.
/// Every method returns the envelope text or nil. Nothing is ever saved.
protocol PeekDecryptor {
  func prekeySessionId(ct: String) -> String?
  func decrypt(sessionPickle: String, pickleKey: [UInt8], messageId: String, ct: String, olmType: Int32) -> String?
  func decryptInbound(accountPickle: String, pickleKey: [UInt8], identityKey: String, messageId: String, ct: String) -> String?
}

/// The data of an encrypted push that carries its ciphertext (FCM data keys, all strings).
struct PeekPush: Equatable {
  let messageId: String
  let conversationId: String
  let userId: String
  let ct: String
  let olmType: Int32

  /// Nil when it is not encrypted ("encrypted" != "true"), a key is missing or empty, or "ot" is not "0" or "1".
  init?(userInfo: [AnyHashable: Any]) {
    guard let encrypted = userInfo["encrypted"] as? String, encrypted == "true",
          let messageId = userInfo["message_id"] as? String, !messageId.isEmpty,
          let conversationId = userInfo["conversation_id"] as? String, !conversationId.isEmpty,
          let userId = userInfo["user_id"] as? String, !userId.isEmpty,
          let ct = userInfo["ct"] as? String, !ct.isEmpty,
          let ot = userInfo["ot"] as? String, ot == "0" || ot == "1"
    else { return nil }
    self.messageId = messageId
    self.conversationId = conversationId
    self.userId = userId
    self.ct = ct
    self.olmType = ot == "1" ? 1 : 0
  }
}

struct PeekSessionRow: Equatable {
  let sessionId: String
  let peerUserId: String
  let identityKey: String
  let pickle: String
}

/// What was read from the store; sessions are the peer's, newest first.
struct PeekData: Equatable {
  let ownerId: String?
  let peerUserId: String?
  let storedBody: String?
  let account: String?
  let sessions: [PeekSessionRow]
}

enum PeekCore {
  /// The stand-in body every locked row holds (lib/features/chat/domain/encrypted_message_repository.dart lockedBodyPlaceholder).
  static let lockedPlaceholder = "🔒 Encrypted message"

  /// The real text of a locked push, or nil (then the notification keeps today's locked text). Rules in this order:
  /// 1. data.ownerId must equal push.userId, else nil.
  /// 2. A stored body that is not the placeholder is returned as is (no Olm).
  /// 3. data.peerUserId must be non-nil, else nil.
  /// 4. olmType 1: try each session whose peerUserId == the peer, in order; the first non-nil decrypt wins; none => nil.
  /// 5. olmType 0: id = decryptor.prekeySessionId(ct) (nil => nil). If a session has sessionId == id: it must have peerUserId == the peer (else nil); return decryptor.decrypt for it. Otherwise sessions must be non-empty and data.account non-nil, and the result is decryptor.decryptInbound with the newest session's identity key.
  static func text(push: PeekPush, data: PeekData, pickleKey: [UInt8], decryptor: PeekDecryptor) -> String? {
    guard data.ownerId == push.userId else { return nil }
    if let body = data.storedBody, body != lockedPlaceholder { return body }
    guard let peer = data.peerUserId else { return nil }

    if push.olmType == 1 {
      for session in data.sessions where session.peerUserId == peer {
        if let text = decryptor.decrypt(sessionPickle: session.pickle, pickleKey: pickleKey, messageId: push.messageId, ct: push.ct, olmType: 1) {
          return text
        }
      }
      return nil
    }

    guard let id = decryptor.prekeySessionId(ct: push.ct) else { return nil }
    if let session = data.sessions.first(where: { $0.sessionId == id }) {
      guard session.peerUserId == peer else { return nil }
      return decryptor.decrypt(sessionPickle: session.pickle, pickleKey: pickleKey, messageId: push.messageId, ct: push.ct, olmType: 0)
    }
    guard let newest = data.sessions.first, let account = data.account else { return nil }
    return decryptor.decryptInbound(accountPickle: account, pickleKey: pickleKey, identityKey: newest.identityKey, messageId: push.messageId, ct: push.ct)
  }
}
