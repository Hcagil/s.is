import Foundation

/// The Olm steps, through the Rust C API (rust/include/sis_crypto.h). Each call works on copies and saves nothing.
struct RustPeekDecryptor: PeekDecryptor {
  func prekeySessionId(ct: String) -> String? { run { out, cap, len in sis_peek_prekey_session_id(ct, 0, out, cap, len) } }

  func decrypt(sessionPickle: String, pickleKey: [UInt8], messageId: String, ct: String, olmType: Int32) -> String? {
    pickleKey.withUnsafeBufferPointer { key in
      run { out, cap, len in sis_peek_session(key.baseAddress, key.count, sessionPickle, messageId, ct, olmType, out, cap, len) }
    }
  }

  func decryptInbound(accountPickle: String, pickleKey: [UInt8], identityKey: String, messageId: String, ct: String) -> String? {
    pickleKey.withUnsafeBufferPointer { key in
      run { out, cap, len in sis_peek_inbound(key.baseAddress, key.count, accountPickle, identityKey, messageId, ct, 0, out, cap, len) }
    }
  }

  /// Runs one C call with a 16 KiB output buffer; the buffer is zeroed before it is freed, whatever the result.
  private func run(_ body: (UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<Int>) -> Int32) -> String? {
    var out = [UInt8](repeating: 0, count: 16384)
    var length = 0
    let code = out.withUnsafeMutableBufferPointer { buf in body(buf.baseAddress!, buf.count, &length) }
    defer { out.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard code == 0, length <= out.count else { return nil }
    return String(decoding: out[0..<length], as: UTF8.self)
  }
}

/// Reads what a push needs from the app's encrypted store (PeekStore.c): read-only, small cache, nil when it cannot be read.
enum PeekStoreReader {
  static func read(path: String, keyHex: String, conversationId: String, messageId: String, senderKey: String?, senderId: String?) -> PeekData? {
    var rows = SisPeekRows()
    defer { sis_peek_free(&rows) }
    guard sis_peek_read(path, keyHex, conversationId, messageId, senderKey, senderId, &rows) == 0 else { return nil }

    var sessions: [PeekSessionRow] = []
    for i in 0..<Int(rows.session_count) {
      guard let id = text(rows.session_ids?[i]),
            let peer = text(rows.session_peer_ids?[i]),
            let key = text(rows.session_identity_keys?[i]),
            let pickle = text(rows.session_pickles?[i]) else { continue }
      sessions.append(PeekSessionRow(sessionId: id, peerUserId: peer, identityKey: key, pickle: pickle))
    }
    return PeekData(ownerId: text(rows.owner_id), peerUserId: text(rows.peer_user_id), storedBody: text(rows.stored_body), account: text(rows.account), sessions: sessions, keyElsewhere: rows.key_elsewhere != nil, peerName: text(rows.peer_name))
  }

  private static func text(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    p.map { String(cString: $0) }
  }
}
