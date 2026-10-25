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
  let senderKey: String?
  let senderId: String?

  /// Nil when it is not encrypted ("encrypted" != "true"), a key is missing or empty, or "ot" is not "0" or "1".
  /// sk/si are optional and not shape-checked here.
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
    self.senderKey = (userInfo["sk"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    self.senderId = (userInfo["si"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
  /// A stored session with the push's sender key belongs to a peer other than the push's sender id.
  var keyElsewhere = false
  /// The chat partner's display name from the phone's own copy of the chat, or nil.
  var peerName: String? = nil
  /// messages.sender_id of the stored row (storedBody), or nil.
  var storedSenderId: String? = nil
}

/// A text a push opened, and whether a key already stored on the phone opened it (a stored session, or an inbound session built with the stored peer key). Only such a text may be saved; the push's own sender key (first contact) and an already stored body never qualify.
struct PeekOpened: Equatable {
  let text: String
  let storedKey: Bool
}

enum PeekCore {
  /// The stand-in body every locked row holds (lib/features/chat/domain/encrypted_message_repository.dart lockedBodyPlaceholder).
  static let lockedPlaceholder = "🔒 Encrypted message"

  /// The real text of a locked push, or nil (then the notification keeps today's locked text). Rules in this order:
  /// 1. data.ownerId must equal push.userId, else nil.
  /// 2. A stored body that is not the placeholder is returned as is (no Olm) only when data.storedSenderId == data.peerUserId (non-nil); otherwise rules 3-5 apply.
  /// 3. data.peerUserId must be non-nil, else nil; for olmType 0 it falls back to push.senderId. A push senderId that differs from a known peer => nil.
  /// 4. olmType 1: try each session whose peerUserId == the peer, in order; the first non-nil decrypt wins; none => nil.
  /// 5. olmType 0: id = decryptor.prekeySessionId(ct) (nil => nil). If a session has sessionId == id: it must have peerUserId == the peer (else nil); return decryptor.decrypt for it. Otherwise data.account must be non-nil and the result is decryptor.decryptInbound with the newest session's identity key; with no session, push.senderKey is used only if it and senderId are well-formed, senderId == peer and data.keyElsewhere is false.
  static func opened(push: PeekPush, data: PeekData, pickleKey: [UInt8], decryptor: PeekDecryptor) -> PeekOpened? {
    guard data.ownerId == push.userId else { return nil }
    // A stored text is the peer's preview only when the peer sent it; else go on to decrypt.
    if let body = data.storedBody, body != lockedPlaceholder, let known = data.peerUserId, data.storedSenderId == known { return PeekOpened(text: body, storedKey: false) }
    guard let peer = data.peerUserId ?? (push.olmType == 0 ? push.senderId : nil) else { return nil }
    if let si = push.senderId, let known = data.peerUserId, si != known { return nil }

    if push.olmType == 1 {
      for session in data.sessions where session.peerUserId == peer {
        if let text = decryptor.decrypt(sessionPickle: session.pickle, pickleKey: pickleKey, messageId: push.messageId, ct: push.ct, olmType: 1) {
          return PeekOpened(text: text, storedKey: true)
        }
      }
      return nil
    }

    guard let id = decryptor.prekeySessionId(ct: push.ct) else { return nil }
    if let session = data.sessions.first(where: { $0.sessionId == id }) {
      guard session.peerUserId == peer else { return nil }
      guard let text = decryptor.decrypt(sessionPickle: session.pickle, pickleKey: pickleKey, messageId: push.messageId, ct: push.ct, olmType: 0) else { return nil }
      return PeekOpened(text: text, storedKey: true)
    }
    guard let account = data.account else { return nil }
    let identityKey: String
    if let newest = data.sessions.first {
      guard newest.peerUserId == peer else { return nil }
      identityKey = newest.identityKey  // a stored session of this peer wins; sk is ignored
    } else if let sk = push.senderKey, let si = push.senderId, isSenderKey(sk), isUuid(si), si == peer, !data.keyElsewhere {
      identityKey = sk
    } else {
      return nil
    }
    let storedKey = !data.sessions.isEmpty  // false when the key came from the push's sk
    guard let text = decryptor.decryptInbound(accountPickle: account, pickleKey: pickleKey, identityKey: identityKey, messageId: push.messageId, ct: push.ct) else { return nil }
    return PeekOpened(text: text, storedKey: storedKey)
  }

  static func text(push: PeekPush, data: PeekData, pickleKey: [UInt8], decryptor: PeekDecryptor) -> String? {
    opened(push: push, data: data, pickleKey: pickleKey, decryptor: decryptor)?.text
  }

  private static func isSenderKey(_ s: String) -> Bool {
    guard s.utf8.count == 43 else { return false }
    for byte in s.utf8 {
      if (byte < 65 || byte > 90) && (byte < 97 || byte > 122) && (byte < 48 || byte > 57) && byte != 43 && byte != 47 {
        return false
      }
    }
    return true
  }

  private static func isUuid(_ s: String) -> Bool {
    return s.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
  }
}
