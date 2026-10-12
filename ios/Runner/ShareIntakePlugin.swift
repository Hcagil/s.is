import Flutter
import UIKit

// The iOS side of the `sis/share_intake` channel (MainActivity.kt serves it on
// Android). The Share Extension (ios/ShareExtension) leaves what another app
// shared in the App Group container; this plugin hands it to Dart once: photos
// are resized to JPEG, videos are moved into the caches dir, the leftovers are
// deleted.
final class ShareIntakePlugin: NSObject, FlutterPlugin {
  private static let appGroup = "group.com.esd.sis"
  private static let imageEdge = 1600

  private var channel: FlutterMethodChannel?
  private static var shared: ShareIntakePlugin?
  private let worker = DispatchQueue(label: "sis.share", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "sis/share_intake", binaryMessenger: registrar.messenger())
    let plugin = ShareIntakePlugin()
    plugin.channel = channel
    registrar.addMethodCallDelegate(plugin, channel: channel)
    shared = plugin
    plugin.removeStale()
    // A share that arrives while SIS is in the background is announced when the app comes forward.
    NotificationCenter.default.addObserver(
      plugin, selector: #selector(becameActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func becameActive() {
    if hasPending() { channel?.invokeMethod("arrived", arguments: nil) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "take":
      worker.async {
        let map = self.readNext()
        DispatchQueue.main.async { result(map) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sharedRoot() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareIntakePlugin.appGroup)?
      .appendingPathComponent("shared", isDirectory: true)
  }

  // Share folders that have their manifest (the extension writes it last).
  private func pendingFolders() -> [URL] {
    guard let root = sharedRoot(),
      let folders = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey])
    else { return [] }
    return folders
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
      .sorted {
        let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return first < second
      }
  }

  private func hasPending() -> Bool { !pendingFolders().isEmpty }

  private func readNext() -> [String: Any]? {
    guard let folder = pendingFolders().first else { return nil }
    defer { try? FileManager.default.removeItem(at: folder) }
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let text = manifest["text"] as? String
    var items: [[String: Any]] = []
    for entry in manifest["items"] as? [[String: Any]] ?? [] {
      guard let file = entry["file"] as? String, let name = entry["name"] as? String else { continue }
      let url = folder.appendingPathComponent(file)
      if entry["video"] as? Bool == true {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("shared-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.moveItem(at: url, to: target)) != nil else { continue }
        items.append(["path": target.path, "name": name, "video": true])
      } else if let jpeg = try? PickedImageProcessor.process(url: url, maxEdge: ShareIntakePlugin.imageEdge) {
        items.append(["path": jpeg, "name": name, "video": false])
      }
    }
    if text == nil && items.isEmpty { return nil }
    var map: [String: Any] = ["items": items]
    if let text = text { map["text"] = text }
    return map
  }

  // Shares the app never picked up (it was not opened) must not pile up.
  private func removeStale() {
    guard let root = sharedRoot(),
      let folders = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey])
    else { return }
    for folder in folders {
      let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      if Date().timeIntervalSince(created) > 24 * 60 * 60 { try? FileManager.default.removeItem(at: folder) }
    }
  }
}
