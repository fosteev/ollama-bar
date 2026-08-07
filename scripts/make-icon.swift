#!/usr/bin/env swift

// Draws the app icon into Sources/App/Resources/Assets.xcassets/AppIcon.appiconset.
//
// Code rather than a design file on purpose: the icon is a placeholder until the app goes through
// the same design pass the panel did, and a script keeps it reproducible and reviewable in a diff.
// Run: swift scripts/make-icon.swift

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

let output = URL(filePath: FileManager.default.currentDirectoryPath)
    .appending(path: "Sources/App/Resources/Assets.xcassets/AppIcon.appiconset")

// MARK: - Drawing

/// macOS icons are not masked by the system — the artwork carries its own rounded square, inset
/// from the canvas the way every other icon in the Dock is.
func draw(into context: CGContext, size: CGFloat) {
    let inset = size * 0.086
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.17, green: 0.20, blue: 0.25, alpha: 1),
            CGColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    context.restoreGState()

    // The die: the same idea as the menu bar's `cpu` glyph, so the two read as one app.
    let die = body.insetBy(dx: body.width * 0.26, dy: body.height * 0.26)
    let stroke = max(1, size * 0.028)
    let accent = CGColor(srgbRed: 0.36, green: 0.65, blue: 0.98, alpha: 1)

    context.setStrokeColor(accent)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.addPath(CGPath(
        roundedRect: die,
        cornerWidth: die.width * 0.16,
        cornerHeight: die.width * 0.16,
        transform: nil
    ))
    context.strokePath()

    // Pins. Three a side is enough to read as a chip and still survive 16 points.
    let pin = size * 0.055
    for index in 0..<3 {
        let offset = die.height * (0.25 + 0.25 * CGFloat(index))
        for x in [die.minX - pin, die.maxX] {
            context.addRect(CGRect(x: x, y: die.minY + offset - stroke / 2, width: pin, height: stroke))
        }
        let vertical = die.width * (0.25 + 0.25 * CGFloat(index))
        for y in [die.minY - pin, die.maxY] {
            context.addRect(CGRect(x: die.minX + vertical - stroke / 2, y: y, width: stroke, height: pin))
        }
    }
    context.setFillColor(accent)
    context.fillPath()

    // Three rising bars: this is a monitor, not a chip vendor's logo.
    let inner = die.insetBy(dx: die.width * 0.22, dy: die.height * 0.24)
    let barWidth = inner.width * 0.22
    let gap = (inner.width - barWidth * 3) / 2
    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1))
    for (index, share) in [0.42, 0.72, 1.0].enumerated() {
        let height = inner.height * share
        context.addPath(CGPath(
            roundedRect: CGRect(
                x: inner.minX + (barWidth + gap) * CGFloat(index),
                y: inner.minY,
                width: barWidth,
                height: height
            ),
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        ))
    }
    context.fillPath()
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
