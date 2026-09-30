import Flutter
import UIKit

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
  }
}
