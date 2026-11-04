#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render_app_icon.swift INPUT.svg OUTPUT.png\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
guard let image = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("could not read \(inputURL.path)\n".utf8))
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let bitmapContext = CGContext(
    data: nil,
    width: 1_024,
    height: 1_024,
    bitsPerComponent: 8,
    bytesPerRow: 1_024 * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not allocate bitmap context\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(
    in: NSRect(x: 0, y: 0, width: 1_024, height: 1_024),
    from: .zero,
    operation: .copy,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let renderedImage = bitmapContext.makeImage() else {
    FileHandle.standardError.write(Data("could not create rendered image\n".utf8))
    exit(1)
}
let bitmap = NSBitmapImageRep(cgImage: renderedImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
