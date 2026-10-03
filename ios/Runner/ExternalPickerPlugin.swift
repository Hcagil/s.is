import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// The iOS side of the `sis/external_picker` channel MainActivity.kt serves on
// Android, with the same method names, arguments and results. "From an app"
// is the system photo picker (PHPicker): it runs out of process, needs no
// photo-library permission and hands back only what the member chose.
final class ExternalPickerPlugin: NSObject, FlutterPlugin, PHPickerViewControllerDelegate,
  UIImagePickerControllerDelegate, UINavigationControllerDelegate
{
  private static let attachmentEdge = 1600
  private static let pictureEdge = 2048
  private static let maxAttachments = 10

  private var pending: FlutterResult?
  private var pendingIsPicture = false

  // PickedImageProcessor does file I/O and image decoding; keep it off the
  // main thread, one job at a time.
  private let worker = DispatchQueue(label: "sis.picker", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "sis/external_picker", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ExternalPickerPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickAttachments":
      present(isPicture: false, result: result)
    case "pickProfilePicture":
      present(isPicture: true, result: result)
    case "takePhoto":
      takePhoto(result: result)
    case "cropPicture":
      crop(call.arguments as? [String: Any], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func topViewController() -> UIViewController? {
    var top = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?
      .rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  // The camera: one photo taken now, replied exactly like pickAttachments
  // (`paths` + `dropped`). Needs NSCameraUsageDescription in Info.plist.
  private func takePhoto(result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "A picker is already open.", details: nil))
      return
    }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(FlutterError(code: "no_camera", message: "No camera on this device.", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "no_app", message: "No app can open the camera.", details: nil))
      return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image"]
    picker.delegate = self
    pending = result
    pendingIsPicture = false
    host.present(picker, animated: true)
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    guard let reply = pending else { return }
    pending = nil
    reply(nil)  // cancelled: not a failure
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard let reply = pending else { return }
    pending = nil
    guard let image = info[.originalImage] as? UIImage else {
      reply(FlutterError(code: "unreadable", message: "Could not read the photo.", details: nil))
      return
    }
    worker.async {
      // jpegData writes the camera's orientation into the EXIF, which
      // PickedImageProcessor then applies.
      let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-\(UUID().uuidString).jpg")
      defer { try? FileManager.default.removeItem(at: temp) }
      do {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
          throw PickedImageError.notImage
        }
        try data.write(to: temp)
        let path = try PickedImageProcessor.process(
          url: temp, maxEdge: ExternalPickerPlugin.attachmentEdge)
        DispatchQueue.main.async { reply(["paths": [path], "dropped": 0]) }
      } catch {
        DispatchQueue.main.async {
          reply(FlutterError(code: "unreadable", message: "Could not read the photo.", details: nil))
        }
      }
    }
  }

  private func present(isPicture: Bool, result: @escaping FlutterResult) {
    if pending != nil {
      result(FlutterError(code: "busy", message: "A picker is already open.", details: nil))
      return
    }
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = isPicture ? 1 : ExternalPickerPlugin.maxAttachments
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self

    guard let host = topViewController() else {
      result(FlutterError(code: "no_app", message: "No app can open photos.", details: nil))
      return
    }
    pending = result
    pendingIsPicture = isPicture
    host.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let reply = pending else { return }
    pending = nil
    if results.isEmpty {
      reply(nil)  // cancelled: not a failure
      return
    }
    let isPicture = pendingIsPicture
    let edge = isPicture ? ExternalPickerPlugin.pictureEdge : ExternalPickerPlugin.attachmentEdge
    worker.async {
      var paths: [String] = []
      var failure: FlutterError?
      for item in results {
        let done = DispatchSemaphore(value: 0)
        // The file handed to the closure is deleted when it returns, so the
        // photo is processed (copied into the caches dir) inside it.
        item.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
          url, error in
          defer { done.signal() }
          guard let url = url, error == nil else {
            failure = FlutterError(
              code: "unreadable", message: "Could not read the photo.", details: nil)
            return
          }
          do {
            paths.append(try PickedImageProcessor.process(url: url, maxEdge: edge))
          } catch PickedImageError.notImage {
            failure = FlutterError(code: "not_image", message: "Not a photo.", details: nil)
          } catch {
            failure = FlutterError(
              code: "unreadable", message: "Could not read the photo.", details: nil)
          }
        }
        done.wait()
        if failure != nil { break }
      }
      if failure != nil {
        // An orphaned output file would otherwise leak in the cache dir.
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
      }
      DispatchQueue.main.async {
        if let failure = failure {
          reply(failure)
        } else if isPicture {
          reply(paths)
        } else {
          reply(["paths": paths, "dropped": 0])
        }
      }
    }
  }

  private func crop(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard let path = args?["path"] as? String,
      let left = (args?["left"] as? NSNumber)?.doubleValue,
      let top = (args?["top"] as? NSNumber)?.doubleValue,
      let right = (args?["right"] as? NSNumber)?.doubleValue,
      let bottom = (args?["bottom"] as? NSNumber)?.doubleValue
    else {
      result(FlutterError(code: "bad_args", message: "Missing crop arguments.", details: nil))
      return
    }
    let size = (args?["size"] as? NSNumber)?.intValue ?? 640
    let quality = (args?["quality"] as? NSNumber)?.intValue ?? 82
    worker.async {
      do {
        let output = try PickedImageProcessor.crop(
          sourcePath: path, left: left, top: top, right: right, bottom: bottom,
          size: size, quality: quality)
        DispatchQueue.main.async { result(output) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "crop_failed", message: "Could not crop the photo.", details: nil))
        }
      }
    }
  }
}
