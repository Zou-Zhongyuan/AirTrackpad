#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

func renderIconPNG(pixelSize: Int, roundedIcon: Bool, outputURL: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap"])
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "IconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    defer { NSGraphicsContext.restoreGraphicsState() }

    let cg = nsCtx.cgContext
    let s = CGFloat(pixelSize)
    let fullRect = CGRect(x: 0, y: 0, width: s, height: s)
    cg.clear(fullRect)

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Background plate
    let plateRect: CGRect
    if roundedIcon {
        let inset = s * 0.095
        plateRect = fullRect.insetBy(dx: inset, dy: inset)
        let cornerRadius = plateRect.width * 0.225
        let platePath = CGPath(roundedRect: plateRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        cg.saveGState()
        cg.addPath(platePath)
        cg.clip()
    } else {
        plateRect = fullRect
    }

    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.11, 0.12, 0.15, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.03, 0.035, 0.05, 1.0])!
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(
            grad,
            start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
            end: CGPoint(x: plateRect.midX, y: plateRect.minY),
            options: []
        )
    }

    // Subtle blue ambient glow
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.04, 0.52, 1.0, 0.28])!,
        CGColor(colorSpace: colorSpace, components: [0.04, 0.52, 1.0, 0.0])!
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        let center = CGPoint(x: plateRect.midX, y: plateRect.midY)
        cg.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: plateRect.width * 0.45,
            options: []
        )
    }

    if roundedIcon {
        cg.restoreGState()
        // Crisp rim border on macOS squircle
        let cornerRadius = plateRect.width * 0.225
        let borderPath = CGPath(roundedRect: plateRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        cg.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.18])!)
        cg.setLineWidth(max(1.0, s * 0.012))
        cg.addPath(borderPath)
        cg.strokePath()
    }

    // Stylized Trackpad glyph inside plate
    let padW = plateRect.width * 0.64
    let padH = plateRect.height * 0.48
    let padRect = CGRect(
        x: plateRect.midX - padW * 0.5,
        y: plateRect.midY - padH * 0.5,
        width: padW,
        height: padH
    )
    let padCorner = padW * 0.12
    let padPath = CGPath(roundedRect: padRect, cornerWidth: padCorner, cornerHeight: padCorner, transform: nil)

    cg.setFillColor(CGColor(colorSpace: colorSpace, components: [0.16, 0.18, 0.23, 0.92])!)
    cg.addPath(padPath)
    cg.fillPath()

    cg.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.85, 0.9, 1.0, 0.72])!)
    cg.setLineWidth(max(1.0, s * 0.022))
    cg.addPath(padPath)
    cg.strokePath()

    // Subtle bottom trackpad click-line accent
    let lineY = padRect.minY + padRect.height * 0.24
    cg.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.24])!)
    cg.setLineWidth(max(0.75, s * 0.014))
    cg.move(to: CGPoint(x: padRect.minX + padW * 0.12, y: lineY))
    cg.addLine(to: CGPoint(x: padRect.maxX - padW * 0.12, y: lineY))
    cg.strokePath()

    // Touch ripples / indicator dot
    let touchCenter = CGPoint(x: padRect.midX + padW * 0.08, y: padRect.midY + padH * 0.12)
    let ringR = padW * 0.16
    cg.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.2, 0.62, 1.0, 0.55])!)
    cg.setLineWidth(max(0.8, s * 0.014))
    cg.strokeEllipse(in: CGRect(x: touchCenter.x - ringR, y: touchCenter.y - ringR, width: ringR * 2, height: ringR * 2))

    let dotR = padW * 0.075
    cg.setFillColor(CGColor(colorSpace: colorSpace, components: [0.32, 0.74, 1.0, 0.96])!)
    cg.fillEllipse(in: CGRect(x: touchCenter.x - dotR, y: touchCenter.y - dotR, width: dotR * 2, height: dotR * 2))

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try pngData.write(to: outputURL)
}

let args = CommandLine.arguments
let iconsetDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "build/AppIcon.iconset", isDirectory: true)
let webDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "Web", isDirectory: true)

let fm = FileManager.default
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: webDir, withIntermediateDirectories: true)

let macSpecs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in macSpecs {
    try renderIconPNG(pixelSize: px, roundedIcon: true, outputURL: iconsetDir.appendingPathComponent(name))
}

let webSpecs: [(String, Int)] = [
    ("apple-touch-icon.png", 180),
    ("icon-192.png", 192),
    ("icon-512.png", 512)
]

for (name, px) in webSpecs {
    try renderIconPNG(pixelSize: px, roundedIcon: false, outputURL: webDir.appendingPathComponent(name))
}

print("Generated iconset at \(iconsetDir.path) and PWA icons at \(webDir.path)")
