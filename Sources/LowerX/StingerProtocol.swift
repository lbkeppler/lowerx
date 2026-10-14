import Foundation

/// Protocolo HID do Cloud Stinger 2 Wireless, reconstruído do NGenuity2Helper.exe
/// (`CMDHSCloudStinger2Wireless*` / `HeadsetCloudStinger2Wireless.Device_InputReportReceived`)
/// e verificado no dispositivo real.
///
/// Toda mensagem é um report de 20 bytes (ID 0x06) na coleção vendor 0xFF90/0x0303:
/// `06 FF BB <cmd> <valor…>`. A resposta volta como input report com o mesmo cabeçalho
/// e o mesmo `cmd`; em comandos "set", `resp[4]` ecoa o valor e `resp[5] == 1` é sucesso.
enum Stinger {
    static let vendorID = 0x03F0
    static let productID = 0x0D93
    static let usagePage = 0xFF90
    static let usage = 0x0303
    static let reportID: UInt8 = 0x06
    static let reportLength = 20

    enum Command: UInt8 {
        case getStatus = 0x01
        case getBattery = 0x02
        case getCharge = 0x03
        case getMicrophone = 0x05
        case getSidetone = 0x06
        case getAutoOff = 0x07
        case getSidetoneVolume = 0x0B
        /// Evento espontâneo ao mover a haste: `r[4] == 1` mutado (haste levantada).
        case microphoneEvent = 0x20
        case setSidetone = 0x21
        case setAutoOff = 0x22
        case setSidetoneVolume = 0x23
    }

    static func report(_ cmd: Command, _ values: UInt8...) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: reportLength)
        out[0] = reportID
        out[1] = 0xFF
        out[2] = 0xBB
        out[3] = cmd.rawValue
        for (i, v) in values.enumerated() { out[4 + i] = v }
        return out
    }

    enum Charging: Equatable {
        case none, charging, full, error
    }

    /// Opções de desligamento automático, em minutos (0 = nunca), como nos outros
    /// headsets HyperX (`*PowerAutoOffTiming`). 10 e 0 verificados no dispositivo.
    static let autoOffChoices: [UInt8] = [0, 10, 20, 30]

    /// Nível do sidetone (0x23/0x0B), em dB com sinal. Só é aplicado quando o sidetone
    /// é LIGADO (0x21 01) — mudar com ele ligado não altera nada. Valores positivos
    /// amplificam: 0x20 (+32 dB) foi ensurdecedor no teste. Por isso o app só envia
    /// estes dois níveis, verificados de ouvido.
    enum SidetonePreset: UInt8, CaseIterable {
        /// −25 dB, padrão de fábrica.
        case standard = 0xE7
        /// −12 dB.
        case optimized = 0xF4

        var title: String {
            switch self {
            case .standard: return "Padrão"
            case .optimized: return "Otimizado"
            }
        }
    }

    enum Event: Equatable {
        /// `true` quando o headset está ligado e pareado com o dongle (status 1 ou 4).
        case headsetOnline(Bool)
        case battery(Int)
        case charging(Charging)
        case sidetone(Bool)
        case sidetoneLevel(UInt8)
        case autoOff(UInt8)
        /// Haste levantada = microfone mutado.
        case microphoneMuted(Bool)
        /// Comando "set" recusado pelo headset.
        case rejected(Command)
    }

    static func parse(_ r: [UInt8]) -> Event? {
        guard r.count >= 8, r[0] == reportID, r[1] == 0xFF, r[2] == 0xBB,
              let cmd = Command(rawValue: r[3]) else { return nil }
        switch cmd {
        case .getStatus: return .headsetOnline(r[4] == 1 || r[4] == 4)
        case .getBattery: return .battery(Int(r[7]))
        case .getCharge:
            switch r[4] {
            case 1: return .charging(.charging)
            case 2: return .charging(.full)
            case 3: return .charging(.error)
            default: return .charging(.none)
            }
        case .getSidetone: return .sidetone(r[4] != 0)
        case .getSidetoneVolume: return .sidetoneLevel(r[4])
        case .getAutoOff: return .autoOff(r[4])
        case .getMicrophone, .microphoneEvent: return .microphoneMuted(r[4] == 1)
        // Os "set" ecoam o valor aplicado; o eco também chega quando outro programa
        // (ou o próprio headset) muda o ajuste, então vale como estado atual.
        case .setSidetone: return r[5] == 1 ? .sidetone(r[4] != 0) : .rejected(cmd)
        case .setAutoOff: return r[5] == 1 ? .autoOff(r[4]) : .rejected(cmd)
        case .setSidetoneVolume: return r[5] == 1 ? .sidetoneLevel(r[4]) : .rejected(cmd)
        }
    }
}
