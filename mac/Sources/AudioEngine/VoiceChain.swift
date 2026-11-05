import AVFoundation
import AudioToolbox

/// Cadena de voz en tiempo real: lo que se oye al mover un control es exactamente lo que se exporta.
///
/// Por cada persona: ecualizador (Audio Unit del sistema, `AUNBandEQ`), compresor «voz pareja»
/// (`AUDynamicsProcessor`), de-esser «menos siseo» (propio, por bandas) y limitador (`AUPeakLimiter`).
/// Hasta hoy esto se hacía con ffmpeg generando un archivo por cada ajuste; ahora se procesa al vuelo
/// dentro de la mezcla (`MTAudioProcessingTap`), igual en la vista previa que en el export.
///
/// `VoiceEQ` sigue siendo la configuración «simple» (graves/medios/agudos, retumbe, voz pareja, siseo);
/// aquí se traduce a parámetros de los Audio Units. En el estudio (etapa B) se expondrán los parámetros
/// completos sobre esta misma cadena.
final class VoiceChain: @unchecked Sendable {
    private var eqUnit: AudioUnit?
    private var compUnit: AudioUnit?
    private var limUnit: AudioUnit?
    private var prepared = false
    private var channels = 0
    private var sampleRate = 48_000.0

    // De-esser por bandas (estado por canal)
    private var dsLow: [Float] = []
    private var dsEnv: [Float] = []
    private var dsOn = false
    private var dsCoef: Float = 0
    private var dsRelease: Float = 0.9995

    private var lock = os_unfair_lock()
    private var pending: VoiceEQ?
    private(set) var settings = VoiceEQ()

    // Bandas del ecualizador (índice fijo): 0 paso alto 120 · 1 −3 dB a 250 · 2 graves · 3 medios · 4 agudos
    private enum Band: UInt32 { case highpass = 0, rumble = 1, low = 2, mid = 3, high = 4 }
    private static let bandCount: UInt32 = 5

    init(settings: VoiceEQ) { self.settings = settings }

    deinit { teardown() }

    // MARK: Preparar con el formato de la pista

    func prepare(format: AudioStreamBasicDescription, maxFrames: UInt32) {
        teardown()
        var asbd = format
        channels = Int(asbd.mChannelsPerFrame)
        sampleRate = asbd.mSampleRate
        guard let eq = Self.makeUnit(kAudioUnitSubType_NBandEQ),
              let comp = Self.makeUnit(kAudioUnitSubType_DynamicsProcessor),
              let lim = Self.makeUnit(kAudioUnitSubType_PeakLimiter) else { return }
        eqUnit = eq; compUnit = comp; limUnit = lim
        var bands = Self.bandCount
        AudioUnitSetProperty(eq, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, UInt32(MemoryLayout<UInt32>.size))
        var frames = maxFrames
        for u in [eq, comp, lim] {
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        // eq → comp → lim
        var c1 = AudioUnitConnection(sourceAudioUnit: eq, sourceOutputNumber: 0, destInputNumber: 0)
        AudioUnitSetProperty(comp, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &c1, UInt32(MemoryLayout<AudioUnitConnection>.size))
        var c2 = AudioUnitConnection(sourceAudioUnit: comp, sourceOutputNumber: 0, destInputNumber: 0)
        AudioUnitSetProperty(lim, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &c2, UInt32(MemoryLayout<AudioUnitConnection>.size))
        // Bandas fijas del EQ
        setBand(.highpass, type: Self.ftHighPass, freq: 120, gain: 0, width: 0.5)
        setBand(.rumble, type: Self.ftParametric, freq: 250, gain: -3, width: 1)
        setBand(.low, type: Self.ftParametric, freq: 120, gain: 0, width: 0.8)
        setBand(.mid, type: Self.ftParametric, freq: 1000, gain: 0, width: 1)
        setBand(.high, type: Self.ftParametric, freq: 6000, gain: 0, width: 0.8)
        // Limitador siempre al final (como el alimiter de antes): sin ganancia previa
        AudioUnitSetParameter(lim, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        AudioUnitSetParameter(lim, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(lim, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        // De-esser: paso alto de un polo a 5 kHz
        dsCoef = Float(1 - exp(-2 * Double.pi * 5000 / sampleRate))
        dsRelease = Float(exp(-1 / (0.06 * sampleRate)))
        dsLow = Array(repeating: 0, count: channels)
        dsEnv = Array(repeating: 0, count: channels)
        prepared = true
        applyNow(settings)
    }

    /// Quién alimenta el primer eslabón (el tap llama con el audio de la pista).
    func setInput(_ proc: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer) {
        guard let eq = eqUnit else { return }
        var cb = AURenderCallbackStruct(inputProc: proc, inputProcRefCon: refCon)
        AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        for u in [eq, compUnit!, limUnit!] { AudioUnitInitialize(u) }
    }

    func teardown() {
        for u in [eqUnit, compUnit, limUnit].compactMap({ $0 }) {
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        eqUnit = nil; compUnit = nil; limUnit = nil
        prepared = false
    }

    // MARK: Parámetros (se pueden cambiar desde cualquier hilo mientras suena)

    func update(_ eq: VoiceEQ) {
        os_unfair_lock_lock(&lock); pending = eq; settings = eq; os_unfair_lock_unlock(&lock)
    }

    private func applyNow(_ e: VoiceEQ) {
        guard let eqU = eqUnit, let comp = compUnit else { return }
        bypass(.highpass, !e.rumbleCut)
        bypass(.rumble, !e.rumbleCut)
        bypass(.low, abs(e.low) < 0.1)
        bypass(.mid, abs(e.mid) < 0.1)
        bypass(.high, abs(e.high) < 0.1)
        AudioUnitSetParameter(eqU, kAUNBandEQParam_Gain + Band.low.rawValue, kAudioUnitScope_Global, 0, Float(e.low), 0)
        AudioUnitSetParameter(eqU, kAUNBandEQParam_Gain + Band.mid.rawValue, kAudioUnitScope_Global, 0, Float(e.mid), 0)
        AudioUnitSetParameter(eqU, kAUNBandEQParam_Gain + Band.high.rawValue, kAudioUnitScope_Global, 0, Float(e.high), 0)
        // «Voz pareja»: umbral −20 dB, compresión ≈ 3:1, ataque 8 ms, salida 140 ms, +4 dB de compensación
        if e.compress {
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -20, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.008, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.14, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 4, 0)
        } else {
            // Sin compresión: umbral por encima de todo y sin ganancia
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, 0, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 40, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 0, 0)
        }
        AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 1, 0)
        dsOn = e.deess
    }

    // Tipos de filtro de AUNBandEQ: 0 paramétrico · 1 paso bajo Butterworth · 2 paso alto Butterworth
    private static let ftParametric: Float = 0, ftHighPass: Float = 2

    private func setBand(_ b: Band, type: Float, freq: Float, gain: Float, width: Float) {
        guard let eq = eqUnit else { return }
        AudioUnitSetParameter(eq, kAUNBandEQParam_FilterType + b.rawValue, kAudioUnitScope_Global, 0, type, 0)
        AudioUnitSetParameter(eq, kAUNBandEQParam_Frequency + b.rawValue, kAudioUnitScope_Global, 0, freq, 0)
        AudioUnitSetParameter(eq, kAUNBandEQParam_Gain + b.rawValue, kAudioUnitScope_Global, 0, gain, 0)
        AudioUnitSetParameter(eq, kAUNBandEQParam_Bandwidth + b.rawValue, kAudioUnitScope_Global, 0, width, 0)
    }

    private func bypass(_ b: Band, _ on: Bool) {
        guard let eq = eqUnit else { return }
        AudioUnitSetParameter(eq, kAUNBandEQParam_BypassBand + b.rawValue, kAudioUnitScope_Global, 0, on ? 1 : 0, 0)
    }

    // MARK: Procesar un bloque (hilo de audio)

    /// Pasa `frames` cuadros por la cadena. `list` ya tiene el audio de la pista (lo pidió el callback de entrada).
    func render(into list: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, sampleTime: Double) -> OSStatus {
        guard prepared, let lim = limUnit else { return noErr }
        if os_unfair_lock_trylock(&lock) {
            if let p = pending { pending = nil; os_unfair_lock_unlock(&lock); applyNow(p) } else { os_unfair_lock_unlock(&lock) }
        }
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let st = AudioUnitRender(lim, &flags, &ts, 0, frames, list)
        if st == noErr, dsOn { deess(list, frames: Int(frames)) }
        return st
    }

    /// De-esser por bandas: separa lo que hay por encima de 5 kHz, sigue su envolvente y, cuando silba,
    /// baja solo esa parte (hasta −10 dB). Lo demás de la voz no se toca.
    private func deess(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let thr: Float = 0.05          // ≈ −26 dBFS en la banda alta
        let floorGain: Float = 0.32    // −10 dB
        var ch = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData, ch < dsLow.count else { continue }
            let n = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            let x = data.assumingMemoryBound(to: Float.self)
            var low = dsLow[ch], env = dsEnv[ch]
            for i in 0..<n {
                let s = x[i]
                low += dsCoef * (s - low)
                let hf = s - low
                let a = abs(hf)
                env = a > env ? a : env * dsRelease
                var g: Float = 1
                if env > thr { g = max(floorGain, thr / env) }
                x[i] = low + hf * g
            }
            dsLow[ch] = low; dsEnv[ch] = env
            ch += 1
        }
    }

    private static func makeUnit(_ sub: OSType) -> AudioUnit? {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: sub,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var unit: AudioUnit?
        return AudioComponentInstanceNew(comp, &unit) == noErr ? unit : nil
    }
}

/// Las cadenas vivas por persona: la vista previa y un export en marcha pueden tener cada uno la suya;
/// al cambiar un control se actualizan todas (las muertas se descartan solas).
final class VoiceChainRegistry: @unchecked Sendable {
    static let shared = VoiceChainRegistry()
    private var lock = os_unfair_lock()
    private var chains: [Int: [WeakChain]] = [:]
    private struct WeakChain { weak var chain: VoiceChain? }

    func register(_ chain: VoiceChain, lane: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        chains[lane] = (chains[lane] ?? []).filter { $0.chain != nil } + [WeakChain(chain: chain)]
    }

    func update(lane: Int, _ eq: VoiceEQ) {
        os_unfair_lock_lock(&lock)
        let list = (chains[lane] ?? []).compactMap(\.chain)
        os_unfair_lock_unlock(&lock)
        for c in list { c.update(eq) }
    }
}
