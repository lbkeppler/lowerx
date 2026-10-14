import SwiftUI

/// Curva do equalizador: a resposta real dos filtros (a mesma conta do áudio) com um
/// ponto arrastável por banda. Arrastar chama `onChange(banda, ganho)`.
struct EqualizerGraph: View {
    let gains: [Double]
    var enabled = true
    let onChange: (Int, Double) -> Void

    private static let minFrequency = 20.0
    private static let maxFrequency = 20000.0
    /// Margem acima de ±12 dB: bandas vizinhas somadas passam um pouco do ganho pedido.
    private static let range = Equalizer.maxGain + 4
    private static let labelHeight: CGFloat = 18

    @State private var draggedBand: Int?

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: 30, y: 6, width: geo.size.width - 36, height: geo.size.height - Self.labelHeight - 10)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(in: context, plot: plot)
                    drawCurve(in: context, plot: plot)
                }
                ForEach(0..<Equalizer.frequencies.count, id: \.self) { band in
                    let point = CGPoint(x: x(Equalizer.frequencies[band], plot), y: y(gains[band], plot))
                    Circle()
                        .fill(draggedBand == band ? Theme.accent : Color.white)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(point)
                        .opacity(enabled ? 1 : 0.35)
                }
                ForEach(0..<Equalizer.frequencies.count, id: \.self) { band in
                    Text(Self.label(Equalizer.frequencies[band]))
                        .font(Theme.font(10, .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .position(x: x(Equalizer.frequencies[band], plot), y: plot.maxY + Self.labelHeight / 2 + 4)
                }
                ForEach([12.0, 6, 0, -6, -12], id: \.self) { db in
                    Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                        .font(Theme.font(9))
                        .foregroundStyle(Theme.tertiaryText)
                        .position(x: 12, y: y(db, plot))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard enabled else { return }
                    let band = draggedBand ?? nearestBand(to: drag.startLocation.x, plot)
                    draggedBand = band
                    let gain = (plot.midY - drag.location.y) / (plot.height / 2) * Self.range
                    let clamped = min(max(gain, -Equalizer.maxGain), Equalizer.maxGain)
                    onChange(band, (clamped * 2).rounded() / 2)
                }
                .onEnded { _ in draggedBand = nil })
        }
    }

    // MARK: - Desenho

    private func drawGrid(in context: GraphicsContext, plot: CGRect) {
        for db in [-12.0, -6, 0, 6, 12] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(db, plot)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(db, plot)))
            context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.16 : 0.06)), lineWidth: 1)
        }
        for f in Equalizer.frequencies {
            var line = Path()
            line.move(to: CGPoint(x: x(f, plot), y: plot.minY))
            line.addLine(to: CGPoint(x: x(f, plot), y: plot.maxY))
            context.stroke(line, with: .color(.white.opacity(0.04)), lineWidth: 1)
        }
    }

    private func drawCurve(in context: GraphicsContext, plot: CGRect) {
        let filters = Equalizer.design(gains: gains, sampleRate: 48000).filters
        var curve = Path()
        let steps = 160
        for i in 0...steps {
            let f = Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, Double(i) / Double(steps))
            let magnitude = filters.reduce(1.0) { $0 * $1.magnitude(at: f, sampleRate: 48000) }
            let point = CGPoint(x: x(f, plot), y: y(20 * log10(magnitude), plot))
            i == 0 ? curve.move(to: point) : curve.addLine(to: point)
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
        fill.closeSubpath()
        let color = enabled ? Theme.accent : Color.white.opacity(0.4)
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        context.stroke(curve, with: .color(color), lineWidth: 2)
    }

    // MARK: - Escalas

    private func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
        let t = log(frequency / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency)
        return plot.minX + CGFloat(t) * plot.width
    }

    private func y(_ db: Double, _ plot: CGRect) -> CGFloat {
        let clamped = min(max(db, -Self.range), Self.range)
        return plot.midY - CGFloat(clamped / Self.range) * plot.height / 2
    }

    private func nearestBand(to position: CGFloat, _ plot: CGRect) -> Int {
        Equalizer.frequencies.indices.min {
            abs(x(Equalizer.frequencies[$0], plot) - position) < abs(x(Equalizer.frequencies[$1], plot) - position)
        } ?? 0
    }

    static func label(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}
