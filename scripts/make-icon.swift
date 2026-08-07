#!/usr/bin/env swift

// Builds Sources/App/Resources/Assets.xcassets/AppIcon.appiconset from design/icon.png.
//
// The artwork arrives full-bleed on a square canvas, which is the iOS convention. macOS does not
// mask app icons: the artwork carries its own rounded square, inset from the canvas, and an icon
// that skips this sits in the Dock as a hard square a size too big next to everything else. So the
// source stays a plain square and the platform shape is applied here, from Apple's grid — an 824 pt
// body on a 1024 pt canvas, corner radius 185.4.
//
// Run: swift scripts/make-icon.swift

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let source = root.appending(path: "design/icon.png")
let output = root.appending(path: "Sources/App/Resources/Assets.xcassets/AppIcon.appiconset")

guard let data = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(data, 0, nil)
else {
    FileHandle.standardError.write(Data("no artwork at design/icon.png\n".utf8))
    exit(1)
}

// MARK: - Drawing

/// Apple's macOS icon grid, as ratios so every size lands on the same proportions.
private let bodyInset = 100.0 / 1024
private let cornerRadius = 185.4 / 824

func draw(into context: CGContext, size: CGFloat) {
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let inset = size * bodyInset
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * cornerRadius

    context.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(artwork, in: body)
}

// MARK: - Output

func render(size: Int) throws -> Data {
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(into: context, size: CGFloat(size))
    let image = context.makeImage()!
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    return representation.representation(using: .png, properties: [:])!
}

let entries: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var written: Set<Int> = []
for size in sizes where !written.contains(size) {
    written.insert(size)
    try render(size: size).write(to: output.appending(path: "icon-\(size).png"))
}

let images = entries.map { entry in
    """
        {
          "filename" : "icon-\(entry.size * entry.scale).png",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: output.appending(path: "Contents.json"))

print("wrote \(written.count) images to \(output.path())")
