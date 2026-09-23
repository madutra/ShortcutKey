// Gera o ícone do app (um Daruma original com uma tecla ⌘ na barriga).
// Uso: swift scripts/make-icon.swift   →   Resources/AppIcon.icns
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

func draw(in ctx: CGContext) {
    // Fundo: "squircle" no grid de ícones do macOS (824 px com margem de 100).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1B2340))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x2C3A66), color(0x121831)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Brilho suave atrás do Daruma.
    ctx.drawRadialGradient(gradient([color(0xFFB36B, 0.35), color(0xFFB36B, 0)]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])

    // Sombra no "chão".
    ctx.setFillColor(color(0x000000, 0.35))
    ctx.fillEllipse(in: CGRect(x: 300, y: 175, width: 424, height: 60))

    // Corpo: formato de ovo, mais largo embaixo.
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 512, y: 200))
    body.addCurve(to: CGPoint(x: 782, y: 460), control1: CGPoint(x: 690, y: 200), control2: CGPoint(x: 782, y: 300))
    body.addCurve(to: CGPoint(x: 512, y: 840), control1: CGPoint(x: 782, y: 660), control2: CGPoint(x: 680, y: 840))
    body.addCurve(to: CGPoint(x: 242, y: 460), control1: CGPoint(x: 344, y: 840), control2: CGPoint(x: 242, y: 660))
    body.addCurve(to: CGPoint(x: 512, y: 200), control1: CGPoint(x: 242, y: 300), control2: CGPoint(x: 334, y: 200))
    body.closeSubpath()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xF2553C), color(0xD1301F), color(0x9E1B14)]),
                           start: CGPoint(x: 380, y: 840), end: CGPoint(x: 650, y: 200), options: [])
    // Reflexo de verniz no alto da cabeça.
    ctx.setFillColor(color(0xFFFFFF, 0.18))
    ctx.fillEllipse(in: CGRect(x: 330, y: 700, width: 170, height: 100))
    ctx.restoreGState()

    // Rosto: área clara com borda dourada.
    let face = CGPath(ellipseIn: CGRect(x: 342, y: 480, width: 340, height: 250), transform: nil)
    ctx.addPath(face)
    ctx.setFillColor(color(0xFFF6E8))
    ctx.fillPath()
    ctx.addPath(face)
    ctx.setStrokeColor(color(0xF2C14E))
    ctx.setLineWidth(10)
    ctx.strokePath()

    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x1A1A1A))

    // Sobrancelhas.
    ctx.setLineWidth(18)
    for side: CGFloat in [-1, 1] {
        ctx.move(to: CGPoint(x: 512 + side * 30, y: 668))
        ctx.addQuadCurve(to: CGPoint(x: 512 + side * 118, y: 676), control: CGPoint(x: 512 + side * 76, y: 706))
        ctx.strokePath()
    }

    // Olhos: um pintado (a meta cumprida), outro em branco — como manda a tradição.
    for (side, painted) in [(CGFloat(-1), true), (CGFloat(1), false)] {
        let center = CGPoint(x: 512 + side * 72, y: 612)
        let eye = CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: eye)
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: eye)
        if painted {
            ctx.setFillColor(color(0x1A1A1A))
            ctx.fillEllipse(in: CGRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50))
        }
    }

    // Bigode.
    ctx.setLineWidth(14)
    for side: CGFloat in [-1, 1] {
        ctx.move(to: CGPoint(x: 512 + side * 10, y: 548))
        ctx.addQuadCurve(to: CGPoint(x: 512 + side * 100, y: 536), control: CGPoint(x: 512 + side * 60, y: 520))
        ctx.strokePath()
    }
    // Barba: três traços curtos.
    ctx.setLineWidth(10)
    for dx: CGFloat in [-44, 0, 44] {
        ctx.move(to: CGPoint(x: 512 + dx, y: 512))
        ctx.addLine(to: CGPoint(x: 512 + dx * 1.15, y: 492))
        ctx.strokePath()
    }

    // Barriga: uma tecla dourada com ⌘.
    let key = CGRect(x: 432, y: 290, width: 160, height: 140)
    let keyPath = CGPath(roundedRect: key, cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 0, color: color(0x8A5A10))
    ctx.addPath(keyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFE08A), color(0xF2B83A)]),
                           start: CGPoint(x: 512, y: key.maxY), end: CGPoint(x: 512, y: key.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(keyPath)
    ctx.setStrokeColor(color(0xB9811C))
    ctx.setLineWidth(6)
    ctx.strokePath()

    let glyph = NSAttributedString(string: "⌘", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .bold),
        .foregroundColor: NSColor(cgColor: color(0x7A1A10))!,
    ])
    let glyphSize = glyph.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    glyph.draw(at: CGPoint(x: key.midX - glyphSize.width / 2, y: key.midY - glyphSize.height / 2 + 2))
    NSGraphicsContext.restoreGraphicsState()

    ctx.restoreGState()
}

/// Versão monocromática para a barra de menu (o macOS pinta de preto/branco conforme o tema).
func drawTemplate(in ctx: CGContext) {
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 512, y: 200))
    body.addCurve(to: CGPoint(x: 782, y: 460), control1: CGPoint(x: 690, y: 200), control2: CGPoint(x: 782, y: 300))
    body.addCurve(to: CGPoint(x: 512, y: 840), control1: CGPoint(x: 782, y: 660), control2: CGPoint(x: 680, y: 840))
    body.addCurve(to: CGPoint(x: 242, y: 460), control1: CGPoint(x: 344, y: 840), control2: CGPoint(x: 242, y: 660))
    body.addCurve(to: CGPoint(x: 512, y: 200), control1: CGPoint(x: 242, y: 300), control2: CGPoint(x: 334, y: 200))
    body.closeSubpath()

    ctx.setFillColor(color(0x000000))
    ctx.addPath(body)
    ctx.fillPath()
    // Recorta o rosto e depois desenha os olhos dentro dele.
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: 330, y: 470, width: 364, height: 270))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 447, y: 285, width: 130, height: 115), cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.fillPath()
    ctx.setBlendMode(.normal)
    ctx.fillEllipse(in: CGRect(x: 400, y: 565, width: 90, height: 90))
    ctx.setLineWidth(26)
    ctx.setStrokeColor(color(0x000000))
    ctx.strokeEllipse(in: CGRect(x: 547, y: 578, width: 64, height: 64))
}

func templatePNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(size) / 660
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -182, y: -190)
    drawTemplate(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
try templatePNG(size: 18).write(to: root.appendingPathComponent("Resources/MenuBarIcon.png"))
try templatePNG(size: 36).write(to: root.appendingPathComponent("Resources/MenuBarIcon@2x.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Ícone gerado em Resources/AppIcon.icns" : "Falha no iconutil")
