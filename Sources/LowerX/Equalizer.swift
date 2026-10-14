import Foundation

/// Equalizador gráfico de 10 bandas, igual ao do NGENUITY para o Stinger 2
/// (`HeadsetCloudStinger2Wireless.ApplyEQBands`). No Windows ele roda no DTS APO;
/// aqui roda no `SystemAudioEQ`.
enum Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// O NGENUITY guarda o ganho normalizado em −1…+1; a escala em dB fica dentro da
    /// DLL da DTS. ±12 dB é a faixa usual de EQ gráfico e a que usamos aqui.
    static let maxGain = 12.0
    /// Bandas um pouco mais estreitas que uma oitava (Q 1,41): com bandas vizinhas
    /// somando, Q 2 deixa a curva mais perto dos ganhos pedidos.
    static let q = 2.0

    static var flat: [Double] { Array(repeating: 0, count: frequencies.count) }

    /// Presets de fábrica do Stinger 2 (`HeadsetPreset.GetDefaultStinger2WirelessEqualizers`).
    enum Preset: String, CaseIterable, Identifiable {
        case bassBoost, bassCut, trebleBoost, trebleCut, voiceChat, gaming, balanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bassBoost: return "Mais graves"
            case .bassCut: return "Menos graves"
            case .trebleBoost: return "Mais agudos"
            case .trebleCut: return "Menos agudos"
            case .voiceChat: return "Voz"
            case .gaming: return "Jogos"
            case .balanced: return "Equilibrado"
            }
        }

        /// Ganhos em dB por banda.
        var gains: [Double] { normalized.map { $0 * Equalizer.maxGain } }

        private var normalized: [Double] {
            switch self {
            case .bassBoost: return [0.4064721, 0.4064721, 0.1743361, 0, 0, 0, 0, 0, 0, 0]
            case .bassCut: return [-0.3806452, -0.3806452, -0.1611887, 0, 0, 0, 0, 0, 0, 0]
            case .trebleBoost: return [0, 0, 0, 0, 0, 0, 0.1875031, 0.4581661, 0.4713332, 0.2260301]
            case .trebleCut: return [0, 0, 0, 0, 0, 0, -0.2128827, -0.4835457, -0.4835457, -0.2514097]
            case .voiceChat:
                return [-0.8449172, -0.4450187, -0.1094947, 0.3937925, 0.7161495,
                        1, 0.5615541, 0.1358091, -0.7415291, -0.8834441]
            case .gaming:
                return [0.1097381, -0.1480217, -0.1482445, 0.08389144, 0.2004473,
                        0.3420977, 0.4323187, 0.2518767, 0, -0.2772571]
            case .balanced: return [0, 0, 0, 0, 0, 0.4326235, 0, 0.4326235, 0, 0]
            }
        }
    }

    /// Coeficientes biquad normalizados (a0 = 1).
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

        /// Filtro "peaking" do Audio EQ Cookbook (R. Bristow-Johnson).
        static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
            guard gain != 0, frequency < sampleRate / 2 else { return Biquad() }
            let a = pow(10, gain / 40)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / a
            return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cos(w0) / a0, b2: (1 - alpha * a) / a0,
                          a1: -2 * cos(w0) / a0, a2: (1 - alpha / a) / a0)
        }

        func magnitude(at frequency: Double, sampleRate: Double) -> Double {
            let w = 2 * Double.pi * frequency / sampleRate
            // |B(e^jw)| / |A(e^jw)|
            func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
                let im = -(c1 * sin(w) + c2 * sin(2 * w))
                return (re * re + im * im).squareRoot()
            }
            return mag(b0, b1, b2) / mag(1, a1, a2)
        }
    }

    /// Filtros das bandas e o pré-ganho que evita clipping: o pico da curva somada
    /// é compensado para baixo, como fazem os EQs de sistema.
    static func design(gains: [Double], sampleRate: Double) -> (filters: [Biquad], preamp: Double) {
        let filters = zip(frequencies, gains).map {
            Biquad.peaking(frequency: $0, gain: $1, q: q, sampleRate: sampleRate)
        }
        var peak = 1.0
        var f = 20.0
        while f < min(20000, sampleRate / 2) {
            peak = max(peak, filters.reduce(1) { $0 * $1.magnitude(at: f, sampleRate: sampleRate) })
            f *= 1.02
        }
        return (filters, 1 / peak)
    }
}
