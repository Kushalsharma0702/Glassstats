import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Supply an output PNG path")
}

let canvas = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: canvas * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let face = CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                  cornerWidth: 190, cornerHeight: 190, transform: nil)
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -13), blur: 36, color: color(0.1, 0.04, 0.24, 0.48))
context.addPath(face)
context.setFillColor(color(0.14, 0.06, 0.32))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(face)
context.clip()
context.drawLinearGradient(gradient([color(0.49, 0.32, 0.83), color(0.27, 0.13, 0.55), color(0.09, 0.06, 0.24)]),
                           start: CGPoint(x: 130, y: 900), end: CGPoint(x: 865, y: 100), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
context.drawRadialGradient(gradient([color(0.73, 0.67, 1, 0.65), color(0.68, 0.47, 1, 0)]),
                           startCenter: CGPoint(x: 280, y: 890), startRadius: 40,
                           endCenter: CGPoint(x: 280, y: 890), endRadius: 600, options: [.drawsBeforeStartLocation])
for inset in [0.0, 11.0, 31.0] {
    let ring = CGPath(roundedRect: CGRect(x: 94 + inset, y: 94 + inset, width: 836 - 2 * inset, height: 836 - 2 * inset),
                      cornerWidth: 188 - inset, cornerHeight: 188 - inset, transform: nil)
    context.addPath(ring)
    context.setLineWidth(inset == 0 ? 8 : 3)
    context.setStrokeColor(color(0.87, 0.80, 1, inset == 0 ? 0.70 : 0.23))
    context.strokePath()
}
let wave = CGMutablePath()
wave.move(to: CGPoint(x: 216, y: 498))
wave.addLine(to: CGPoint(x: 340, y: 498))
wave.addLine(to: CGPoint(x: 416, y: 646))
wave.addLine(to: CGPoint(x: 505, y: 333))
wave.addLine(to: CGPoint(x: 602, y: 698))
wave.addLine(to: CGPoint(x: 681, y: 498))
wave.addLine(to: CGPoint(x: 808, y: 498))
context.setLineJoin(.round)
context.setLineCap(.round)
context.setLineWidth(48)
context.setShadow(offset: .zero, blur: 35, color: color(0.42, 0.92, 1, 0.58))
context.setStrokeColor(color(0.82, 0.97, 1))
context.addPath(wave)
context.strokePath()
context.restoreGState()

let image = context.makeImage()!
let pixels = NSBitmapImageRep(cgImage: image)
try pixels.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
