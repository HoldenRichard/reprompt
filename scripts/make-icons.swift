// Renders the Reprompt mark — the sharpening caret — into every asset the app needs.
// Run: swift scripts/make-icons.swift
//
// The mark is defined once in a 100x100 space and drawn with CoreGraphics, so each size is
// rendered at its own resolution rather than downsampled from one bitmap. That matters at
// 16 and 18 points, where a downsample turns the caret to mush.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The mark

/// Two ragged lines of text resolving into one crisp cursor.
struct Mark {
    struct Bar { var x, y, w, h: CGFloat }

    static let textBars: [Bar] = [
        Bar(x: 14, y: 30, w: 40, h: 13),
        Bar(x: 26, y: 54, w: 28, h: 13),
    ]
    static let caret = Bar(x: 68, y: 16, w: 15, h: 68)
    /// Clarify mode: the caret is broken, so something is still to be filled in.
    static let caretGap: (from: CGFloat, to: CGFloat) = (45, 59)

    /// Drawn bounds in the 100-space, used to centre the mark in any canvas.
    static let bounds = CGRect(x: 14, y: 16, width: 69, height: 68)

    static func path(broken: Bool) -> CGPath {
        let p = CGMutablePath()
        func add(_ b: Bar) {
            let r = CGRect(x: b.x, y: 100 - b.y - b.h, width: b.w, height: b.h)  // flip to CG's origin
            p.addPath(CGPath(roundedRect: r, cornerWidth: b.h / 2, cornerHeight: b.h / 2, transform: nil))
        }
        for bar in textBars { add(bar) }
        if broken {
            add(Bar(x: caret.x, y: caret.y, w: caret.w, h: caretGap.from - caret.y))
            add(Bar(x: caret.x, y: caretGap.to, w: caret.w, h: caret.y + caret.h - caretGap.to))
        } else {
            add(caret)
        }
        return p
    }
}

// MARK: - Palette

let clayTop = CGColor(srgbRed: 0.906, green: 0.627, blue: 0.471, alpha: 1)   // #E7A078
let clayBottom = CGColor(srgbRed: 0.706, green: 0.306, blue: 0.173, alpha: 1) // #B44E2C
let cream = CGColor(srgbRed: 0.969, green: 0.953, blue: 0.933, alpha: 1)      // #F7F3EE

// MARK: - Rendering

func context(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// Maps the 100-space mark into `rect`, preserving aspect and centring on the drawn bounds.
func markTransform(into rect: CGRect) -> CGAffineTransform {
    let b = CGRect(x: Mark.bounds.minX, y: 100 - Mark.bounds.maxY,
                   width: Mark.bounds.width, height: Mark.bounds.height)
    let scale = min(rect.width / b.width, rect.height / b.height)
    return CGAffineTransform(translationX: rect.midX - (b.midX * scale), y: rect.midY - (b.midY * scale))
        .scaledBy(x: scale, y: scale)
}

func fillGradient(_ ctx: CGContext, in rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [clayTop, clayBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

func write(_ ctx: CGContext, to url: URL) {
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// A menubar template: opaque black on transparency. macOS inverts it for dark menubars.
func renderTemplate(size: Int, broken: Bool, to url: URL) {
    let ctx = context(size)
    let inset = CGFloat(size) * 0.055   // a little breathing room, as Apple's own glyphs have
    let box = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
    var t = markTransform(into: box)
    ctx.addPath(Mark.path(broken: broken).copy(using: &t)!)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    write(ctx, to: url)
}

/// The app icon: a cream rounded square with the mark in clay, on Apple's 824/1024 grid.
func renderAppIcon(size: Int, to url: URL) {
    let ctx = context(size)
    let s = CGFloat(size)
    let plateInset = s * (100.0 / 1024.0)
    let plate = CGRect(x: plateInset, y: plateInset, width: s - plateInset * 2, height: s - plateInset * 2)
    let radius = s * (185.0 / 1024.0)

    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(cream)
    ctx.fillPath()

    let markBox = plate.insetBy(dx: plate.width * 0.21, dy: plate.height * 0.21)
    var t = markTransform(into: markBox)
    ctx.saveGState()
    ctx.addPath(Mark.path(broken: false).copy(using: &t)!)
    ctx.clip()
    fillGradient(ctx, in: markBox)
    ctx.restoreGState()
    write(ctx, to: url)
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/Reprompt/Resources")
let assets = root.appendingPathComponent("assets")
let iconset = assets.appendingPathComponent("Reprompt.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Menubar templates at 2x; the app declares an 18pt size so they stay crisp on Retina.
renderTemplate(size: 36, broken: false, to: resources.appendingPathComponent("menubar_quick.png"))
renderTemplate(size: 36, broken: true, to: resources.appendingPathComponent("menubar_clarify.png"))

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    renderAppIcon(size: px, to: iconset.appendingPathComponent("\(name).png"))
}
renderAppIcon(size: 512, to: assets.appendingPathComponent("preview-appicon.png"))
renderTemplate(size: 144, broken: false, to: assets.appendingPathComponent("preview-menubar-quick.png"))
renderTemplate(size: 144, broken: true, to: assets.appendingPathComponent("preview-menubar-clarify.png"))
print("rendered menubar templates and \(10) icon sizes")
