import AudioToolbox
import Foundation

/// Substituto do "Spatial" da DTS: surround virtual 7.1 com o AUSpatialMixer da Apple
/// (HRTF para fones).
///
/// Áudio 7.1 de verdade (vindo da saída virtual "LowerX 7.1") vai canal a canal
/// para o alto-falante correspondente. Áudio estéreo é distribuído (upmix) nos 7
/// alto-falantes virtuais. O que é igual nos dois lados (voz, bumbo) vai SÓ para o centro: tocar o
/// mesmo som em dois alto-falantes virtuais cria buracos no espectro (−15 dB em 2 kHz
/// nos testes) e deixa tudo abafado. A diferença entre os lados vai para as frentes e,
/// atrasada, para laterais e traseiras, que dão a sensação de ambiente.
///
/// `render` roda na thread de tempo real do `SystemAudioEQ`, depois do EQ.
final class SpatialRenderer {
    static let maxFrames = 4096

    struct Speaker {
        let azimuth: Float32
        /// Sinal que o alto-falante recebe: centro (L+R)/2 ou lateral ±(L−R)/2.
        let mid: Bool
        let sign: Float
        let gain: Float
        /// Atraso em ms, só nos canais de ambiente.
        let delay: Double
    }

    /// Disposição 7.1 (sem o LFE: o grave fica no centro, que não é direcional).
    static let speakers: [Speaker] = [
        Speaker(azimuth: 0, mid: true, sign: 1, gain: 1, delay: 0),          // centro
        Speaker(azimuth: -30, mid: false, sign: 1, gain: 1, delay: 0),       // frente esq.
        Speaker(azimuth: 30, mid: false, sign: -1, gain: 1, delay: 0),       // frente dir.
        Speaker(azimuth: -90, mid: false, sign: 1, gain: 0.5, delay: 10),    // lateral esq.
        Speaker(azimuth: 90, mid: false, sign: -1, gain: 0.5, delay: 10),    // lateral dir.
        Speaker(azimuth: -150, mid: false, sign: 1, gain: 0.35, delay: 18),  // traseira esq.
        Speaker(azimuth: 150, mid: false, sign: -1, gain: 0.35, delay: 18),  // traseira dir.
    ]
    static let distance: Float32 = 1
    /// Medido com ruído por oitava: o centro sai plano (±1,5 dB) e uns 3 dB abaixo da
    /// entrada; nenhuma banda passa da entrada, então não há ganho extra a compensar.
    static let outputGain: Float32 = 0

    /// Saída estéreo do último `render`.
    let outLeft: UnsafeMutablePointer<Float>
    let outRight: UnsafeMutablePointer<Float>

    private var unit: AudioUnit?
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var time = AudioTimeStamp()
    /// Um buffer por alto-falante, preenchido antes de cada `AudioUnitRender`.
    private let feeds: [UnsafeMutablePointer<Float>]
    /// Histórico do sinal lateral para os atrasos.
    private let history: UnsafeMutablePointer<Float>
    private let historyLength: Int
    private var historyPosition = 0
    private let delays: [Int]
    /// Amostras que faltam para voltar ao upmix depois do último som nos canais
    /// além de L/R (apps que mandam estéreo para a saída 7.1 só usam L/R).
    private var multichannelHold = 0
    private let sampleRate: Double

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        outLeft = .allocate(capacity: Self.maxFrames)
        outRight = .allocate(capacity: Self.maxFrames)
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        feeds = Self.speakers.map { _ in .allocate(capacity: Self.maxFrames) }
        delays = Self.speakers.map { Int($0.delay / 1000 * sampleRate) }
        historyLength = Self.maxFrames + (delays.max() ?? 0) + 1
        history = .allocate(capacity: historyLength)
        history.initialize(repeating: 0, count: historyLength)
        time.mFlags = .sampleTimeValid

        var description = AudioComponentDescription(componentType: kAudioUnitType_Mixer,
                                                    componentSubType: kAudioUnitSubType_SpatialMixer,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw SystemAudioEQ.Failure(step: "AUSpatialMixer indisponível", status: -1)
        }
        try check("Abrir AUSpatialMixer", AudioComponentInstanceNew(component, &unit))
        guard let unit else { return }

        var buses = UInt32(Self.speakers.count)
        try set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &buses)
        var frames = UInt32(Self.maxFrames)
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames)
        var outputType = AUSpatialMixerOutputType.spatialMixerOutputType_Headphones
        try set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType)
        // Sem sala virtual: o reverb também escurecia o som. A sensação de espaço vem
        // dos canais de ambiente atrasados.
        var reverb: UInt32 = 0
        try set(kAudioUnitProperty_UsesInternalReverb, kAudioUnitScope_Global, 0, &reverb)

        var stereo = Self.format(sampleRate: sampleRate, channels: 2)
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stereo)

        let context = Unmanaged.passUnretained(self).toOpaque()
        for (bus, speaker) in Self.speakers.enumerated() {
            let bus = UInt32(bus)
            var mono = Self.format(sampleRate: sampleRate, channels: 1)
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, &mono)
            var algorithm = AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType
            try set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, bus, &algorithm)
            var mode = AUSpatialMixerSourceMode.spatialMixerSourceMode_PointSource
            try set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, bus, &mode)
            var callback = AURenderCallbackStruct(inputProc: Self.feed, inputProcRefCon: context)
            try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus, &callback)
            for (parameter, value) in [(kSpatialMixerParam_Azimuth, speaker.azimuth),
                                       (kSpatialMixerParam_Distance, Self.distance)] {
                try check("Parâmetro do mixer",
                          AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Input, bus, value, 0))
            }
        }
        try check("Ganho do mixer",
                  AudioUnitSetParameter(unit, kSpatialMixerParam_Gain, kAudioUnitScope_Output, 0, Self.outputGain, 0))
        try check("Iniciar AUSpatialMixer", AudioUnitInitialize(unit))
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        for buffer in feeds + [outLeft, outRight, history] { buffer.deallocate() }
        free(outputList.unsafeMutablePointer)
    }

    /// Processa `frames` amostras dos `channels` primeiros buffers de `input` (2 = estéreo,
    /// 8 = 7.1 na ordem L R C LFE Ls Rs Rls Rrs) para `outLeft`/`outRight`.
    /// Áudio 7.1 é sempre posicionado; estéreo só com `upmixStereo` (o toggle Espacial).
    /// Devolve `false` quando não processou: quem chama usa L/R como vieram.
    func render(_ input: [UnsafeMutablePointer<Float>], channels: Int, frames: Int, upmixStereo: Bool) -> Bool {
        guard let unit, frames <= Self.maxFrames, input.count >= 2 else { return false }
        if channels >= 8, input.count >= 8 {
            var energy: Float = 0
            for c in 2..<8 { for i in 0..<frames { energy += input[c][i] * input[c][i] } }
            if energy > 1e-8 { multichannelHold = Int(sampleRate) } else { multichannelHold -= frames }
        } else {
            multichannelHold = 0
        }
        let discrete = multichannelHold > 0
        guard discrete || upmixStereo else { return false }
        let left = input[0], right = input[1]
        for i in 0..<frames {
            let mid = (left[i] + right[i]) / 2
            let side = (left[i] - right[i]) / 2
            history[historyPosition] = side
            if discrete {
                feeds[0][i] = input[2][i] + input[3][i]   // centro + LFE (grave não tem direção)
                feeds[1][i] = left[i]
                feeds[2][i] = right[i]
                for s in 3..<7 { feeds[s][i] = input[s + 1][i] }   // Ls Rs Rls Rrs
            } else {
                for (s, speaker) in Self.speakers.enumerated() {
                    var value = mid
                    if !speaker.mid {
                        var index = historyPosition - delays[s]
                        if index < 0 { index += historyLength }
                        value = history[index] * speaker.sign
                    }
                    feeds[s][i] = value * speaker.gain
                }
            }
            historyPosition = (historyPosition + 1) % historyLength
        }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outLeft)
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: outRight)
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), outputList.unsafeMutablePointer)
        time.mSampleTime += Double(frames)
        return status == noErr
    }

    /// Entrega ao mixer o sinal do alto-falante `bus`.
    private static let feed: AURenderCallback = { context, _, _, bus, frames, data in
        let renderer = Unmanaged<SpatialRenderer>.fromOpaque(context).takeUnretainedValue()
        guard let data, let destination = UnsafeMutableAudioBufferListPointer(data).first?.mData,
              Int(bus) < renderer.feeds.count else { return noErr }
        destination.copyMemory(from: renderer.feeds[Int(bus)], byteCount: Int(frames) * MemoryLayout<Float>.size)
        return noErr
    }

    private static func format(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: UInt32,
                        _ value: inout T) throws {
        guard let unit else { return }
        let status = withUnsafeMutablePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size))
        }
        try check("Propriedade \(property) do mixer", status)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioEQ.Failure(step: step, status: status) }
    }
}
