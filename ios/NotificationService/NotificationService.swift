import UIKit
import UserNotifications

/// Adds the small picture of a photo or video message to its notification (see NotificationPicture.kt for the Android twin). Runs inside the system's 30 s budget; the download gives up after 10 s so the text always arrives.
final class NotificationService: UNNotificationServiceExtension, URLSessionDownloadDelegate {
  private let lock = NSLock()
  private var handler: ((UNNotificationContent) -> Void)?
  private var content: UNMutableNotificationContent?
  private var task: URLSessionDownloadTask?
  private var video = false

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    lock.lock(); handler = contentHandler; content = mutable; lock.unlock()
    // Only our own Supabase host: the push's action link is built from the same SUPABASE_URL as the picture link.
    guard let link = mutable.userInfo["thumb_url"] as? String, let url = URL(string: link), url.scheme == "https", let actionLink = mutable.userInfo["action_url"] as? String, let actionHost = URL(string: actionLink)?.host, let host = url.host, host.lowercased() == actionHost.lowercased() else {
      finish()
      return
    }
    video = (mutable.userInfo["thumb_kind"] as? String) == "video"
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    // The link is a short-lived signed link: it is never logged.
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    let task = session.downloadTask(with: url)
    self.task = task
    task.resume()
  }

  override func serviceExtensionTimeWillExpire() {
    task?.cancel()
    finish()
  }

  /// Hands the content (with the picture when there is one) to the system, once.
  private func finish() {
    lock.lock()
    let h = handler, c = content
    handler = nil
    lock.unlock()
    if let h = h, let c = c { h(c) }
  }

  /// [image] with a round dark badge and a white play triangle in the middle (the video's poster).
  static func withPlayMark(_ image: UIImage) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(at: .zero)
      let cx = image.size.width / 2
      let cy = image.size.height / 2
      let d = min(image.size.width, image.size.height) * 0.28
      UIColor(white: 0, alpha: 0.6).setFill()
      UIBezierPath(ovalIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)).fill()
      let t = d * 0.22
      let triangle = UIBezierPath()
      triangle.move(to: CGPoint(x: cx - t * 0.6, y: cy - t))
      triangle.addLine(to: CGPoint(x: cx - t * 0.6, y: cy + t))
      triangle.addLine(to: CGPoint(x: cx + t * 1.1, y: cy))
      triangle.close()
      UIColor.white.setFill()
      triangle.fill()
    }
  }

  // A redirect is never followed: the signed link answers directly.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  // Stops the download as soon as it passes 256 KiB, not after it is all on disk.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > 262_144 {
      downloadTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let response = downloadTask.response as? HTTPURLResponse,
          response.statusCode == 200,
          let data = try? Data(contentsOf: location),
          data.count <= 262_144,
          let image = UIImage(data: data) else { return }
    let shown = video ? NotificationService.withPlayMark(image) : image
    guard let jpeg = shown.jpegData(compressionQuality: 0.85) else { return }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    guard (try? jpeg.write(to: file)) != nil,
          let attachment = try? UNNotificationAttachment(identifier: "picture", url: file, options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]) else { return }
    lock.lock(); content?.attachments = [attachment]; lock.unlock()
  }

  // Success, failure or cancel: the one place the content goes to the system.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    finish()
  }
}
