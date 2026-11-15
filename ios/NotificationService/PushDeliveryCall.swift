import Foundation

/// Sends a delivery request using an ephemeral URLSession, refusing redirects and swallowing all errors and answers. Nothing is logged: the request holds a token.
final class URLSessionDeliveryCaller: NSObject, DeliveryCalling, URLSessionTaskDelegate {
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var session: URLSession?
  private var completion: (() -> Void)?

  func send(_ request: URLRequest, completion: @escaping () -> Void) {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = PushDelivery.timeout
    config.timeoutIntervalForResource = PushDelivery.timeout // hard cap on the whole request, not only idle time
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: request) { [weak self] _, _, _ in
      self?.finish()
    }
    lock.lock()
    self.task = task
    self.session = session
    self.completion = completion
    lock.unlock()
    task.resume()
  }

  func cancel() {
    lock.lock(); let t = task; lock.unlock()
    t?.cancel()
    finish()
  }

  /// The one place the completion runs, once; the session is released after it.
  private func finish() {
    lock.lock()
    let c = completion, s = session
    completion = nil
    session = nil
    lock.unlock()
    s?.invalidateAndCancel()
    c?()
  }

  // A redirect is never followed: the delivery endpoint answers directly.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
