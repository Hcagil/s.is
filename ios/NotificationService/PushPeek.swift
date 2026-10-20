import Foundation
import Security

/// Read-only keychain access for the extension: it never adds, updates or deletes an item.
enum PeekKeychain {
  static let service = "flutter_secure_storage_service"
  static let groupSuffix = ".com.esd.sis.crypto"

  /// The keychain access group of the shared keys: a read-only attribute lookup of the store key item without a group filter. The group it reports must end with groupSuffix, else nil.
  static func cryptoGroup() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "sis.store.key",
      kSecAttrSynchronizable as String: false,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let attributes = result as? [String: Any],
          let group = attributes[kSecAttrAccessGroup as String] as? String,
          group.hasSuffix(groupSuffix) else { return nil }
    return group
  }

  /// The text value of the item (service, account) in the explicit [group], or nil.
  static func value(account: String, group: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: group,
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

enum PushPeek {
  static let appGroup = "group.com.esd.sis"
  static let storeFileName = "sis_store.sqlite"

  /// The real text of an encrypted push, or nil (then the notification keeps today's locked text). Reads the App Group store and the two keys read-only, decrypts on copies and saves nothing.
  static func text(for userInfo: [AnyHashable: Any], decryptor: PeekDecryptor = RustPeekDecryptor()) -> String? {
    guard let push = PeekPush(userInfo: userInfo),
          let store = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(storeFileName),
          FileManager.default.fileExists(atPath: store.path),
          let group = PeekKeychain.cryptoGroup(),
          let storeKeyHex = PeekKeychain.value(account: "sis.store.key", group: group),
          let pickleHex = PeekKeychain.value(account: "sis.olm.pickle.key", group: group),
          isHex64(storeKeyHex), isHex64(pickleHex) else { return nil }
    var pickleKey = bytes(fromHex: pickleHex)
    defer { pickleKey.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard let data = PeekStoreReader.read(path: store.path, keyHex: storeKeyHex, conversationId: push.conversationId, messageId: push.messageId) else { return nil }
    return PeekCore.text(push: push, data: data, pickleKey: pickleKey, decryptor: decryptor)
  }

  /// What the notification body becomes: "sender: text" when the push carries a sender (a group chat), else the text; at most 1000 characters.
  static func shownBody(text: String, sender: String?) -> String {
    let body = (sender?.isEmpty == false) ? "\(sender!): \(text)" : text
    return String(body.prefix(1000))
  }

  private static func isHex64(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
  }

  /// 32 bytes from 64 lowercase hex characters (checked by isHex64).
  private static func bytes(fromHex s: String) -> [UInt8] {
    let chars = Array(s.utf8)
    func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
    return stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) << 4 | nibble(chars[$0 + 1]) }
  }
}
