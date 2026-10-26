import UIKit
import UniformTypeIdentifiers

// Share Extension: copies what another app shares (text, links, photos, videos)
// into the App Group container and opens SIS, where the member picks chats and
// taps Send. Nothing is uploaded from here. Photos and videos are copied as the
// raw files; the host app (ShareIntakePlugin) resizes photos, because an
// extension has a small memory budget.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
  private let appGroup = "group.com.esd.sis"
  private let openScheme = "sisshare://open"
  private let maxItems = 10
  private var collected = false
  private let lock = NSLock()
  private var results: [[String: Any]?] = []
  private var textList: [String] = []

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !collected else { return }
    collected = true
    collect()
  }

  private func collect() {
    let inputItems = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = Array(inputItems.flatMap { $0.attachments ?? [] }.prefix(maxItems))
    guard !providers.isEmpty,
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return finish() }

    let folder = container.appendingPathComponent("shared", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let group = DispatchGroup()
    results = Array(repeating: nil, count: providers.count)

    for (index, provider) in providers.enumerated() {
      group.enter()
      let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
      if isVideo || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
          defer { group.leave() }
          guard let url = url else { return }
          // The url is only valid inside this closure: copy it now.
          let ext = url.pathExtension.isEmpty ? (isVideo ? "mov" : "img") : url.pathExtension
          let target = folder.appendingPathComponent("\(index).\(ext)")
          // An unreadable size counts as too big (ShareRules).
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
          guard ShareRules.allowsFile(size: size, isVideo: isVideo) else { return }
          guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
          self.lock.lock()
          self.results[index] = ["file": target.lastPathComponent, "name": url.lastPathComponent, "video": isVideo]
          self.lock.unlock()
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          defer { group.leave() }
          guard let url = item as? URL, !url.isFileURL else { return }
          self.lock.lock()
          self.textList.append(url.absoluteString)
          self.lock.unlock()
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          defer { group.leave() }
          guard let string = item as? String else { return }
          self.lock.lock()
          self.textList.append(string)
          self.lock.unlock()
        }
      } else {
        group.leave()
      }
    }

    group.notify(queue: .main) {
      let items = self.results.compactMap { $0 }
      if items.isEmpty && self.textList.isEmpty {
        try? FileManager.default.removeItem(at: folder)
        return self.finish()
      }
      var manifest: [String: Any] = ["items": items]
      if !self.textList.isEmpty {
        manifest["text"] = ShareRules.clippedText(self.textList)
      }
      if let data = try? JSONSerialization.data(withJSONObject: manifest) {
        try? data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        self.openHost()
      }
      self.finish()
    }
  }

  // shortcut: relies on the responder chain reaching UIApplication, which Apple does not document for extensions; if it fails the share still waits in the App Group and is picked up the next time SIS opens.
  private func openHost() {
    guard let url = URL(string: openScheme) else { return }
    var responder: UIResponder? = self
    while let current = responder {
      if let app = current as? UIApplication {
        app.open(url, options: [:], completionHandler: nil)
        return
      }
      responder = current.next
    }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
