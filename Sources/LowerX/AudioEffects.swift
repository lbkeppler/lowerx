import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// Estado do EQ, do espacial e da saída 7.1. Tudo vale só para o Stinger: os efeitos
/// rodam quando a saída do Mac é o próprio Stinger ou a "LowerX 7.1" (que toca nele).
/// O `SystemAudioEQ` liga quando a saída é a 7.1 (sempre: senão nada tocaria) ou quando
/// algum efeito está ativo; fora isso não existe tap nenhum.
@Observable
@MainActor
final class AudioEffects {
    enum Selection: Hashable {
        case off
        case preset(Equalizer.Preset)
        case custom
    }

    enum State: Equatable {
        case off
        /// Efeito ligado (ou Saída 7.1 escolhida), mas o Stinger não está conectado.
        case stingerMissing
        /// Efeito ligado, mas a saída de som do Mac é outra.
        case otherOutput
        case waitingPermission
        case denied
        case active
        case failed(String)
    }

    var selection: Selection {
        didSet {
            UserDefaults.standard.set(Self.encode(selection), forKey: Self.selectionKey)
            update()
        }
    }

    var spatial: Bool {
        didSet {
            UserDefaults.standard.set(spatial, forKey: Self.spatialKey)
            update()
        }
    }

    /// Ganhos do modo Personalizado, em dB.
    var customGains: [Double] {
        didSet {
            UserDefaults.standard.set(customGains, forKey: Self.customKey)
            if selection == .custom { update() }
        }
    }

    /// Driver da saída 7.1 instalado.
    private(set) var surroundInstalled = false
    /// Só a versão antiga ("HeadsetBar 7.1") está instalada: reinstalar atualiza.
    private(set) var surroundNeedsUpdate = false
    /// A saída de som do Mac é a "LowerX 7.1".
    private(set) var usingSurround = false
    private(set) var installing = false

    private(set) var state: State = .off {
        didSet {
            if state != oldValue { log.notice("EQ: \(String(describing: self.state), privacy: .public)") }
        }
    }

    @ObservationIgnored private let engine = SystemAudioEQ()
    @ObservationIgnored private var requestingPermission = false
    @ObservationIgnored private var observedSurround: AudioObjectID?
    @ObservationIgnored private let log = Logger(subsystem: "dev.local.lowerx", category: "eq")
    private static let selectionKey = "eqSelection"
    private static let customKey = "eqCustomGains"
    private static let spatialKey = "spatial"

    init() {
        let defaults = UserDefaults.standard
        selection = Self.decode(defaults.string(forKey: Self.selectionKey))
        spatial = defaults.bool(forKey: Self.spatialKey)
        let saved = defaults.array(forKey: Self.customKey) as? [Double]
        customGains = saved?.count == Equalizer.frequencies.count ? saved! : Equalizer.flat
        AudioDevices.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    var gains: [Double] {
        switch selection {
        case .off: return Equalizer.flat
        case .preset(let preset): return preset.gains
        case .custom: return customGains
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    /// Reavalia tudo: chamado quando muda um ajuste, a saída de áudio ou a lista de dispositivos.
    func update() {
        let legacyID = AudioDevices.deviceID(uid: AudioDevices.legacySurroundUID)
        let surroundID = AudioDevices.deviceID(uid: AudioDevices.surroundUID) ?? legacyID
        surroundNeedsUpdate = legacyID != nil && surroundID == legacyID
        surroundInstalled = surroundID != nil && !surroundNeedsUpdate
        if let surroundID, observedSurround != surroundID {
            observedSurround = surroundID
            AudioDevices.observeOutputGain(surroundID) { [weak self] in
                MainActor.assumeIsolated { self?.update() }
            }
        }
        let output = AudioDevices.defaultOutputUID()
        usingSurround = output.map(AudioDevices.isSurround) ?? false
        let stinger = AudioDevices.stingerUID()

        guard usingSurround || selection != .off || spatial else { return stop(.off) }
        guard let target = stinger else { return stop(.stingerMissing) }
        guard usingSurround || output == target else { return stop(.otherOutput) }
        switch AudioCapturePermission.status {
        case .authorized: break
        case .denied: return stop(.denied)
        case .unknown:
            stop(.waitingPermission)
            guard !requestingPermission else { return }
            requestingPermission = true
            AudioCapturePermission.request { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.requestingPermission = false
                        self.update()
                    }
                }
            }
            return
        }
        let source = usingSurround ? output ?? AudioDevices.surroundUID : target
        if engine.sourceUID != source || engine.outputUID != target || !engine.isRunning {
            do {
                try engine.start(sourceUID: source, outputUID: target)
                log.notice("Áudio de \(source, privacy: .public) para \(target, privacy: .public), \(self.engine.sampleRate) Hz")
            } catch {
                log.error("Falhou: \(error.localizedDescription, privacy: .public)")
                return stop(.failed(error.localizedDescription))
            }
        }
        let design = Equalizer.design(gains: gains, sampleRate: engine.sampleRate)
        guard !spatial || engine.processor.spatial != nil else {
            return stop(.failed("o mixer espacial da Apple não abriu"))
        }
        let gain = usingSurround ? surroundID.map(AudioDevices.outputGain) ?? 1 : 1
        engine.processor.update(.init(filters: design.filters, preamp: design.preamp, spatial: spatial, gain: gain))
        state = .active
    }

    /// Liga/desliga a saída 7.1 como saída de som do Mac (desligada, volta ao Stinger).
    func useSurround(_ on: Bool) {
        if on {
            AudioDevices.setDefaultOutput(uid: AudioDevices.surroundUID)
        } else {
            useStinger()
        }
    }

    /// Escolhe o Stinger como saída de som do Mac.
    func useStinger() {
        if let stinger = AudioDevices.stingerUID() { AudioDevices.setDefaultOutput(uid: stinger) }
    }

    /// Instala (ou remove) o driver em /Library/Audio/Plug-Ins/HAL. Pede a senha de
    /// administrador e reinicia o coreaudiod, o que corta o som por um instante.
    func installSurround(remove: Bool = false) {
        guard !installing, let bundled = Bundle.main.url(forResource: "LowerX71", withExtension: "driver")
        else { return }
        if remove, usingSurround { useSurround(false) }
        installing = true
        let target = "/Library/Audio/Plug-Ins/HAL/LowerX71.driver"
        // Também remove a versão instalada quando o app se chamava HeadsetBar.
        var command = "rm -rf \(Self.quoted(target)) /Library/Audio/Plug-Ins/HAL/HeadsetBar71.driver"
        if !remove {
            command += " && mkdir -p /Library/Audio/Plug-Ins/HAL && cp -R \(Self.quoted(bundled.path)) \(Self.quoted(target))"
                + " && chown -R root:wheel \(Self.quoted(target)) && chmod -R u=rwX,go=rX \(Self.quoted(target))"
        }
        command += " && killall coreaudiod"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        engine.stop()
        DispatchQueue.global().async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            // O coreaudiod leva alguns segundos para voltar com os dispositivos.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    self.installing = false
                    self.engine.stop()
                    self.update()
                    if !remove, error == nil, self.surroundInstalled { self.useSurround(true) }
                }
            }
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func stop(_ state: State) {
        engine.stop()
        self.state = state
    }

    private static func encode(_ selection: Selection) -> String {
        switch selection {
        case .off: return "off"
        case .custom: return "custom"
        case .preset(let preset): return preset.rawValue
        }
    }

    private static func decode(_ value: String?) -> Selection {
        switch value {
        case "custom": return .custom
        case let raw?: return Equalizer.Preset(rawValue: raw).map(Selection.preset) ?? .off
        case nil: return .off
        }
    }
}
