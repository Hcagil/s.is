import Foundation
import UIKit
import Vision

enum StickerCutout {
  static let side = 512
  
  // True when the phone can lift a subject: iOS 17+ (VNGenerateForegroundInstanceMaskRequest is iOS 17 only; the project's deployment target is iOS 15, so everything touching Vision is behind #available).
  static var supported: Bool {
    if #available(iOS 17.0, *) { return true }
    return false
  }
  
  // Decodes [jpeg] (UIImage(data:); nil -> return nil), redraws it to exactly side x side at scale 1 (UIGraphicsImageRenderer with UIGraphicsImageRendererFormat, format.scale = 1), runs Vision subject lifting and returns side*side bytes (row-major, one byte per pixel, 0..255) or nil on ANY failure / no subject / not supported. Synchronous and heavy: the caller runs it on a background queue.
  static func mask(jpeg: Data) -> Data? {
    guard #available(iOS 17.0, *) else { return nil }
    
    guard let uiImage = UIImage(data: jpeg) else { return nil }
    
    // Redraw to exactly side x side at scale 1
    let rendererFormat = UIGraphicsImageRendererFormat()
    rendererFormat.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: rendererFormat)
    let renderedImage = renderer.image { _ in
      uiImage.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    
    guard let cgImage = renderedImage.cgImage else { return nil }
    
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    
    do {
      try handler.perform([request])
    } catch {
      return nil
    }
    
    guard let observation = request.results?.first else { return nil }
    
    let all = observation.allInstances
    guard !all.isEmpty else { return nil }
    
    do {
      let buffer: CVPixelBuffer = try observation.generateScaledMaskForImage(forInstances: all, from: handler)
      
      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      
      if width != side || height != side {
        return nil
      }
      
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      
      guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
      
      let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
      
      let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
      
      var maskData = [UInt8](repeating: 0, count: side * side)
      var hasSubject = false
      
      switch pixelFormat {
      case kCVPixelFormatType_OneComponent32Float:
        let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
        for y in 0..<side {
          for x in 0..<side {
            let index = y * bytesPerRow / MemoryLayout<Float>.size + x
            let value = floatPtr[index]
            let byteValue = Int((value * 255).rounded())
            let clamped = max(0, min(255, byteValue))
            maskData[y * side + x] = UInt8(clamped)
            if clamped > 25 {
              hasSubject = true
            }
          }
        }
      
      case kCVPixelFormatType_OneComponent8:
        let uint8Ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
          for x in 0..<side {
            let index = y * bytesPerRow + x
            let byteValue = uint8Ptr[index]
            maskData[y * side + x] = byteValue
            if byteValue > 25 {
              hasSubject = true
            }
          }
        }
      
      default:
        return nil
      }
      
      if !hasSubject {
        return nil
      }
      
      return Data(maskData)
    } catch {
      return nil
    }
  }
}
