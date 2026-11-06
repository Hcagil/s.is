import UIKit

/// Background time for a notification action, behind a seam so tests can make time run out.
protocol BackgroundTime {
  func begin(expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier
  func end(_ id: UIBackgroundTaskIdentifier)
}

struct ApplicationBackgroundTime: BackgroundTime {
  func begin(expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
    UIApplication.shared.beginBackgroundTask(expirationHandler: expired)
  }

  func end(_ id: UIBackgroundTaskIdentifier) {
    UIApplication.shared.endBackgroundTask(id)
  }
}

enum NotificationActionRun {
  /// `completion` and `time.end` each run exactly once: when the work reports (ok or failed) or when time expires, whichever comes first. The expiry handler (main thread) and the URLSession callback (another queue) can race, so a lock guards the once-flag.
  static func run(time: BackgroundTime, work: (@escaping (Bool) -> Void) -> Void, completion: @escaping () -> Void) {
    let lock = NSLock()
    var finished = false
    var task: UIBackgroundTaskIdentifier = .invalid

    func finishOnce() {
      lock.lock()
      let first = !finished
      finished = true
      let id = task
      lock.unlock()
      guard first else { return }
      completion()
      if id != .invalid { time.end(id) }
    }

    let id = time.begin(expired: { })
    lock.lock()
    task = id
    let already = finished
    lock.unlock()
    // Expiry fired before the id was stored: finishOnce could not end it.
    if already && id != .invalid { time.end(id) }
    work { _ in finishOnce() }
  }
}
