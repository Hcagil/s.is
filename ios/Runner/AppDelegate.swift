import Flutter
import GoogleMaps
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before Flutter starts: move the store and pickle keys to the crypto keychain group (idempotent; see KeychainMigration.swift).
    SisKeychain.runMigration()
    excludeSupportFromBackup()
    // Google Maps starts only with a key; with none, Dart uses OpenStreetMap and never builds a GoogleMap.
    if let mapsKey = Bundle.main.object(forInfoDictionaryKey: "MapsApiKey") as? String, !mapsKey.isEmpty, !mapsKey.hasPrefix("$(") {
      GMSServices.provideAPIKey(mapsKey)
    }
    registerMessageActions()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private static let messageCategory = "SIS_MESSAGE"
  private static let lockedCategory = "SIS_MESSAGE_LOCKED"
  private static let markReadAction = "SIS_MARK_READ"
  private static let replyAction = "SIS_REPLY"
  /// Replies typed into a private chat's notification: memory only, never written to disk or logged. Dart takes them (channel sis/encrypted_reply) and sends them through the normal encrypted send queue; nothing is encrypted here.
  private static var pendingReplies: [[String: String]] = []
  private var replyChannel: FlutterMethodChannel?

  /// The Reply and Mark as read buttons on a message push (the server sets aps.category to SIS_MESSAGE). The system draws APNs alerts itself, so the buttons are a notification category registered here; titles follow the phone language (tr or English).
  private func registerMessageActions() {
    let turkish = Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
    let reply = UNTextInputNotificationAction(identifier: AppDelegate.replyAction, title: turkish ? "Yanıtla" : "Reply", options: [.authenticationRequired], textInputButtonTitle: turkish ? "Gönder" : "Send", textInputPlaceholder: turkish ? "Mesaj" : "Message")
    let markRead = UNNotificationAction(identifier: AppDelegate.markReadAction, title: turkish ? "Okundu olarak işaretle" : "Mark as read", options: [])
    let category = UNNotificationCategory(identifier: AppDelegate.messageCategory, actions: [reply, markRead], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: turkish ? "Yeni mesaj" : "New message", options: [])
    // An encrypted chat's push (the server sets SIS_MESSAGE_LOCKED) has no Mark as read; its Reply opens SIS (.foreground) after the unlock (.authenticationRequired), and the app locks and sends the text. Never encrypted in the extension or in the background.
    let lockedReply = UNTextInputNotificationAction(identifier: AppDelegate.replyAction, title: turkish ? "Yanıtla" : "Reply", options: [.authenticationRequired, .foreground], textInputButtonTitle: turkish ? "Gönder" : "Send", textInputPlaceholder: turkish ? "Mesaj" : "Message")
    let locked = UNNotificationCategory(identifier: AppDelegate.lockedCategory, actions: [lockedReply], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: turkish ? "Yeni mesaj" : "New message", options: [])
    UNUserNotificationCenter.current().setNotificationCategories([category, locked])
  }

  /// A tap on one of the buttons. There is no Supabase session here: the push carries a signed action token and the function address (action_token, action_url), which the notification-action function checks. Returns false for any other response (a plain tap, other categories), which then goes on to the Flutter plugins as before. Replies get a fresh message id, sent again unchanged on one retry, so the server never stores a reply twice.
  private func handleMessageAction(_ response: UNNotificationResponse, completion: @escaping () -> Void) -> Bool {
    let action = response.actionIdentifier
    // A Reply in a private chat never goes to the function: the text is kept in memory for the app to lock and send.
    if action == AppDelegate.replyAction && response.notification.request.content.categoryIdentifier == AppDelegate.lockedCategory {
      handleEncryptedReply(response)
      completion()
      return true
    }
    guard action == AppDelegate.markReadAction || action == AppDelegate.replyAction else { return false }
    let content = response.notification.request.content
    let info = content.userInfo
    guard let token = info["action_token"] as? String, !token.isEmpty,
      let address = info["action_url"] as? String, address.hasPrefix("https://"), let url = URL(string: address),
      let conversation = info["conversation_id"] as? String, !conversation.isEmpty
    else { completion(); return true }
    var body: [String: Any] = ["token": token, "conversation_id": conversation]
    var reply: String? = nil
    if action == AppDelegate.replyAction {
      guard let input = response as? UNTextInputNotificationResponse else { completion(); return true }
      let text = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.utf16.count <= 4000 else { completion(); return true }
      reply = text
      body["action"] = "reply"
      body["id"] = UUID().uuidString.lowercased()
      body["body"] = text
    } else {
      body["action"] = "mark_read"
    }
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { completion(); return true }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    var background = UIBackgroundTaskIdentifier.invalid
    background = UIApplication.shared.beginBackgroundTask {
      UIApplication.shared.endBackgroundTask(background)
      background = .invalid
    }
    func finish(_ ok: Bool) {
      if ok {
        // Reading from here clears the chat's other delivered pushes too (matched by thread id, as the clearThread channel does).
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
          let ids = delivered.filter { $0.request.content.threadIdentifier == conversation }.map { $0.request.identifier }
          if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
      } else if let reply = reply {
        // The system dismissed the notification when the reply was sent; say so if it did not go through.
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = (Locale.preferredLanguages.first?.hasPrefix("tr") ?? false ? "Gönderilemedi: " : "Not sent: ") + reply
        note.threadIdentifier = conversation
        note.userInfo = ["conversation_id": conversation]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil))
      }
      completion()
      if background != .invalid {
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
      }
    }
    func send(retry: Bool) {
      URLSession.shared.dataTask(with: request) { _, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil && status == 200 { return finish(true) }
        // 429, 5xx and no answer are passing failures: try once more.
        if retry && (error != nil || status == 429 || status >= 500) { return send(retry: false) }
        finish(false)
      }.resume()
    }
    send(retry: true)
    return true
  }

  /// Keeps a private chat's Reply for Dart: the typed text, the chat and the member the push was for, with a message id made now (tap time). Anything odd is dropped.
  private func handleEncryptedReply(_ response: UNNotificationResponse) {
    let info = response.notification.request.content.userInfo
    guard let input = response as? UNTextInputNotificationResponse,
      let conversation = info["conversation_id"] as? String, !conversation.isEmpty,
      let user = info["user_id"] as? String, !user.isEmpty
    else { return }
    let text = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf16.count <= 4000 else { return }
    AppDelegate.pendingReplies.append(["id": UUID().uuidString.lowercased(), "conversation_id": conversation, "user_id": user, "text": text])
    replyChannel?.invokeMethod("arrived", arguments: nil)
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if handleMessageAction(response, completion: completionHandler) { return }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// The chat list snapshot and the last-session marker live in Application
  /// Support; keep them out of iCloud and iTunes backups.
  private func excludeSupportFromBackup() {
    guard var url = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first else { return }
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The app's own channel: "From an app" and the square crop (the iOS twin
    // of the one MainActivity.kt serves on Android).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ExternalPickerPlugin") {
      ExternalPickerPlugin.register(with: registrar)
    }
    // The keychain group the Dart key stores must name (see SisKeychain.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SisKeychain") {
      SisKeychain.register(with: registrar)
    }
    // Share into SIS: hands what the Share Extension left in the App Group to Dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShareIntakePlugin") {
      ShareIntakePlugin.register(with: registrar)
    }
    // Replies typed into a private chat's notification (see handleEncryptedReply): Dart takes them once.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EncryptedReply") {
      let channel = FlutterMethodChannel(name: "sis/encrypted_reply", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "take" else { result(FlutterMethodNotImplemented); return }
        let taken = AppDelegate.pendingReplies
        AppDelegate.pendingReplies = []
        result(taken)
      }
      replyChannel = channel
    }
    // Reading a chat removes that chat's delivered pushes: the system drew
    // them (APNs), so the Flutter notifications plugin cannot see them. They
    // are matched by thread id, which the server sets to the conversation id.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SisNotifications") {
      let channel = FlutterMethodChannel(
        name: "sis/notifications", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        // The app-icon number, set from Dart (unread total) whenever it changes.
        if call.method == "setBadge" {
          let count = (call.arguments as? Int) ?? 0
          DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
              UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
            } else {
              UIApplication.shared.applicationIconBadgeNumber = count
            }
            result(nil)
          }
          return
        }
        guard call.method == "clearThread", let thread = call.arguments as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
          let ids = delivered
            .filter { $0.request.content.threadIdentifier == thread }
            .map { $0.request.identifier }
          if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
          DispatchQueue.main.async { result(nil) }
        }
      }
    }
  }
}
