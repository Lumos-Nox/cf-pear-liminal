// Bake the continuous corners into transparent pixels. Launch storyboards and
// the timed opening screen use these exact same raster assets, with no mask
// applied later at runtime. Usage: swift ios/Tools/generate-launch-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("PearLiminal/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let directory = root.appendingPathComponent("PearLiminal/Assets.xcassets/LaunchIconRounded.imageset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Could not read the app icon")
}
for scale in 1...3 {
    let pixels = 64 * scale
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create the launch icon bitmap")
    }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
    context.addPath(RoundedRectangle(cornerRadius: 14.4, style: .continuous).path(in: bounds).cgPath)
    context.clip()
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    let output = directory.appendingPathComponent("LaunchIconRounded@\(scale)x.png")
    guard let bitmap = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not write the launch icon")
    }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not save the launch icon") }
}
let catalog: [String: Any] = [
    "images": (1...3).map { ["filename": "LaunchIconRounded@\($0)x.png", "idiom": "universal", "scale": "\($0)x"] },
    "info": ["author": "xcode", "version": 1],
]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("Contents.json"))
