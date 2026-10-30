// Uygulama ikonunun kaynağı (seçilen: E2). Çalıştır: cd store/icon && swift icon.swift → E1/E2/E3.png
// Seçileni assets/icon.png olarak kopyala, sonra: CI=1 npx expo prebuild -p ios
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}

/// Sol üst köşe başlangıçlı, alfasız 1024'lük tuval.
func canvas(_ draw: (CGContext) -> Void) -> CGImage {
  let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.translateBy(x: 0, y: S)
  ctx.scaleBy(x: 1, y: -1)
  ctx.interpolationQuality = .high
  draw(ctx)
  return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, nil)
  CGImageDestinationFinalize(dest)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
  let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
  ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], _ locs: [CGFloat], center: CGPoint, radius: CGFloat) {
  let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
  ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Baş + omuz silueti; `box` içine ortalanmış, alttan taşar (pencere kırpar).
func person(_ ctx: CGContext, in box: CGRect, color: CGColor) {
  let w = box.width
  let headR = w * 0.20
  let headC = CGPoint(x: box.midX, y: box.minY + box.height * 0.40)
  ctx.setFillColor(color)
  ctx.fillEllipse(in: CGRect(x: headC.x - headR, y: headC.y - headR, width: headR * 2, height: headR * 2))
  let shoulderTop = headC.y + headR * 1.28
  let sw = w * 0.80
  let body = CGRect(x: box.midX - sw / 2, y: shoulderTop, width: sw, height: box.height)
  ctx.addPath(rrect(body, sw * 0.42))
  ctx.fillPath()
}

func mountains(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)], _ color: CGColor) {
  ctx.beginPath()
  ctx.move(to: CGPoint(x: -20, y: S + 20))
  for (x, y) in pts { ctx.addLine(to: CGPoint(x: x, y: y)) }
  ctx.addLine(to: CGPoint(x: S + 20, y: S + 20))
  ctx.closePath()
  ctx.setFillColor(color)
  ctx.fillPath()
}

/// Ön kamera penceresi: beyaz çerçeve + gölge + içerik.
func pipWindow(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, border: CGFloat, fill: [CGColor], personColor: CGColor) {
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 48, color: hex(0x000000, 0.45))
  ctx.addPath(rrect(r, radius))
  ctx.setFillColor(hex(0xffffff))
  ctx.fillPath()
  ctx.restoreGState()
  let inner = r.insetBy(dx: border, dy: border)
  ctx.saveGState()
  ctx.addPath(rrect(inner, radius - border))
  ctx.clip()
  linear(ctx, fill, [0, 1], from: CGPoint(x: inner.midX, y: inner.minY), to: CGPoint(x: inner.midX, y: inner.maxY))
  person(ctx, in: inner.insetBy(dx: inner.width * 0.06, dy: 0).offsetBy(dx: 0, dy: inner.height * 0.10), color: personColor)
  ctx.restoreGState()
}

func recDot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: r * 1.2, color: hex(0xff2d2d, 0.75))
  ctx.setFillColor(hex(0xff3b30))
  ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
  ctx.restoreGState()
}


/// Gün batımı sahnesi, verilen dikdörtgenin içine (arka kameranın gördüğü).
func sunsetRect(_ ctx: CGContext, _ r: CGRect) {
  linear(ctx, [hex(0x2A1A63), hex(0x8A2F8F), hex(0xF2566A), hex(0xFFB15C)], [0, 0.35, 0.68, 0.9],
         from: CGPoint(x: 0, y: r.minY), to: CGPoint(x: 0, y: r.maxY))
  let sun = CGPoint(x: r.minX + r.width * 0.34, y: r.minY + r.height * 0.66)
  radial(ctx, [hex(0xFFE08A, 0.85), hex(0xFFB15C, 0)], [0, 1], center: sun, radius: r.height * 0.5)
  let sr = r.height * 0.17
  ctx.setFillColor(hex(0xFFE7A3))
  ctx.fillEllipse(in: CGRect(x: sun.x - sr, y: sun.y - sr, width: sr * 2, height: sr * 2))
  func range(_ pts: [(CGFloat, CGFloat)], _ col: CGColor) {
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX - 10, y: r.maxY + 10))
    for (x, y) in pts { ctx.addLine(to: CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)) }
    ctx.addLine(to: CGPoint(x: r.maxX + 10, y: r.maxY + 10))
    ctx.closePath(); ctx.setFillColor(col); ctx.fillPath()
  }
  range([(-0.02, 0.74), (0.18, 0.52), (0.33, 0.66), (0.52, 0.44), (0.76, 0.68), (1.02, 0.52)], hex(0x5A2470))
  range([(-0.02, 0.88), (0.22, 0.70), (0.42, 0.84), (0.64, 0.66), (0.86, 0.86), (1.02, 0.78)], hex(0x2A1046))
}

/// Köşeleri yuvarlatılmış üçgen (video kamerasının lensi): sivri ucu gövdeye bakar.
func roundedTriangle(_ ctx: CGContext, apex: CGPoint, baseX: CGFloat, halfHeight h: CGFloat, radius: CGFloat) {
  let p1 = apex, p2 = CGPoint(x: baseX, y: apex.y - h), p3 = CGPoint(x: baseX, y: apex.y + h)
  let start = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
  ctx.beginPath()
  ctx.move(to: start)
  ctx.addArc(tangent1End: p2, tangent2End: p3, radius: radius)
  ctx.addArc(tangent1End: p3, tangent2End: p1, radius: radius)
  ctx.addArc(tangent1End: p1, tangent2End: p2, radius: radius)
  ctx.closePath()
}

/// E — video kamerası simgesi; gövdesi uygulamanın ekranı: sahne + seni gösteren pencere + kayıt.
func videoIcon(bg: (CGContext) -> Void, frame: CGColor, lens: CGColor, shadow: CGFloat) -> CGImage {
  canvas { ctx in
    bg(ctx)
    let body = CGRect(x: 84, y: 254, width: 622, height: 516)
    let border: CGFloat = 28
    // gölge + çerçeve
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 56, color: hex(0x000000, shadow))
    ctx.addPath(rrect(body, 112)); ctx.setFillColor(frame); ctx.fillPath()
    roundedTriangle(ctx, apex: CGPoint(x: 718, y: 512), baseX: 944, halfHeight: 196, radius: 44)
    ctx.setFillColor(lens); ctx.fillPath()
    ctx.restoreGState()
    // ekran: arka kameranın sahnesi
    let screen = body.insetBy(dx: border, dy: border)
    ctx.saveGState()
    ctx.addPath(rrect(screen, 112 - border)); ctx.clip()
    sunsetRect(ctx, screen)
    ctx.restoreGState()
    // ön kamera penceresi (uygulamadaki gibi sağ üstte)
    let pip = CGRect(x: screen.maxX - 36 - 196, y: screen.minY + 36, width: 196, height: 252)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: hex(0x000000, 0.35))
    ctx.addPath(rrect(pip, 40)); ctx.setFillColor(hex(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    let pin = pip.insetBy(dx: 12, dy: 12)
    ctx.saveGState()
    ctx.addPath(rrect(pin, 29)); ctx.clip()
    linear(ctx, [hex(0xFFD84A), hex(0xF5A70C)], [0, 1], from: CGPoint(x: 0, y: pin.minY), to: CGPoint(x: 0, y: pin.maxY))
    person(ctx, in: pin.insetBy(dx: 18, dy: 0).offsetBy(dx: 0, dy: 26), color: hex(0x15151A))
    ctx.restoreGState()
    // kayıt noktası
    recDot(ctx, CGPoint(x: screen.minX + 68, y: screen.minY + 68), 34)
  }
}

let dark: (CGContext) -> Void = { ctx in
  linear(ctx, [hex(0x262A4A), hex(0x0B0C16)], [0, 1], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: S))
}
let yellow: (CGContext) -> Void = { ctx in
  linear(ctx, [hex(0xFFD84A), hex(0xF7A70C)], [0, 1], from: CGPoint(x: 120, y: 0), to: CGPoint(x: S - 120, y: S))
}
let coral: (CGContext) -> Void = { ctx in
  linear(ctx, [hex(0xFF5F6D), hex(0xC2185B)], [0, 1], from: CGPoint(x: 0, y: 0), to: CGPoint(x: S * 0.4, y: S))
}
let e1 = videoIcon(bg: dark, frame: hex(0xFFFFFF), lens: hex(0xFFFFFF), shadow: 0.45)
let e2 = videoIcon(bg: yellow, frame: hex(0x15151A), lens: hex(0x15151A), shadow: 0.30)
let e3 = videoIcon(bg: coral, frame: hex(0xFFFFFF), lens: hex(0xFFFFFF), shadow: 0.30)
save(e1, "E1.png"); save(e2, "E2.png"); save(e3, "E3.png")

// Karşılaştırma sayfası: büyük önizleme + ana ekran boyutu (iOS köşe maskesiyle)
func masked(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
  ctx.saveGState()
  ctx.addPath(rrect(r, r.width * 0.2237))
  ctx.clip()
  ctx.saveGState()
  ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
  ctx.restoreGState()
  ctx.restoreGState()
}
let W = 1500, H = 760
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sheet.translateBy(x: 0, y: CGFloat(H)); sheet.scaleBy(x: 1, y: -1)
linear(sheet, [hex(0x2B3A55), hex(0x101521)], [0, 1], from: .zero, to: CGPoint(x: 0, y: CGFloat(H)))
func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false) {
  let attr = NSAttributedString(string: s, attributes: [
    .font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: NSColor.white])
  let line = CTLineCreateWithAttributedString(attr)
  let w = CTLineGetTypographicBounds(line, nil, nil, nil)
  sheet.saveGState()
  sheet.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
  sheet.textPosition = CGPoint(x: x - CGFloat(w) / 2, y: y)
  CTLineDraw(line, sheet)
  sheet.restoreGState()
}
for (i, (img, name)) in [(e1, "E1"), (e2, "E2"), (e3, "E3")].enumerated() {
  let cx = CGFloat(250 + i * 500)
  masked(sheet, img, CGRect(x: cx - 170, y: 60, width: 340, height: 340))
  label(name, cx, 450, 30, bold: true)
  // ana ekran boyutu (~60 pt, 2x ekranda 120 px) ve App Store arama boyutu
  masked(sheet, img, CGRect(x: cx - 150, y: 510, width: 120, height: 120))
  label("Çift Kamera", cx - 90, 665, 22)
  masked(sheet, img, CGRect(x: cx + 40, y: 530, width: 80, height: 80))
  label("arama", cx + 80, 665, 22)
}
save(sheet.makeImage()!, "karsilastirma.png")
