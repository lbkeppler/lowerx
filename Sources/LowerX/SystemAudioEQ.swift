import CoreAudio
import Foundation
import os

/// Leva o áudio do sistema pelos efeitos até uma saída de som, sem driver de terceiros:
/// um "process tap" do Core Audio (macOS 14.2+) captura o que os apps mandam para a
/// origem, um aggregate device privado junta o tap e a saída, e o IOProc dele escreve
/// na saída o áudio processado.
///
/// A origem é a própria saída (qualquer fone ou alto-falante; o tap usa
/// `mutedWhenTapped`, então se o app parar ou fechar o som volta direto ao normal) ou
/// a saída virtual "LowerX 7.1" (8 canais, instalada pelo app; o driver não toca nada
/// sozinho), que toca no Stinger.
final class SystemAudioEQ {
    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) (\(status))" }
    }

    let processor = AudioProcessor()
    private(set) var sampleRate = 48000.0
    private(set) var sourceUID: String?
    private(set) var outputUID: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var isRunning: Bool { procID != nil }

    deinit { stop() }

    func start(sourceUID: String, outputUID: String) throws {
        stop()
        do {
            try startPipeline(sourceUID: sourceUID, outputUID: outputUID)
            self.sourceUID = sourceUID
            self.outputUID = outputUID
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        sourceUID = nil
        outputUID = nil
    }

    private func startPipeline(sourceUID: String, outputUID: String) throws {
        // O próprio app fica fora do tap: é ele quem toca o resultado no headset.
        let me = try AudioDevices.processObject(pid: getpid())
        let description = CATapDescription(excludingProcesses: [me], deviceUID: sourceUID, stream: 0)
        description.name = "LowerX"
        description.isPrivate = true
        // Tocando no próprio Stinger, o som original precisa ser calado; na saída 7.1
        // o driver já descarta tudo.
        description.muteBehavior = sourceUID == outputUID ? .mutedWhenTapped : .unmuted
        try check("Criar tap", AudioHardwareCreateProcessTap(description, &tapID))

        let format = try AudioDevices.tapFormat(tapID)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw Failure(step: "Formato de áudio não suportado", status: OSStatus(format.mFormatID))
        }
        sampleRate = format.mSampleRate
        processor.tapChannels = Int(format.mChannelsPerFrame)
        // Se o mixer da Apple não abrir, o EQ segue funcionando sem o espacial.
        processor.spatial = try? SpatialRenderer(sampleRate: sampleRate)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LowerX",
            kAudioAggregateDeviceUIDKey: "dev.local.lowerx.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try check("Criar aggregate device",
                  AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let processor = processor
        try check("Criar IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, input, _, output, _ in
            processor.process(input: input, output: output)
        })
        try check("Iniciar áudio", AudioDeviceStart(aggregateID, procID))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }
}

/// Cadeia de efeitos na thread de tempo real do Core Audio:
/// origem (2 ou 8 canais) → espacial ou downmix → EQ → volume → headset.
/// Nada de alocação nem lock bloqueante no caminho do áudio.
final class AudioProcessor: @unchecked Sendable {
    struct Settings {
        var filters: [Equalizer.Biquad]
        var preamp: Double
        var spatial: Bool
        /// Volume da saída 7.1 (o driver não aplica volume); 1 com a origem no Stinger.
        var gain: Float
    }

    static let maxChannels = 8
    private let bands = Equalizer.frequencies.count
    /// b0 b1 b2 a1 a2 por banda.
    private let coefficients: UnsafeMutablePointer<Double>
    /// z1 z2 por canal (2) e banda (forma direta II transposta).
    private let state: UnsafeMutablePointer<Double>
    /// Áudio da origem, um buffer por canal.
    private let source: [UnsafeMutablePointer<Float>]
    /// Mix estéreo antes do EQ.
    private let stereo: [UnsafeMutablePointer<Float>]
    private var preamp = 1.0
    private var spatialEnabled = false
    private var gain: Float = 1
    private let pending = OSAllocatedUnfairLock<Settings?>(initialState: nil)

    /// Canais do tap. Na entrada do aggregate eles vêm depois das entradas do próprio
    /// headset (o microfone), então são os últimos da lista.
    var tapChannels = 2
    /// Criado antes de o áudio começar; `nil` se o AUSpatialMixer não abriu.
    var spatial: SpatialRenderer?

    init() {
        coefficients = .allocate(capacity: bands * 5)
        state = .allocate(capacity: 2 * bands * 2)
        state.initialize(repeating: 0, count: 2 * bands * 2)
        source = (0..<Self.maxChannels).map { _ in .allocate(capacity: SpatialRenderer.maxFrames) }
        stereo = (0..<2).map { _ in .allocate(capacity: SpatialRenderer.maxFrames) }
        apply(Settings(filters: Array(repeating: Equalizer.Biquad(), count: bands), preamp: 1, spatial: false, gain: 1))
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        (source + stereo).forEach { $0.deallocate() }
    }

    func update(_ settings: Settings) {
        pending.withLock { $0 = settings }
    }

    private func apply(_ settings: Settings) {
        for b in 0..<min(settings.filters.count, bands) {
            let f = settings.filters[b]
            coefficients[b * 5] = f.b0
            coefficients[b * 5 + 1] = f.b1
            coefficients[b * 5 + 2] = f.b2
            coefficients[b * 5 + 3] = f.a1
            coefficients[b * 5 + 4] = f.a2
        }
        preamp = settings.preamp
        spatialEnabled = settings.spatial
        gain = settings.gain
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        // Se o lock estiver ocupado agora, os novos ajustes entram no próximo ciclo.
        if let next = pending.withLockIfAvailable({ value -> Settings? in
            defer { value = nil }
            return value
        }) ?? nil {
            apply(next)
        }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let first = outputs.first, first.mNumberChannels > 0 else { return }
        let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), SpatialRenderer.maxFrames)

        // 1. Origem → buffers por canal (um canal só vira os dois lados).
        let inChannels = inputs.reduce(0) { $0 + Int($1.mNumberChannels) }
        let channels = min(tapChannels, inChannels, Self.maxChannels)
        for c in 0..<max(channels, 2) {
            let out = source[c]
            guard channels > 0,
                  let from = Self.channel(inChannels - min(tapChannels, inChannels) + c % channels, in: inputs) else {
                out.update(repeating: 0, count: frames)
                continue
            }
            let n = min(frames, from.frames)
            for i in 0..<n { out[i] = from.data[i * from.stride] }
            if n < frames { (out + n).update(repeating: 0, count: frames - n) }
        }

        // 2. Espacial: 7.1 sempre posicionado; estéreo só com o toggle ligado.
        var left = UnsafePointer(source[0]), right = UnsafePointer(source[1])
        if let spatial {
            if (spatialEnabled || channels >= 8),
               spatial.render(source, channels: channels, frames: frames, upmixStereo: spatialEnabled) {
                left = UnsafePointer(spatial.outLeft)
                right = UnsafePointer(spatial.outRight)
            }
        } else if channels >= 8 {
            // Sem o mixer da Apple, o 7.1 vira estéreo.
            Self.downmix(source, into: stereo, frames: frames)
            left = UnsafePointer(stereo[0])
            right = UnsafePointer(stereo[1])
        }

        // 3. EQ e volume → saída do headset, no layout que o dispositivo pedir.
        for c in 0..<2 {
            let from = c == 0 ? left : right
            let out = stereo[c]
            let z = state + c * bands * 2
            for i in 0..<frames {
                var x = Double(from[i]) * preamp
                for b in 0..<bands {
                    let k = coefficients + b * 5
                    let y = k[0] * x + z[b * 2]
                    z[b * 2] = k[1] * x - k[3] * y + z[b * 2 + 1]
                    z[b * 2 + 1] = k[2] * x - k[4] * y
                    x = y
                }
                out[i] = Float(x) * gain
            }
        }
        var outChannel = 0
        for buffer in outputs {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            let available = min(frames, Int(buffer.mDataByteSize) / (4 * max(stride, 1)))
            for c in 0..<stride {
                let from = stereo[outChannel % 2]
                for i in 0..<available { out[i * stride + c] = from[i] }
                outChannel += 1
            }
        }
    }

    /// Downmix 7.1 → estéreo (ITU, −3 dB nos canais compartilhados), com folga
    /// para não distorcer quando todos os canais tocam juntos.
    private static func downmix(_ s: [UnsafeMutablePointer<Float>], into out: [UnsafeMutablePointer<Float>],
                                frames: Int) {
        let k: Float = 0.7071
        for i in 0..<frames {
            let shared = k * (s[2][i] + s[3][i])
            out[0][i] = 0.5 * (s[0][i] + shared + k * (s[4][i] + s[6][i]))
            out[1][i] = 0.5 * (s[1][i] + shared + k * (s[5][i] + s[7][i]))
        }
    }

    private static func channel(_ index: Int, in list: UnsafeMutableAudioBufferListPointer)
        -> (data: UnsafePointer<Float>, stride: Int, frames: Int)? {
        var first = 0
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            if index < first + count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                return (UnsafePointer(data + (index - first)), count, Int(buffer.mDataByteSize) / (4 * count))
            }
            first += count
        }
        return nil
    }
}

/// Consultas ao Core Audio usadas pelo app.
enum AudioDevices {
    static let stingerName = "HyperX Cloud Stinger 2 Wireless"
    /// UID da saída virtual do driver `Driver/LowerX71.c`.
    static let surroundUID = "dev.local.lowerx.surround71"
    /// Mesma saída, instalada quando o app se chamava HeadsetBar.
    static let legacySurroundUID = "dev.local.headsetbar.surround71"

    /// UID Core Audio do Stinger (entrada e saída são o mesmo dispositivo).
    static func stingerUID() -> String? {
        allDevices().lazy.compactMap { uid($0) }.first { $0.contains(stingerName) }
    }

    static func defaultOutputUID() -> String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) else {
            return nil
        }
        return uid(id)
    }

    static func isSurround(_ uid: String) -> Bool {
        uid == surroundUID || uid == legacySurroundUID
    }

    static func name(uid wanted: String) -> String? {
        guard let id = deviceID(uid: wanted) else { return nil }
        var name: Unmanaged<CFString>?
        guard get(id, kAudioObjectPropertyName, &name), let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func deviceID(uid wanted: String) -> AudioObjectID? {
        allDevices().first { uid($0) == wanted }
    }

    static func setDefaultOutput(uid: String) {
        guard var id = deviceID(uid: uid) else { return }
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    /// Ganho linear do volume/mudo de saída do dispositivo (curva do driver: dB = 40·log10).
    static func outputGain(_ device: AudioObjectID) -> Float {
        var muted: UInt32 = 0
        if let mute = control(device, kAudioMuteControlClassID), get(mute, kAudioBooleanControlPropertyValue, &muted),
           muted != 0 { return 0 }
        var scalar: Float32 = 1
        guard let volume = control(device, kAudioVolumeControlClassID),
              get(volume, kAudioLevelControlPropertyScalarValue, &scalar) else { return 1 }
        return scalar * scalar
    }

    /// Chama `body` quando muda o volume ou o mudo do dispositivo.
    static func observeOutputGain(_ device: AudioObjectID, _ body: @escaping () -> Void) {
        for (classID, selector) in [(kAudioVolumeControlClassID, kAudioLevelControlPropertyScalarValue),
                                    (kAudioMuteControlClassID, kAudioBooleanControlPropertyValue)] {
            guard let control = control(device, classID) else { continue }
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(control, &address, .main) { _, _ in body() }
        }
    }

    private static func control(_ device: AudioObjectID, _ classID: AudioClassID) -> AudioObjectID? {
        var address = address(kAudioObjectPropertyControlList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first {
            var objectClass: AudioClassID = 0
            return get($0, kAudioObjectPropertyClass, &objectClass) && objectClass == classID
        }
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else {
            throw SystemAudioEQ.Failure(step: "Processo de áudio", status: status)
        }
        return object
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        guard get(tap, kAudioTapPropertyFormat, &format) else {
            throw SystemAudioEQ.Failure(step: "Formato do tap", status: -1)
        }
        return format
    }

    /// Chama `body` quando muda a saída padrão ou a lista de dispositivos.
    static func observeChanges(_ body: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                body()
            }
        }
    }

    // MARK: - Interno

    private static func allDevices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uid(_ id: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        guard get(id, kAudioDevicePropertyDeviceUID, &value), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) == noErr
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Permissão de "Gravação de áudio do sistema". Não há API pública para consultá-la;
/// o TCC.framework expõe a mesma chamada que o macOS usa para mostrar o pedido.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return completion(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { completion($0) }
    }
}
