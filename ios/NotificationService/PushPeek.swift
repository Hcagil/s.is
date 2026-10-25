import CryptoKit
import Foundation
import Security

/// Reads keys from the keychain.
enum PeekKeychain {
  static let service = "flutter_secure_storage_service"
  static let groupSuffix = ".com.esd.sis.crypto"

  /// Returns the crypto group from the keychain, or nil if not found or invalid.
  static func cryptoGroup() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "sis.store.key",
      kSecAttrSynchronizable as String: false,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }

    guard let attributes = result as? [String: Any],
          let group = attributes[kSecAttrAccessGroup as String] as? String,
          group.hasSuffix(groupSuffix) else {
      return nil
    }

    return group
  }

  /// Returns the value for an account in a keychain group, or nil if not found.
  static func value(account: String, group: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: group,
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }

    guard let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
      return nil
    }

    return value
  }
}

/// Handles push notification peeking.
enum PushPeek {
  static let appGroup = "group.com.esd.sis"
  static let storeFileName = "sis_store.sqlite"

  /// Extracts the text from a push notification using the given decryptor.
  static func text(for userInfo: [AnyHashable: Any], decryptor: PeekDecryptor = RustPeekDecryptor()) -> String? {
    peek(for: userInfo, decryptor: decryptor).text
  }

  /// The text of an encrypted push (nil when it cannot be opened) and the chat partner's name from the phone's own copy of the chat (nil when the phone has none).
  static func peek(for userInfo: [AnyHashable: Any], decryptor: PeekDecryptor = RustPeekDecryptor()) -> (text: String?, name: String?) {
    guard let push = PeekPush(userInfo: userInfo) else { return (nil, nil) }

    guard let store = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(storeFileName) else { return (nil, nil) }
    guard FileManager.default.fileExists(atPath: store.path) else { return (nil, nil) }

    guard let group = PeekKeychain.cryptoGroup() else { return (nil, nil) }

    guard let storeKeyHex = PeekKeychain.value(account: "sis.store.key", group: group),
          let pickleHex = PeekKeychain.value(account: "sis.olm.pickle.key", group: group),
          isHex64(storeKeyHex),
          isHex64(pickleHex) else {
      return (nil, nil)
    }

    var pickleKey = bytes(fromHex: pickleHex)
    defer { pickleKey.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }

    guard let data = PeekStoreReader.read(path: store.path, keyHex: storeKeyHex, conversationId: push.conversationId, messageId: push.messageId, senderKey: push.senderKey, senderId: push.senderId) else {
      return (nil, nil)
    }

    let opened = PeekCore.opened(push: push, data: data, pickleKey: pickleKey, decryptor: decryptor)
    // Save only a text a STORED session or key opened, for the chat partner the store knows (never the push's own sender key or id). Runs here, before the extension hands its content to the system, so the store connection is already closed.
    if let opened = opened, opened.storedKey, let peer = data.peerUserId {
      _ = PeekStoreReader.save(path: store.path, keyHex: storeKeyHex, conversationId: push.conversationId, messageId: push.messageId, peerUserId: peer, body: opened.text, sealed: sealedHash(push.ct), receivedAtMicros: Int64(Date().timeIntervalSince1970 * 1_000_000))
    }
    return (opened?.text, data.peerName)
  }

  /// Formats the shown body of a notification.
  static func shownBody(text: String, sender: String?) -> String {
    let body = (sender?.isEmpty == false) ? "\(sender!): \(text)" : text
    return String(body.prefix(1000))
  }

  /// The same hash the app's opener keeps in `sealed`: SHA-256 of the ciphertext string's UTF-8 bytes, lowercase hex.
  static func sealedHash(_ ct: String) -> String {
    SHA256.hash(data: Data(ct.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Checks if a string is a valid hex64 string.
  private static func isHex64(_ s: String) -> Bool {
    guard s.utf8.count == 64 else { return false }
    return s.utf8.allSatisfy { c in (48...57).contains(c) || (97...102).contains(c) }
  }

  /// Converts a hex string to bytes.
  private static func bytes(fromHex s: String) -> [UInt8] {
    let chars = Array(s.utf8)
    func nibble(_ c: UInt8) -> UInt8 { return c <= 57 ? c - 48 : c - 87 }
    return stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) << 4 | nibble(chars[$0 + 1]) }
  }
}
