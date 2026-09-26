#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let canvas: CGFloat = 1024

private struct IconSlot {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var filename: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    }
}

private let slots = [
    IconSlot(points: 16, scale: 1),
    IconSlot(points: 16, scale: 2),
    IconSlot(points: 32, scale: 1),
    IconSlot(points: 32, scale: 2),
    IconSlot(points: 128, scale: 1),
    IconSlot(points: 128, scale: 2),
    IconSlot(points: 256, scale: 1),
    IconSlot(points: 256, scale: 2),
    IconSlot(points: 512, scale: 1),
    IconSlot(points: 512, scale: 2)
]

private let scriptURL = URL(fileURLWithPath: #filePath)
private let repositoryURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let outputURL = repositoryURL
    .appendingPathComponent("AppleIntelligenceSummarizer/Assets.xcassets/AppIcon.appiconset")

private func roundedLine(
    in context: CGContext,
    from start: CGPoint,
    to end: CGPoint,
    width: CGFloat,
    color: CGColor
) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.move(to: start)
    context.addLine(to: end)
    context.strokePath()
}

private func sparklePath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = 16
    for index in 0..<points {
        let angle = CGFloat(index) * .pi / 8 - .pi / 2
        let radius = index.isMultiple(of: 2) ? outer : inner
        let point = CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
        index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

private func drawIcon(in context: CGContext) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let backgroundColors = [
        NSColor(calibratedRed: 0.34, green: 0.23, blue: 0.96, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.45, blue: 0.91, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.69, blue: 0.68, alpha: 1).cgColor
    ] as CFArray
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: backgroundColors,
        locations: [0, 0.56, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 70, y: 960),
        end: CGPoint(x: 950, y: 40),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Subtle depth that remains legible behind the document surface.
    context.setFillColor(NSColor.white.withAlphaComponent(0.055).cgColor)
    context.fillEllipse(in: CGRect(x: 540, y: 520, width: 620, height: 620))
    context.setFillColor(NSColor.black.withAlphaComponent(0.05).cgColor)
    context.fillEllipse(in: CGRect(x: -260, y: -250, width: 780, height: 780))

    let card = CGPath(
        roundedRect: CGRect(x: 165, y: 155, width: 694, height: 714),
        cornerWidth: 150,
        cornerHeight: 150,
        transform: nil
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -24),
        blur: 45,
        color: NSColor.black.withAlphaComponent(0.24).cgColor
    )
    context.setFillColor(NSColor.white.withAlphaComponent(0.17).cgColor)
    context.addPath(card)
    context.fillPath()
    context.restoreGState()

    context.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
    context.setLineWidth(3)
    context.addPath(card)
    context.strokePath()

    let white = NSColor.white.withAlphaComponent(0.94).cgColor
    let softWhite = NSColor.white.withAlphaComponent(0.68).cgColor

    // Three source lines become progressively shorter.
    roundedLine(
        in: context,
        from: CGPoint(x: 285, y: 666),
        to: CGPoint(x: 665, y: 666),
        width: 50,
        color: white
    )
    roundedLine(
        in: context,
        from: CGPoint(x: 285, y: 564),
        to: CGPoint(x: 597, y: 564),
        width: 50,
        color: softWhite
    )
    roundedLine(
        in: context,
        from: CGPoint(x: 285, y: 462),
        to: CGPoint(x: 510, y: 462),
        width: 50,
        color: softWhite
    )

    // A single highlighted result line represents the concise summary.
    let summaryRect = CGRect(x: 255, y: 270, width: 514, height: 102)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 24,
        color: NSColor(calibratedRed: 0.01, green: 0.25, blue: 0.34, alpha: 0.3).cgColor
    )
    context.setFillColor(
        NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.82, alpha: 1).cgColor
    )
    context.fillEllipse(in: summaryRect)
    context.restoreGState()

    roundedLine(
        in: context,
        from: CGPoint(x: 327, y: 321),
        to: CGPoint(x: 697, y: 321),
        width: 27,
        color: NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.43, alpha: 0.72).cgColor
    )

    // Original eight-point sparkle; this is drawn geometry, not an SF Symbol.
    let sparkle = sparklePath(center: CGPoint(x: 739, y: 711), outer: 84, inner: 29)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -8),
        blur: 20,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    context.setFillColor(NSColor(calibratedRed: 1, green: 0.86, blue: 0.35, alpha: 1).cgColor)
    context.addPath(sparkle)
    context.fillPath()
    context.restoreGState()
}

private func render(slot: IconSlot) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: slot.pixels,
        pixelsHigh: slot.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    let scale = CGFloat(slot.pixels) / canvas
    graphicsContext.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(in: graphicsContext.cgContext)
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputURL.appendingPathComponent(slot.filename), options: .atomic)
}

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
for slot in slots {
    try render(slot: slot)
}

print("Generated \(slots.count) app icon images in \(outputURL.path)")
