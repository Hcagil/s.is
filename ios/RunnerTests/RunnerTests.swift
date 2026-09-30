import Flutter
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Runner

// The `sis/external_picker` channel on iOS, driven through its contract: a
// FlutterMethodCall in, a value or FlutterError out, with arguments shaped as
// the standard codec delivers Dart's (doubles and int32 NSNumbers).
//
// Fixtures are real JPEGs whose stored pixels are four coloured quadrants
// (top-left red, top-right green, bottom-left blue, bottom-right white),
// tagged with an EXIF orientation. Checking a colour at a known point of the
// output tells whether the orientation was applied, and in which direction.
//
// Orientation 6 ("rotate 90 degrees clockwise to display") turns a stored
// 400x200 into an upright 200x400 whose quadrants are
//   top-left blue, top-right red, bottom-left white, bottom-right green.
class RunnerTests: XCTestCase {

  // MARK: - cropPicture

  func testCropCutsTheUprightImageIntoANewSquareJPEG() throws {
    let src = try makeJPEG(width: 400, height: 200, orientation: 6)

    // Upright pixels (0..100, 0..100): inside the upright top-left, blue.
    let out = try XCTUnwrap(
      invoke("cropPicture", cropArgs(src.path, 0, 0, 0.5, 0.25)) as? String,
      "cropPicture did not answer a path")

    XCTAssertNotEqual(out, src.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the source was deleted")
    let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
    XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")
    let image = try decode(out)
    XCTAssertEqual(image.width, 64)
    XCTAssertEqual(image.height, 64)
    XCTAssertEqual(image.orientation, 1, "the output still carries a rotation tag")
    XCTAssertEqual(image.colour(32, 32), "blue", "crop not measured on the upright image")
  }

  func testCropDefaultsToA640Square() throws {
    let src = try makeJPEG(width: 400, height: 200, orientation: 6)
    var args = cropArgs(src.path, 0, 0, 1, 0.5)
    args.removeValue(forKey: "size")
    args.removeValue(forKey: "quality")

    let out = try XCTUnwrap(invoke("cropPicture", args) as? String)

    let image = try decode(out)
    XCTAssertEqual(image.width, 640)
    XCTAssertEqual(image.height, 640)
  }

  // Android's clamping: x = round(left*w) in 0..w-1, cropW = round((right-left)*w)
  // in 1..w-x (same for y), with w and h those of the UPRIGHT image (200x400).
  func testCropClampsTheRectangleLikeAndroidOnTheUprightImage() throws {
    let src = try makeJPEG(width: 400, height: 200, orientation: 6)
    let cases: [(String, [Double], String)] = [
      // x = 200 -> 199, width 0 -> 1: the last upright column, rows 0..100.
      ("zero width at the right edge", [1, 0, 1, 0.25], "red"),
      // x, y below 0 -> 0: upright (0..150, 0..250), centre (75, 125).
      ("negative left and top", [-0.5, -0.5, 0.25, 0.125], "blue"),
      // width 900 -> 100, height 1700 -> 100: upright (100..200, 300..400).
      ("right and bottom far past the edge", [0.5, 0.75, 5, 5], "green"),
    ]
    for (name, r, colour) in cases {
      let answer = invoke("cropPicture", cropArgs(src.path, r[0], r[1], r[2], r[3]))
      let out = try XCTUnwrap(answer as? String, "\(name): answered \(String(describing: answer))")
      let image = try decode(out)
      XCTAssertEqual(image.width, 64, name)
      XCTAssertEqual(image.height, 64, name)
      XCTAssertEqual(image.colour(32, 32), colour, name)
    }
  }

  func testCropWithoutARequiredArgumentIsBadArgs() throws {
    let src = try makeJPEG(width: 400, height: 200, orientation: 1)
    for key in ["path", "left", "top", "right", "bottom"] {
      var args = cropArgs(src.path, 0, 0, 1, 1)
      args.removeValue(forKey: key)
      XCTAssertEqual(errorCode(invoke("cropPicture", args)), "bad_args", "without \(key)")
    }
    XCTAssertEqual(errorCode(invoke("cropPicture", nil)), "bad_args", "no arguments")
  }

  func testCropOfAMissingOrNonImageFileIsAnError() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".jpg")
    let text = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("not a picture".utf8).write(to: text)

    for (name, url) in [("missing", missing), ("text", text)] {
      let answer = invoke("cropPicture", cropArgs(url.path, 0, 0, 1, 1))
      XCTAssertTrue(
        ["unreadable", "not_image", "crop_failed"].contains(errorCode(answer) ?? ""),
        "\(name): answered \(String(describing: answer))")
    }
  }

  // MARK: - The picked-image copy (what pickAttachments / pickProfilePicture send)

  func testAPickedImageIsCopiedUprightWithinTheLongEdge() throws {
    let src = try makeJPEG(width: 3200, height: 800, orientation: 6)

    for (maxEdge, width, height) in [(1600, 400, 1600), (2048, 512, 2048)] {
      let out = try PickedImageProcessor.process(url: src, maxEdge: maxEdge)

      XCTAssertTrue(isInCaches(out), "\(out) is not in the caches directory")
      let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
      XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")
      let image = try decode(out)
      XCTAssertEqual(image.width, width, "maxEdge \(maxEdge)")
      XCTAssertEqual(image.height, height, "maxEdge \(maxEdge)")
      XCTAssertEqual(image.orientation, 1, "the copy still carries a rotation tag")
      let (w, h) = (image.width, image.height)
      XCTAssertEqual(image.colour(w / 4, h / 4), "blue")
      XCTAssertEqual(image.colour(w * 3 / 4, h / 4), "red")
      XCTAssertEqual(image.colour(w / 4, h * 3 / 4), "white")
      XCTAssertEqual(image.colour(w * 3 / 4, h * 3 / 4), "green")
    }
  }

  func testAPickedImageTurnedHalfwayIsCopiedUpright() throws {
    // Orientation 3: rotate 180; the stored bottom-right (white) is upright top-left.
    let src = try makeJPEG(width: 400, height: 200, orientation: 3)

    let image = try decode(try PickedImageProcessor.process(url: src, maxEdge: 1600))

    XCTAssertEqual(image.width, 400)
    XCTAssertEqual(image.height, 200)
    XCTAssertEqual(image.colour(100, 50), "white")
    XCTAssertEqual(image.colour(300, 150), "red")
  }

  func testAPickedFileThatIsNoImageIsRejected() throws {
    let text = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("not a picture".utf8).write(to: text)

    XCTAssertThrowsError(try PickedImageProcessor.process(url: text, maxEdge: 1600))
  }

  // MARK: - The pending pick

  func testASecondPickWhileOneIsOpenIsBusyAndACancelAnswersNil() throws {
    let plugin = ExternalPickerPlugin()

    for method in ["pickAttachments", "pickProfilePicture"] {
      var answer: Any? = "no answer yet"
      let answered = expectation(description: "\(method) answers")
      plugin.handle(FlutterMethodCall(methodName: method, arguments: nil)) { value in
        answer = value
        answered.fulfill()
      }
      let picker = try XCTUnwrap(waitForPicker(), "\(method) presented no PHPicker")
      XCTAssertEqual(answer as? String, "no answer yet", "\(method) answered before the user picked")

      for second in ["pickAttachments", "pickProfilePicture"] {
        XCTAssertEqual(
          errorCode(invoke(second, nil, on: plugin)), "busy", "\(second) while \(method) is open")
      }

      // The user taps Cancel: PHPicker reports no results.
      plugin.picker(picker, didFinishPicking: [])
      wait(for: [answered], timeout: 10)
      XCTAssertNil(answer, "a cancelled \(method) must answer nil")
      XCTAssertTrue(waitUntil { !(self.topViewController() is PHPickerViewController) },
                    "the picker stayed on screen after \(method) was cancelled")
    }
  }

  // MARK: - Helpers

  private func invoke(_ method: String, _ args: Any?, on plugin: ExternalPickerPlugin? = nil) -> Any? {
    let target = plugin ?? ExternalPickerPlugin()
    var answer: Any?
    let answered = expectation(description: method)
    target.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
      answer = value
      answered.fulfill()
    }
    wait(for: [answered], timeout: 20)
    return answer
  }

  private func errorCode(_ answer: Any?) -> String? {
    (answer as? FlutterError)?.code
  }

  private func cropArgs(
    _ path: String, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double
  ) -> [String: Any] {
    [
      "path": path,
      "left": NSNumber(value: left),
      "top": NSNumber(value: top),
      "right": NSNumber(value: right),
      "bottom": NSNumber(value: bottom),
      "size": NSNumber(value: Int32(64)),
      "quality": NSNumber(value: Int32(90)),
    ]
  }

  private func isInCaches(_ path: String) -> Bool {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .resolvingSymlinksInPath().path
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(caches)
  }

  private func makeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
    let ctx = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let (hw, hh) = (width / 2, height / 2)
    // CoreGraphics draws from the bottom-left; yTop counts from the top.
    func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ x: Int, _ yTop: Int, _ w: Int, _ h: Int) {
      ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
      ctx.fill(CGRect(x: x, y: height - yTop - h, width: w, height: h))
    }
    fill(1, 0, 0, 0, 0, hw, hh)
    fill(0, 1, 0, hw, 0, width - hw, hh)
    fill(0, 0, 1, 0, hh, hw, height - hh)
    fill(1, 1, 1, hw, hh, width - hw, height - hh)
    let image = try XCTUnwrap(ctx.makeImage())

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".jpg")
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
      url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, [
      kCGImagePropertyOrientation: orientation,
      kCGImageDestinationLossyCompressionQuality: 1.0,
    ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))

    // The fixture itself: stored as drawn, tagged as asked.
    let check = try decode(url.path)
    XCTAssertEqual(check.orientation, orientation, "fixture tag")
    XCTAssertEqual(check.colour(width / 4, height / 4), "red", "fixture pixels")
    return url
  }

  private struct Decoded {
    let width: Int
    let height: Int
    let orientation: Int
    let rgba: [UInt8]

    func colour(_ x: Int, _ y: Int) -> String {
      let i = (y * width + x) * 4
      let (r, g, b) = (rgba[i], rgba[i + 1], rgba[i + 2])
      switch (r > 180, g > 180, b > 180) {
      case (true, true, true): return "white"
      case (true, false, false) where g < 80 && b < 80: return "red"
      case (false, true, false) where r < 80 && b < 80: return "green"
      case (false, false, true) where r < 80 && g < 80: return "blue"
      default: return "mixed(\(r),\(g),\(b))"
      }
    }
  }

  /// The stored pixels, top row first, with no orientation applied.
  private func decode(_ path: String) throws -> Decoded {
    let source = try XCTUnwrap(
      CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), "cannot open \(path)")
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "cannot decode \(path)")
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let (w, h) = (image.width, image.height)
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buffer in
      let ctx = CGContext(
        data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return Decoded(width: w, height: h, orientation: orientation, rgba: rgba)
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }

  private func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  private func waitForPicker() -> PHPickerViewController? {
    _ = waitUntil { self.topViewController() is PHPickerViewController }
    return topViewController() as? PHPickerViewController
  }
}
