// Gera o ícone do LowerX: monograma "LX" na fonte Saira Black, X em vermelho,
// sobre fundo escuro com brilho vermelho vindo de baixo.
// Uso: make_icon <Saira-Black.ttf> <saída.iconset>
import AppKit
import CoreText

let args = CommandLine.arguments
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: args[1]) as CFURL, .process, nil)
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let red = NSColor(red: 0.89, green: 0.10, blue: 0.20, alpha: 1)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Grade de ícones do macOS: conteúdo em ~80% com cantos arredondados.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
                        NSColor(red: 0.035, green: 0.035, blue: 0.045, alpha: 1)])!.draw(in: rect, angle: -90)
    // Brilho vermelho embaixo: o "lower".
    let glowCenter = NSPoint(x: rect.midX, y: rect.minY - rect.height * 0.12)
    NSGradient(colors: [red.withAlphaComponent(0.55), red.withAlphaComponent(0)])!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: rect.width * 0.75, options: [])

    let font = NSFont(name: "Saira-Black", size: rect.height * 0.46)!
    let text = NSMutableAttributedString(string: "LX", attributes: [.font: font, .foregroundColor: NSColor.white,
                                                                   .kern: -rect.height * 0.01])
    text.addAttribute(.foregroundColor, value: red, range: NSRange(location: 1, length: 1))
    let bounds = text.boundingRect(with: NSSize(width: s, height: s), options: [.usesLineFragmentOrigin])
    let origin = NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2 + rect.height * 0.01)
    text.draw(at: origin)
    // Traço vermelho sob o monograma, como o detalhe da barra lateral do app.
    let baseline = origin.y - font.descender
    let bar = NSRect(x: rect.midX - rect.width * 0.2, y: baseline - rect.height * 0.085,
                     width: rect.width * 0.4, height: rect.height * 0.035)
    red.setFill()
    NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.08).setStroke()
    shape.lineWidth = max(1, s / 512)
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
