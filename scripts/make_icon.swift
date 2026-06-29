#!/usr/bin/swift
// X Downloader – App Icon ("Void Descent")
// Generates a 1024×1024 macOS-style icon using CoreGraphics.

import AppKit
import CoreGraphics
import CoreImage

let SIZE: CGFloat = 1024
let CORNER: CGFloat = 229          // macOS standard ≈ 22.4% of 1024
// Default output goes into the gitignored build/ dir so a stray run doesn't
// drop untracked litter in the source tree. Pass an explicit path to override.
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1]
              : "build/AppIcon.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

// ─── Colour helpers ───────────────────────────────────────────────────────────
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// ─── Rendering ────────────────────────────────────────────────────────────────
let cs   = CGColorSpaceCreateDeviceRGB()
let ctx  = CGContext(data: nil,
                     width:  Int(SIZE), height: Int(SIZE),
                     bitsPerComponent: 8, bytesPerRow: 0,
                     space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// CoreGraphics has Y=0 at the BOTTOM; flip so (0,0) is top-left like a normal image.
ctx.translateBy(x: 0, y: SIZE)
ctx.scaleBy(x: 1, y: -1)

// ── 1. Clip to rounded-square ─────────────────────────────────────────────────
let iconRect = CGRect(x: 0, y: 0, width: SIZE, height: SIZE)
let clipPath = CGPath(roundedRect: iconRect,
                      cornerWidth: CORNER, cornerHeight: CORNER,
                      transform: nil)
ctx.addPath(clipPath)
ctx.clip()

// ── 2. Background gradient (dark navy centre → near-black edges) ──────────────
let bgCentre = rgb(14, 20, 46)
let bgEdge   = rgb(6,  8,  16)
let bgColors = [bgCentre, bgEdge] as CFArray
let bgGrad   = CGGradient(colorsSpace: cs, colors: bgColors,
                           locations: [0, 1] as [CGFloat])!
ctx.drawRadialGradient(bgGrad,
                        startCenter: CGPoint(x: SIZE*0.50, y: SIZE*0.56),
                        startRadius: 0,
                        endCenter:   CGPoint(x: SIZE*0.50, y: SIZE*0.56),
                        endRadius:   SIZE * 0.72,
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ── 3. Soft blue glow at the icon centre ─────────────────────────────────────
let glowColors = [rgb(50, 90, 220, 0.13), rgb(50, 90, 220, 0)] as CFArray
let glowGrad   = CGGradient(colorsSpace: cs, colors: glowColors,
                              locations: [0, 1] as [CGFloat])!
ctx.drawRadialGradient(glowGrad,
                        startCenter: CGPoint(x: SIZE*0.50, y: SIZE*0.56),
                        startRadius: 0,
                        endCenter:   CGPoint(x: SIZE*0.50, y: SIZE*0.56),
                        endRadius:   SIZE * 0.52,
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ── 4. Draw the X mark ────────────────────────────────────────────────────────
// Two thick diagonal bars; X centre slightly above mid to give arrow room below.
let xcx: CGFloat = SIZE * 0.50
let xcy: CGFloat = SIZE * 0.40          // nudge X up slightly
let armLen: CGFloat = SIZE * 0.580
let armW:   CGFloat = SIZE * 0.112

func barPath(cx: CGFloat, cy: CGFloat,
             length: CGFloat, width: CGFloat,
             angleDeg: CGFloat) -> CGPath {
    let a = angleDeg * .pi / 180
    let path = CGMutablePath()
    // rectangle corners before rotation
    let hw = width  / 2
    let hl = length / 2
    let corners: [(CGFloat, CGFloat)] = [(-hl, -hw), (hl, -hw), (hl, hw), (-hl, hw)]
    let pts = corners.map { (px, py) -> CGPoint in
        CGPoint(x: cx + px * cos(a) - py * sin(a),
                y: cy + px * sin(a) + py * cos(a))
    }
    path.move(to: pts[0])
    pts[1...].forEach { path.addLine(to: $0) }
    path.closeSubpath()
    return path
}

// Draw X glow first (soft white halo)
ctx.saveGState()
ctx.setBlendMode(.normal)
for angle in [-42.0, 42.0] as [CGFloat] {
    ctx.addPath(barPath(cx: xcx, cy: xcy, length: armLen + 12,
                         width: armW + 24, angleDeg: angle))
}
ctx.setShadow(offset: .zero, blur: 18,
              color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0))
ctx.fillPath()
ctx.restoreGState()

// Draw the two X bars
ctx.saveGState()
for angle in [-42.0, 42.0] as [CGFloat] {
    ctx.addPath(barPath(cx: xcx, cy: xcy, length: armLen,
                         width: armW, angleDeg: angle))
}
ctx.setFillColor(rgb(255, 255, 255, 0.92))
ctx.fillPath()
ctx.restoreGState()

// ── 5. Download arrow ─────────────────────────────────────────────────────────
let ax: CGFloat  = SIZE * 0.50
let ay: CGFloat  = SIZE * 0.625          // arrow vertical anchor (slightly lower)

let shaftW: CGFloat = SIZE * 0.076
let shaftH: CGFloat = SIZE * 0.195
let headW:  CGFloat = SIZE * 0.235
let headH:  CGFloat = SIZE * 0.115
let barW:   CGFloat = SIZE * 0.250
let barH:   CGFloat = SIZE * 0.040
let barGap: CGFloat = SIZE * 0.012

let shaftTop:    CGFloat = ay - shaftH / 2
let shaftBottom: CGFloat = ay + shaftH / 2
let tipY:        CGFloat = shaftBottom + headH
let landTop:     CGFloat = tipY + barGap
let landBottom:  CGFloat = landTop + barH

// Build arrow path in one shape
let arrowPath = CGMutablePath()

// Shaft (rounded rectangle approximated as rect with arc caps)
let shaftRect = CGRect(x: ax - shaftW/2, y: shaftTop, width: shaftW, height: shaftH)
arrowPath.addRoundedRect(in: shaftRect, cornerWidth: shaftW/2, cornerHeight: shaftW/2)

// Arrowhead triangle
arrowPath.move(to: CGPoint(x: ax - headW/2, y: shaftBottom))
arrowPath.addLine(to: CGPoint(x: ax + headW/2, y: shaftBottom))
arrowPath.addLine(to: CGPoint(x: ax,           y: tipY))
arrowPath.closeSubpath()

// Landing bar
let landRect = CGRect(x: ax - barW/2, y: landTop, width: barW, height: barH)
arrowPath.addRoundedRect(in: landRect, cornerWidth: barH/2, cornerHeight: barH/2)

// Arrow blue glow
ctx.saveGState()
ctx.addPath(arrowPath)
ctx.setShadow(offset: .zero, blur: 28, color: rgb(80, 130, 255, 0.55))
ctx.setFillColor(rgb(255, 255, 255, 0))   // transparent fill; shadow does the work
ctx.fillPath()
ctx.restoreGState()

// Arrow fill — vivid sky-blue so it reads apart from the pure-white X
ctx.saveGState()
ctx.addPath(arrowPath)
ctx.setFillColor(rgb(100, 170, 255, 1.0))
ctx.fillPath()
ctx.restoreGState()

// Bright outer glow — electric halo
ctx.saveGState()
ctx.addPath(arrowPath)
ctx.setShadow(offset: .zero, blur: 44, color: rgb(80, 140, 255, 0.80))
ctx.setFillColor(rgb(100, 170, 255, 0))
ctx.fillPath()
ctx.restoreGState()

// Inner highlight on shaft top — white gleam for depth
let highlightRect = CGRect(x: ax - shaftW/2 + 4,
                            y: shaftTop + 4,
                            width: shaftW - 8,
                            height: shaftH * 0.32)
ctx.saveGState()
let hlPath = CGPath(roundedRect: highlightRect,
                    cornerWidth: (shaftW-8)/2, cornerHeight: (shaftW-8)/2,
                    transform: nil)
ctx.addPath(hlPath)
ctx.setFillColor(rgb(255, 255, 255, 0.35))
ctx.fillPath()
ctx.restoreGState()

// ── 6. Specular highlight (top-left shimmer — depth cue) ──────────────────────
let specColors = [rgb(255,255,255, 0.09), rgb(255,255,255, 0)] as CFArray
let specGrad   = CGGradient(colorsSpace: cs, colors: specColors,
                              locations: [0, 1] as [CGFloat])!
ctx.drawRadialGradient(specGrad,
                        startCenter: CGPoint(x: SIZE*0.30, y: SIZE*0.22),
                        startRadius: 0,
                        endCenter:   CGPoint(x: SIZE*0.30, y: SIZE*0.22),
                        endRadius:   SIZE * 0.40,
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ── 7. Inner-edge vignette (makes the rounded rect feel 3-D) ─────────────────
for i in 0 ..< 28 {
    let t     = CGFloat(i) / 27
    let alpha = 0.22 * pow(1 - t, 2.2)
    let inset = CGFloat(i)
    let r     = max(1, CORNER - inset)
    let ring  = CGPath(roundedRect: iconRect.insetBy(dx: inset, dy: inset),
                        cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(ring)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
    ctx.setLineWidth(1.2)
    ctx.strokePath()
}

// ── 8. Save PNG ───────────────────────────────────────────────────────────────
let cgImage = ctx.makeImage()!
let rep     = NSBitmapImageRep(cgImage: cgImage)
let png     = rep.representation(using: .png, properties: [:])!

try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                          withIntermediateDirectories: true)
try! png.write(to: out)
print("✅  Icon saved → \(out.path)")
print("   Size: \(cgImage.width)×\(cgImage.height) px")
