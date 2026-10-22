import Foundation
import Security

enum KeychainRead: Equatable {
  case value(String)
  case missing
  case error(OSStatus)
}

/// One generic-password item as flutter_secure_storage keeps it (service flutter_secure_storage_service, account = the key name). Every call names its access group.
protocol KeychainItems {
  func read(account: String, group: String) -> KeychainRead
  func add(account: String, value: String, group: String) -> OSStatus
  func delete(account: String, group: String) -> OSStatus
}

/// The real keychain.
struct SecKeychainItems: KeychainItems {
  private static let service = "flutter_secure_storage_service"

  private static func baseQuery(account: String, group: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: group,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func read(account: String, group: String) -> KeychainRead {
    var query = SecKeychainItems.baseQuery(account: account, group: group)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return .missing }
    guard status == errSecSuccess else { return .error(status) }
    guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { return .error(errSecDecode) }
    return .value(text)
  }

  func add(account: String, value: String, group: String) -> OSStatus {
    var query = SecKeychainItems.baseQuery(account: account, group: group)
    query[kSecValueData as String] = Data(value.utf8)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(query as CFDictionary, nil)
  }

  func delete(account: String, group: String) -> OSStatus {
    SecItemDelete(SecKeychainItems.baseQuery(account: account, group: group) as CFDictionary)
  }
}

enum KeychainMigration {
  static let accounts = ["sis.store.key", "sis.olm.pickle.key"]

  enum Outcome: Equatable {
    case nothingToMove
    case moved
    case alreadyThere
    case conflict
    case failed
  }

  /// Idempotent and safe to stop at any step: it runs on every start. The legacy copy is deleted only after the new copy was read back and compared; a conflict or any error deletes nothing. A failed account never stops the next one.
  static func migrate(items: KeychainItems, legacyGroup: String, newGroup: String) -> [String: Outcome] {
    var result: [String: Outcome] = [:]
    for account in accounts {
      result[account] = move(account, items: items, legacyGroup: legacyGroup, newGroup: newGroup)
    }
    return result
  }

  private static func move(_ account: String, items: KeychainItems, legacyGroup: String, newGroup: String) -> Outcome {
    let value: String
    switch items.read(account: account, group: legacyGroup) {
    case .value(let legacy): value = legacy
    case .missing: return .nothingToMove
    case .error: return .failed
    }
    switch items.read(account: account, group: newGroup) {
    case .error:
      return .failed
    case .value(let existing):
      guard existing == value else { return .conflict }
      return removeLegacy(account, items: items, group: legacyGroup, done: .alreadyThere)
    case .missing:
      let added = items.add(account: account, value: value, group: newGroup)
      guard added == errSecSuccess || added == errSecDuplicateItem else { return .failed }
      guard case .value(let back) = items.read(account: account, group: newGroup), back == value else { return .failed }
      return removeLegacy(account, items: items, group: legacyGroup, done: .moved)
    }
  }

  private static func removeLegacy(_ account: String, items: KeychainItems, group: String, done: Outcome) -> Outcome {
    let status = items.delete(account: account, group: group)
    return status == errSecSuccess || status == errSecItemNotFound ? done : .failed
  }
}
