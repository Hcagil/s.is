import Foundation

/// Reads the small keychain item "sis.push.delivery" in the crypto group. Read-only: it only calls PeekKeychain's two read functions, never add, update or delete.
struct KeychainDeliveryReader: DeliveryReading {
  static let account = "sis.push.delivery"

  func read() -> DeliveryItem? {
    guard let group = PeekKeychain.cryptoGroup() else { return nil }
    guard let raw = PeekKeychain.value(account: Self.account, group: group) else { return nil }

    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
      return nil
    }

    guard let accessToken = obj["access_token"] as? String,
          let userId = obj["user_id"] as? String,
          let url = obj["url"] as? String,
          let key = obj["key"] as? String,
          let expiresAt = (obj["expires_at"] as? NSNumber)?.intValue else {
      return nil
    }

    return DeliveryItem(accessToken: accessToken, expiresAt: expiresAt, userId: userId, url: url, key: key)
  }
}
