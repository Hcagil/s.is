import Flutter
import Foundation
import Security

/// The app's keychain access groups. The keys live in the dedicated group TEAMID.com.esd.sis.crypto (shared with the notification extension only); the old default group TEAMID.com.esd.sis stays first in Runner.entitlements.
enum SisKeychain {
  static let appSuffix = ".com.esd.sis"
  static let cryptoName = "com.esd.sis.crypto"

  /// The app's default keychain access group (the FIRST entry of keychain-access-groups, "TEAMID.com.esd.sis"), found without needing the team id at build time: add a probe item with NO group (it lands in the default group), read its kSecAttrAccessGroup, delete the probe. Nil when the app is not signed (errSecMissingEntitlement or any other failure) or the group does not end with appSuffix.
  static func defaultGroup() -> String? {
    let probe: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "sis.keychain.probe",
      kSecAttrAccount as String: "probe",
    ]
    var add = probe
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecValueData as String] = Data([0])
    add[kSecReturnAttributes as String] = true
    var result: AnyObject?
    var status = SecItemAdd(add as CFDictionary, &result)
    if status == errSecDuplicateItem {
      // A probe left by an interrupted start: read it instead.
      var find = probe
      find[kSecReturnAttributes as String] = true
      find[kSecMatchLimit as String] = kSecMatchLimitOne
      status = SecItemCopyMatching(find as CFDictionary, &result)
    }
    let group = status == errSecSuccess ? (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String : nil
    SecItemDelete(probe as CFDictionary)
    guard let group, group.hasSuffix(appSuffix) else { return nil }
    return group
  }

  private static var cachedCryptoGroup: String?

  /// "TEAMID.com.esd.sis.crypto": the team part of defaultGroup() plus the crypto name. Nil when defaultGroup() is nil.
  static func cryptoGroup() -> String? {
    if let cached = cachedCryptoGroup { return cached }
    guard let base = defaultGroup() else { return nil }
    let group = "\(base.dropLast(appSuffix.count)).\(cryptoName)"
    cachedCryptoGroup = group
    return group
  }

  /// Runs the key move at app start, BEFORE Flutter starts. Does nothing when the groups are unknown (an unsigned build). Never throws.
  static func runMigration(items: KeychainItems = SecKeychainItems()) {
    guard let legacy = defaultGroup(), let new = cryptoGroup() else {
      // Unsigned build or unknown group: change nothing, the keys stay where they are. No key material is logged.
      NSLog("SisKeychain: keychain group unknown, keys not moved")
      return
    }
    _ = KeychainMigration.migrate(items: items, legacyGroup: legacy, newGroup: new)
  }

  /// The channel "sis/keychain": method "cryptoGroup" returns the group string, or nil (Dart then uses no group, as on a simulator).
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "sis/keychain", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "cryptoGroup" {
        result(cryptoGroup())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
