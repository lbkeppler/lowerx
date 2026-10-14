import Foundation
import Observation

/// Estado do headset e fila de comandos. O NGENUITY espera 100 ms entre comandos
/// (`Thread.Sleep(100)` em `ExecuteCommand`); aqui a fila respeita o mesmo ritmo.
@Observable
@MainActor
final class HeadsetModel {
    private(set) var dongleAttached = false
    private(set) var headsetOnline = false
    private(set) var battery: Int?
    private(set) var charging: Stinger.Charging = .none
    private(set) var sidetone = false
    /// `nil` quando o headset tem um nível fora dos presets.
    private(set) var sidetonePreset: Stinger.SidetonePreset?
    private(set) var autoOff: UInt8 = 0
    private(set) var microphoneMuted = false

    @ObservationIgnored private let transport = HIDTransport()
    @ObservationIgnored private var queue: [[UInt8]] = []
    @ObservationIgnored private var pump: Timer?
    @ObservationIgnored private var poll: Timer?

    init() {
        transport.onAttach = { [weak self] in
            MainActor.assumeIsolated {
                self?.dongleAttached = true
                self?.enqueue(.getStatus)
            }
        }
        transport.onDetach = { [weak self] in
            MainActor.assumeIsolated { self?.reset() }
        }
        transport.onReport = { [weak self] report in
            MainActor.assumeIsolated { self?.handle(report) }
        }
        transport.start()
        // Bateria e status a cada 30 s; também detecta o headset ligando/desligando.
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPeriodic() }
        }
    }

    func setSidetone(_ on: Bool) {
        sidetone = on
        enqueue(.setSidetone, on ? 1 : 0)
        enqueue(.getSidetone)
    }

    func setSidetonePreset(_ preset: Stinger.SidetonePreset) {
        sidetonePreset = preset
        enqueue(.setSidetoneVolume, preset.rawValue)
        // O nível só vale quando o sidetone é ligado: religa para aplicar.
        if sidetone {
            enqueue(.setSidetone, 0, coalesce: false)
            enqueue(.setSidetone, 1, coalesce: false)
        }
        enqueue(.getSidetoneVolume)
    }

    func setAutoOff(_ minutes: UInt8) {
        autoOff = minutes
        enqueue(.setAutoOff, minutes)
        enqueue(.getAutoOff)
    }

    func refresh() {
        enqueue(.getStatus)
        if headsetOnline { readAll() }
    }

    // MARK: - Interno

    private func refreshPeriodic() {
        guard dongleAttached else { return }
        enqueue(.getStatus)
        if headsetOnline {
            enqueue(.getBattery)
            enqueue(.getCharge)
            enqueue(.getSidetone)
            enqueue(.getMicrophone)
        }
    }

    private func readAll() {
        enqueue(.getBattery)
        enqueue(.getCharge)
        enqueue(.getSidetone)
        enqueue(.getSidetoneVolume)
        enqueue(.getAutoOff)
        enqueue(.getMicrophone)
    }

    private func reset() {
        dongleAttached = false
        headsetOnline = false
        battery = nil
        charging = .none
        queue.removeAll()
    }

    private func handle(_ report: [UInt8]) {
        guard let event = Stinger.parse(report) else { return }
        switch event {
        case .headsetOnline(let online):
            let cameOnline = online && !headsetOnline
            headsetOnline = online
            if cameOnline { readAll() }
            if !online { battery = nil; charging = .none }
        case .battery(let level): battery = level
        case .charging(let state): charging = state
        case .sidetone(let on): sidetone = on
        case .sidetoneLevel(let level): sidetonePreset = Stinger.SidetonePreset(rawValue: level)
        case .autoOff(let minutes): autoOff = minutes
        case .microphoneMuted(let muted): microphoneMuted = muted
        case .rejected(let cmd):
            switch cmd {
            case .setSidetone: enqueue(.getSidetone)
            case .setAutoOff: enqueue(.getAutoOff)
            case .setSidetoneVolume: enqueue(.getSidetoneVolume)
            default: break
            }
        }
    }

    private func enqueue(_ cmd: Stinger.Command, _ values: UInt8..., coalesce: Bool = true) {
        var report = Stinger.report(cmd)
        for (i, v) in values.enumerated() { report[4 + i] = v }
        // Cliques repetidos geram vários ajustes: um "set" ainda não enviado é
        // substituído pelo mais recente em vez de enfileirar todos.
        if coalesce, !values.isEmpty, let i = queue.firstIndex(where: { $0[3] == cmd.rawValue }) {
            queue[i] = report
        } else {
            queue.append(report)
        }
        startPump()
    }


    private func startPump() {
        guard pump == nil else { return }
        sendNext()
        pump = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendNext() }
        }
    }

    private func sendNext() {
        guard !queue.isEmpty else {
            pump?.invalidate()
            pump = nil
            return
        }
        transport.send(queue.removeFirst())
    }
}
