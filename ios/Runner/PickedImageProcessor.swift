import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PickedImageError: Error { case notImage }

// Stateless helper; all work is file-based and synchronous, so the caller runs
// it off the main thread. iOS counterpart of PickedImageProcessor.kt.
struct PickedImageProcessor {
  // Reads the image at `url` (HEIC, JPEG, PNG... anything ImageIO decodes),
  // applies its EXIF orientation, downsamples so the long edge is at most
  // `maxEdge`, writes a JPEG into the caches dir and returns its path.
  static func process(url: URL, maxEdge: Int) throws -> String {
    let image = try decodeUpright(url: url, maxEdge: maxEdge)
    return try writeJPEG(image, quality: 0.85, prefix: "picked")
  }

  // Crops the JPEG at `sourcePath` to the rectangle given as fractions of its
  // width/height, scales that to a size x size square and writes a JPEG at
  // `quality` (0...100). Does not delete the source; the caller owns it.
  static func crop(
    sourcePath: String,
    left: Double,
    top: Double,
    right: Double,
    bottom: Double,
    size: Int,
    quality: Int
  ) throws -> String {
    let image = try decodeUpright(url: URL(fileURLWithPath: sourcePath), maxEdge: nil)
    let w = image.width
    let h = image.height
    let x = min(max(Int((left * Double(w)).rounded()), 0), w - 1)
    let y = min(max(Int((top * Double(h)).rounded()), 0), h - 1)
    let cropW = min(max(Int(((right - left) * Double(w)).rounded()), 1), w - x)
    let cropH = min(max(Int(((bottom - top) * Double(h)).rounded()), 1), h - y)
    guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: cropW, height: cropH)) else {
      throw PickedImageError.notImage
    }
    var result = cropped
    if cropW != size || cropH != size {
      guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else { throw PickedImageError.notImage }
      context.interpolationQuality = .high
      context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
      guard let scaled = context.makeImage() else { throw PickedImageError.notImage }
      result = scaled
    }
    return try writeJPEG(result, quality: Double(quality) / 100.0, prefix: "cropped")
  }

  // Decodes with the EXIF orientation applied (`WithTransform`), downsampled
  // in the decoder so a 48 MP photo is never held at full size. Never
  // upscales: the target is capped at the image's own long edge.
  private static func decodeUpright(url: URL, maxEdge: Int?) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int,
      w > 0, h > 0
    else { throw PickedImageError.notImage }
    let long = max(w, h)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(maxEdge ?? long, long),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
      throw PickedImageError.notImage
    }
    return image
  }

  private static func writeJPEG(_ image: CGImage, quality: Double, prefix: String) throws -> String {
    let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("\(prefix)_\(UUID().uuidString).jpg")
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw PickedImageError.notImage }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PickedImageError.notImage }
    return url.path
  }
}
