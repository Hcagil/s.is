import Foundation

/// What the notification extension reads from the small keychain item "sis.push.delivery" (written by the app, see secure_session_storage.dart).
struct DeliveryItem: Equatable {
  let accessToken: String
  let expiresAt: Int   // unix seconds
  let userId: String
  let url: String
  let key: String
}

/// Reads the item. Read-only: no add, update or delete exists on this protocol.
protocol DeliveryReading { func read() -> DeliveryItem? }

/// Sends the request and calls completion exactly once when it is over (answer, error or cancel). Never throws, never logs.
protocol DeliveryCalling {
  func send(_ request: URLRequest, completion: @escaping () -> Void)
  func cancel()
}

enum PushDelivery {
  static let timeout: TimeInterval = 5
  static let expirySlack: TimeInterval = 30

  /// nil = skip. Skips when: kind is "reaction"; conversation_id or user_id missing or empty; push user_id != item.userId; item nil; accessToken empty; key empty; expiresAt <= now + 30 s; url not parseable, not https, or no host.
  /// Otherwise a POST to <url>/rest/v1/rpc/mark_delivered with apikey and Bearer headers and the body {"conversation": id, "up_to": null}. Nothing about the destination comes from userInfo (never action_url).
  static func request(userInfo: [AnyHashable: Any], now: Date, item: DeliveryItem?) -> URLRequest? {
    guard (userInfo["kind"] as? String) != "reaction",
          let item = item,
          let conversationId = userInfo["conversation_id"] as? String, !conversationId.isEmpty,
          let userId = userInfo["user_id"] as? String, !userId.isEmpty,
          !item.accessToken.isEmpty,
          !item.key.isEmpty,
          item.userId == userId
    else { return nil }

    guard item.expiresAt > Int(now.timeIntervalSince1970 + expirySlack) else { return nil }

    guard let base = URL(string: item.url),
          base.scheme == "https",
          let host = base.host, !host.isEmpty,
          let requestUrl = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/v1/rpc/mark_delivered")
    else { return nil }

    var request = URLRequest(url: requestUrl)
    request.timeoutInterval = timeout
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(item.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(item.key, forHTTPHeaderField: "apikey")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["conversation": conversationId, "up_to": NSNull()] as [String: Any])
    return request
  }

  /// Reads the item, builds the request, sends it once. When the request is nil it calls completion at once.
  static func run(userInfo: [AnyHashable: Any], now: Date = Date(), reader: DeliveryReading, caller: DeliveryCalling, completion: @escaping () -> Void) {
    guard let request = request(userInfo: userInfo, now: now, item: reader.read()) else { completion(); return }
    caller.send(request, completion: completion)
  }
}
