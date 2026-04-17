#!/usr/bin/env swift
// Regenerate the Mentor app icon from a 1024×1024 source PNG.
//
// Run from the repo root:
//   swift tools/generate-icon.swift [source.png]
//
// Default source: mentor-macOS-Default-1024x1024@1x.png in the repo root.
// Output: Mentor/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//         plus the surrounding Contents.json manifests.
//
// The source PNG must be at least 1024×1024 (larger is fine — it'll just
// be downscaled to 1024 for the @2x 512 slot). Non-square sources are
// centre-cropped to a square before downscaling.

import AppKit
import CoreGraphics
import Foundation

let defaultSource = "mentor-macOS-Default-1024x1024@1x.png"
let sourcePath: String = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : defaultSource

guard FileManager.default.fileExists(atPath: sourcePath) else {
    FileHandle.standardError.write(
        "Source image not found: \(sourcePath)\n".data(using: .utf8)!
    )
    exit(1)
}

struct IconSize { let name: String; let px: Int }
let sizes: [IconSize] = [
    .init(name: "icon_16x16",       px: 16),
    .init(name: "icon_16x16@2x",    px: 32),
    .init(name: "icon_32x32",       px: 32),
    .init(name: "icon_32x32@2x",    px: 64),
    .init(name: "icon_128x128",     px: 128),
    .init(name: "icon_128x128@2x",  px: 256),
    .init(name: "icon_256x256",     px: 256),
    .init(name: "icon_256x256@2x",  px: 512),
    .init(name: "icon_512x512",     px: 512),
    .init(name: "icon_512x512@2x",  px: 1024)
]

let iconset = "Mentor/Resources/Assets.xcassets/AppIcon.appiconset"
let catalog = "Mentor/Resources/Assets.xcassets"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Root-level catalog manifest (tells Xcode "this is an asset catalog").
let catalogManifest = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try catalogManifest.write(toFile: "\(catalog)/Contents.json", atomically: true, encoding: .utf8)

// ---- Load source --------------------------------------------------------

guard let sourceImage = NSImage(contentsOfFile: sourcePath),
      let sourceTIFF = sourceImage.tiffRepresentation,
      let sourceRep = NSBitmapImageRep(data: sourceTIFF) else {
    FileHandle.standardError.write("Failed to load \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}
let srcW = sourceRep.pixelsWide
let srcH = sourceRep.pixelsHigh
print("Source: \(sourcePath) (\(srcW)×\(srcH) px)")
if srcW < 1024 || srcH < 1024 {
    FileHandle.standardError.write(
        "Warning: source is smaller than 1024×1024 — the @2x 512 slot will be upscaled.\n"
            .data(using: .utf8)!
    )
}

// Centre-crop to square if needed.
let srcSide = min(srcW, srcH)
let srcOriginX = (srcW - srcSide) / 2
let srcOriginY = (srcH - srcSide) / 2
let sourceCG: CGImage = {
    guard let cg = sourceRep.cgImage else { return sourceRep.cgImage! }
    if srcW == srcH { return cg }
    let crop = CGRect(x: srcOriginX, y: srcOriginY, width: srcSide, height: srcSide)
    return cg.cropping(to: crop) ?? cg
}()

// ---- Downscale + emit ---------------------------------------------------

func downscale(source: CGImage, to px: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: px, height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let cg = ctx.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cg)
    return bitmap.representation(using: .png, properties: [:])
}

var manifestImages: [[String: Any]] = []
for entry in sizes {
    guard let png = downscale(source: sourceCG, to: entry.px) else {
        FileHandle.standardError.write("Failed to render \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(iconset)/\(entry.name).png")
    try png.write(to: url)
    print("Wrote \(url.path) (\(png.count) bytes)")

    // Derive "size" + "scale" strings for the AppIcon manifest:
    //   icon_128x128@2x → size=128x128, scale=2x
    //   icon_32x32      → size=32x32,  scale=1x
    let cleaned = entry.name.replacingOccurrences(of: "icon_", with: "")
    let components = cleaned.components(separatedBy: "@")
    manifestImages.append([
        "idiom": "mac",
        "size": components[0],
        "scale": components.count > 1 ? components[1] : "1x",
        "filename": "\(entry.name).png"
    ])
}

let manifest: [String: Any] = [
    "images": manifestImages,
    "info": ["author": "xcode", "version": 1]
]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: "\(iconset)/Contents.json"))
print("Wrote \(iconset)/Contents.json")
