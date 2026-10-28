import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture the fake media source serves for a Mermaid asset: three boxes joined by arrows on a transparent
/// ground, 2x of 320 x 140 points, in dark ink for the light appearance and light ink for the dark one (the server's
/// own PNGs resolve the theme the same way).
nonisolated enum FakeDiagramImage {
  static let width = 320
  static let height = 140

  static func png(dark: Bool) throws -> Data {
    let scale = 2
    let pixelWidth = width * scale
    let pixelHeight = height * scale
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let ink =
      dark
      ? CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1) : CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
    let fill =
      dark
      ? CGColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 1) : CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1)
    context.setLineWidth(1.5)
    context.setStrokeColor(ink)
    context.setFillColor(fill)
    let boxes = [
      CGRect(x: 10, y: 50, width: 80, height: 40), CGRect(x: 120, y: 50, width: 80, height: 40),
      CGRect(x: 230, y: 50, width: 80, height: 40),
    ]
    for box in boxes {
      let path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)
      context.addPath(path)
      context.drawPath(using: .fillStroke)
    }
    for index in 0..<2 {
      let start = CGPoint(x: boxes[index].maxX, y: 70)
      let end = CGPoint(x: boxes[index + 1].minX, y: 70)
      context.move(to: start)
      context.addLine(to: end)
      context.move(to: CGPoint(x: end.x - 6, y: 76))
      context.addLine(to: end)
      context.addLine(to: CGPoint(x: end.x - 6, y: 64))
      context.strokePath()
    }
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
  }
}
