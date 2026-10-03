import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The app's own channel: "From an app" and the square crop (the iOS twin
    // of the one MainActivity.kt serves on Android).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ExternalPickerPlugin") {
      ExternalPickerPlugin.register(with: registrar)
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
