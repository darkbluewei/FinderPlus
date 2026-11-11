import AppKit

// 用法: swift make_icon.swift 输出.png
// 立体感来源：渐变底 + 顶部高光 + 文件夹前后两层 + 层间投影
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let px = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

// 1. 圆角方形底（带整体投影）
let body = NSRect(x: 64, y: 72, width: 896, height: 896)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 200, yRadius: 200)
NSGraphicsContext.saveGraphicsState()
let bodyShadow = NSShadow()
bodyShadow.shadowColor = color(0, 0, 0, 0.35)
bodyShadow.shadowBlurRadius = 28
bodyShadow.shadowOffset = NSSize(width: 0, height: -14)
bodyShadow.set()
color(0.12, 0.25, 0.65).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: color(0.33, 0.62, 1.0), ending: color(0.10, 0.22, 0.62))?.draw(in: bodyPath, angle: -90)

// 2. 顶部高光和底部暗角（裁剪在圆角方形内）
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(starting: color(1, 1, 1, 0.30), ending: color(1, 1, 1, 0.0))?
    .draw(in: NSRect(x: 64, y: 520, width: 896, height: 448), angle: -90)
NSGradient(starting: color(0, 0, 0, 0.0), ending: color(0, 0, 0, 0.22))?
    .draw(in: NSRect(x: 64, y: 72, width: 896, height: 260), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 3. 文件夹后层（含标签）
let backColor = color(0.82, 0.90, 1.0, 0.95)
let tab = NSBezierPath(roundedRect: NSRect(x: 252, y: 640, width: 250, height: 96), xRadius: 34, yRadius: 34)
let back = NSBezierPath(roundedRect: NSRect(x: 252, y: 330, width: 520, height: 350), xRadius: 44, yRadius: 44)
backColor.setFill()
tab.fill()
back.fill()

// 4. 文件夹前层（带明显投影，形成层次）
let front = NSBezierPath(roundedRect: NSRect(x: 232, y: 290, width: 560, height: 310), xRadius: 46, yRadius: 46)
NSGraphicsContext.saveGraphicsState()
let frontShadow = NSShadow()
frontShadow.shadowColor = color(0.02, 0.08, 0.30, 0.45)
frontShadow.shadowBlurRadius = 26
frontShadow.shadowOffset = NSSize(width: 0, height: -16)
frontShadow.set()
color(1, 1, 1).setFill()
front.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: color(1, 1, 1), ending: color(0.74, 0.84, 1.0))?.draw(in: front, angle: -90)

// 5. 前层上沿的亮边
NSGraphicsContext.saveGraphicsState()
front.addClip()
NSGradient(starting: color(1, 1, 1, 0.9), ending: color(1, 1, 1, 0.0))?
    .draw(in: NSRect(x: 232, y: 560, width: 560, height: 40), angle: -90)
NSGraphicsContext.restoreGraphicsState()
color(1, 1, 1, 0.55).setStroke()
front.lineWidth = 3
front.stroke()

NSGraphicsContext.restoreGraphicsState()

if let data = rep.representation(using: .png, properties: [:]) {
    try? data.write(to: URL(fileURLWithPath: outPath))
}
