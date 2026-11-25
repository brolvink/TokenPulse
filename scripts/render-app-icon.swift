import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let fill = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(fill, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let tile = CGPath(roundedRect: CGRect(x: 88, y: 88, width: 848, height: 848),
                  cornerWidth: 195, cornerHeight: 195, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -21), blur: 35, color: color(0.03, 0.08, 0.12, 0.37))
context.setFillColor(color(0.08, 0.14, 0.20))
context.addPath(tile)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tile)
context.clip()
gradient([color(0.16, 0.29, 0.36), color(0.07, 0.15, 0.23), color(0.035, 0.065, 0.12)],
         from: CGPoint(x: 160, y: 910), to: CGPoint(x: 880, y: 115))
context.setLineWidth(5)
context.setStrokeColor(color(0.67, 0.86, 0.9, 0.29))
context.addPath(tile)
context.strokePath()
context.restoreGState()

let center = CGPoint(x: 512, y: 512)
let arcColors = [
    [color(1, 0.62, 0.49), color(239.0 / 255, 108.0 / 255, 73.0 / 255)],
    [color(0.65, 0.59, 1), color(102.0 / 255, 87.0 / 255, 244.0 / 255)],
    [color(0.44, 0.81, 1), color(39.0 / 255, 159.0 / 255, 230.0 / 255)],
]

for (index, colors) in arcColors.enumerated() {
    let start = CGFloat(137 - index * 120) * .pi / 180
    let end = start - 94 * .pi / 180
    let arc = CGMutablePath()
    arc.addArc(center: center, radius: 252, startAngle: start, endAngle: end, clockwise: true)

    context.saveGState()
    context.setShadow(offset: .zero, blur: 30, color: colors[0].copy(alpha: 0.36))
    context.setStrokeColor(colors[1])
    context.setLineCap(.round)
    context.setLineWidth(61)
    context.addPath(arc)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setLineCap(.round)
    context.setLineWidth(61)
    context.addPath(arc)
    context.replacePathWithStrokedPath()
    context.clip()
    let startPoint = CGPoint(x: center.x + 252 * cos(start), y: center.y + 252 * sin(start))
    let endPoint = CGPoint(x: center.x + 252 * cos(end), y: center.y + 252 * sin(end))
    gradient(colors, from: startPoint, to: endPoint)
    context.restoreGState()
}

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
