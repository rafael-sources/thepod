import AVFoundation
import Combine
import AudioToolbox

/// Real-time voice chain: what you hear when moving a control is exactly what's exported.
///
/// Per person: parametric equalizer of up to 8 bands (`AUNBandEQ`), compressor/gate
/// (`AUDynamicsProcessor`), our own band de-esser and limiter (`AUPeakLimiter`). It's hooked into the
/// track inside the mix (`ChainTap`), the same in the preview as in the export. The configuration
/// is `ChainSettings` (the studio); the simple level (`VoiceEQ`) is a preset of it.
final class VoiceChain: @unchecked Sendable {
    private var eqUnit: AudioUnit?
    private var compUnit: AudioUnit?
    private var limUnit: AudioUnit?
    private var pluginUnits: [(id: UUID, unit: AudioUnit)] = []
    private var appliedState: [UUID: Data] = [:]
    private var prepared = false
    private var channels = 0
    private var sampleRate = 48_000.0

    // Band de-esser (per-channel state)
    private var dsLow: [Float] = []
    private var dsEnv: [Float] = []
    private var dsOn = false
    private var dsFloor: Float = 0.32
    private var dsThr: Float = 0.05
    private var dsCoef: Float = 0
    private var dsRelease: Float = 0.9995

    private var lock = os_unfair_lock()
    private var pending: ChainSettings?
    private(set) var settings: ChainSettings
    private var automated = false

    private static let bandCount: UInt32 = UInt32(ChainSettings.maxBands)
    // AUNBandEQ filter types
    private static let ftParametric: Float = 0, ftLowPass: Float = 1, ftHighPass: Float = 2, ftLowShelf: Float = 7, ftHighShelf: Float = 8

    init(settings: ChainSettings) { self.settings = settings }
    convenience init(settings eq: VoiceEQ) { self.init(settings: ChainSettings.preset(eq)) }

    deinit { teardown() }

    // MARK: Prepare with the track's format

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
        // Third-party plugins between the compressor and the limiter
        pluginUnits = []
        for pl in settings.plugins {
            guard let u = PluginHost.instantiate(pl) else { continue }
            if PluginHost.configure(u, format: &asbd, maxFrames: frames) {
                PluginHost.restore(pl.state, into: u)
                if let st = pl.state { appliedState[pl.id] = st }
                PluginHost.setBypass(u, !pl.enabled)
                pluginUnits.append((pl.id, u))
            } else {
                AudioComponentInstanceDispose(u)
            }
        }
        // eq → comp → plugins… → lim
        var order: [AudioUnit] = [eq, comp] + pluginUnits.map(\.unit) + [lim]
        for i in 1..<order.count {
            var c = AudioUnitConnection(sourceAudioUnit: order[i - 1], sourceOutputNumber: 0, destInputNumber: 0)
            AudioUnitSetProperty(order[i], kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &c, UInt32(MemoryLayout<AudioUnitConnection>.size))
        }
        _ = order.removeAll()
        AudioUnitSetParameter(lim, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        AudioUnitSetParameter(lim, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(lim, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        dsCoef = Float(1 - exp(-2 * Double.pi * 5000 / sampleRate))
        dsRelease = Float(exp(-1 / (0.06 * sampleRate)))
        dsLow = Array(repeating: 0, count: channels)
        dsEnv = Array(repeating: 0, count: channels)
        prepared = true
        applyNow(settings)
        automated = settings.hasAutomation
    }

    /// Who feeds the first link (the tap calls with the track's audio).
    func setInput(_ proc: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer) {
        guard let eq = eqUnit, let comp = compUnit, let lim = limUnit else { return }
        var cb = AURenderCallbackStruct(inputProc: proc, inputProcRefCon: refCon)
        AudioUnitSetProperty(eq, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        for u in [eq, comp] + pluginUnits.map(\.unit) + [lim] { AudioUnitInitialize(u) }
    }

    func teardown() {
        for u in [eqUnit, compUnit, limUnit].compactMap({ $0 }) + pluginUnits.map(\.unit) {
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        eqUnit = nil; compUnit = nil; limUnit = nil; pluginUnits = []
        prepared = false
    }

    /// Is the plugin list (ids and order) the one this chain has mounted? If not, it must be rebuilt.
    func hasPlugins(_ plugins: [PluginInsert]) -> Bool { plugins.map(\.id) == pluginUnits.map(\.id) }

    // MARK: Parameters (from any thread while playing)

    func update(_ c: ChainSettings) {
        os_unfair_lock_lock(&lock); pending = c; settings = c; os_unfair_lock_unlock(&lock)
        // State and bypass of the already mounted plugins: applied here (normal thread), not on the audio one
        if prepared {
            for pl in c.plugins {
                guard let u = pluginUnits.first(where: { $0.id == pl.id })?.unit else { continue }
                PluginHost.setBypass(u, !pl.enabled)
                if let st = pl.state, appliedState[pl.id] != st { PluginHost.restore(st, into: u); appliedState[pl.id] = st }
            }
        }
    }
    func update(_ eq: VoiceEQ) { update(ChainSettings.preset(eq)) }

    private func applyNow(_ c: ChainSettings) {
        guard let eqU = eqUnit, let comp = compUnit, let lim = limUnit else { return }
        // Bands: the ones there are, the rest bypassed
        let bands = Array(c.bands.prefix(ChainSettings.maxBands))
        for i in 0..<ChainSettings.maxBands {
            let b = UInt32(i)
            if i < bands.count, bands[i].enabled {
                let band = bands[i]
                let type: Float
                switch band.kind {
                case .highpass: type = Self.ftHighPass
                case .lowpass: type = Self.ftLowPass
                case .lowshelf: type = Self.ftLowShelf
                case .highshelf: type = Self.ftHighShelf
                case .peak: type = Self.ftParametric
                }
                AudioUnitSetParameter(eqU, kAUNBandEQParam_FilterType + b, kAudioUnitScope_Global, 0, type, 0)
                AudioUnitSetParameter(eqU, kAUNBandEQParam_Frequency + b, kAudioUnitScope_Global, 0, Float(max(20, min(20_000, band.freq))), 0)
                AudioUnitSetParameter(eqU, kAUNBandEQParam_Gain + b, kAudioUnitScope_Global, 0, Float(max(-24, min(24, band.gain))), 0)
                AudioUnitSetParameter(eqU, kAUNBandEQParam_Bandwidth + b, kAudioUnitScope_Global, 0, Float(max(0.05, min(5, band.q))), 0)
                AudioUnitSetParameter(eqU, kAUNBandEQParam_BypassBand + b, kAudioUnitScope_Global, 0, 0, 0)
            } else {
                AudioUnitSetParameter(eqU, kAUNBandEQParam_BypassBand + b, kAudioUnitScope_Global, 0, 1, 0)
            }
        }
        // Compressor: the AU has no «ratio»; its «head room» is how far above the threshold the output
        // keeps rising. ratio r ≈ headroom = 40 / r (3:1 ≈ 13 dB… tuned to what sounds like 3:1 on voice: 6 dB)
        if c.compressorOn {
            let headroom = Float(max(0.5, min(40, 18 / max(1, c.ratio))))
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, Float(c.threshold), 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, headroom, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, Float(c.attack), 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, Float(c.release), 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, Float(c.makeup), 0)
        } else {
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, 0, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 40, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 0, 0)
        }
        // Soft gate: 1:2 expansion below the threshold
        if c.gateOn {
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, Float(c.gateThreshold), 0)
        } else {
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 1, 0)
            AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -120, 0)
        }
        // Limiter: when off the ceiling is raised so it doesn't act
        AudioUnitSetParameter(lim, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, c.limiterOn ? 0 : -0.01, 0)
        dsOn = c.deesserOn
        let a = Float(max(0, min(1, c.deesserAmount)))
        dsFloor = 1 - 0.75 * a            // down to −12 dB
        dsThr = 0.08 - 0.06 * a           // more amount = acts earlier
    }

    // MARK: Process a block (audio thread)

    func render(into list: UnsafeMutablePointer<AudioBufferList>, frames: UInt32, sampleTime: Double, timelineTime: Double? = nil) -> OSStatus {
        guard prepared, let lim = limUnit else { return noErr }
        // A/B: with «Sin procesar» (Bypass) on the audio passes as-is (the buffer already carries the source)
        if VoiceChainRegistry.shared.bypassAll { return noErr }
        if os_unfair_lock_trylock(&lock) {
            if let p = pending { pending = nil; os_unfair_lock_unlock(&lock); applyNow(p); automated = p.hasAutomation } else { os_unfair_lock_unlock(&lock) }
        }
        // Automation: parameters that have points follow their curve at this episode second
        if automated, let t = timelineTime {
            let c = settings
            if let eqU = eqUnit, let comp = compUnit {
                for (param, _) in c.automation {
                    guard let v = c.value(of: param, at: t) else { continue }
                    switch param {
                    case ChainSettings.compThreshold: AudioUnitSetParameter(comp, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, Float(v), 0)
                    case ChainSettings.compRatio: AudioUnitSetParameter(comp, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, Float(max(0.5, min(40, 18 / max(1, v)))), 0)
                    case ChainSettings.compMakeup: AudioUnitSetParameter(comp, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, Float(v), 0)
                    case ChainSettings.gateThreshold: AudioUnitSetParameter(comp, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, Float(v), 0)
                    case ChainSettings.deesserAmount:
                        let a = Float(max(0, min(1, v))); dsFloor = 1 - 0.75 * a; dsThr = 0.08 - 0.06 * a
                    default:
                        let parts = param.split(separator: ".")
                        guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
                              let i = c.bands.prefix(ChainSettings.maxBands).firstIndex(where: { $0.id == id }) else { continue }
                        let b = UInt32(i)
                        if parts[2] == "gain" { AudioUnitSetParameter(eqU, kAUNBandEQParam_Gain + b, kAudioUnitScope_Global, 0, Float(max(-24, min(24, v))), 0) }
                        else if parts[2] == "freq" { AudioUnitSetParameter(eqU, kAUNBandEQParam_Frequency + b, kAudioUnitScope_Global, 0, Float(max(20, min(20_000, v))), 0) }
                    }
                }
            }
        }
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        let st = AudioUnitRender(lim, &flags, &ts, 0, frames, list)
        if st == noErr, dsOn { deess(list, frames: Int(frames)) }
        return st
    }

    /// Band de-esser: splits off what's above 5 kHz, follows its envelope and, when it hisses,
    /// lowers only that part. The rest of the voice isn't touched.
    private func deess(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let thr = dsThr, floorGain = dsFloor
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

/// Live chains per person: the preview and a running export can each have their own;
/// when a control changes they're all updated (dead ones are discarded by themselves).
final class VoiceChainRegistry: ObservableObject, @unchecked Sendable {
    static let shared = VoiceChainRegistry()
    /// Instant A/B: true = no voice chain processes (you hear the recording as-is, at the same volume).
    /// Only affects playback; the export always processes.
    @Published var bypassAll = false
    private var lock = os_unfair_lock()
    private var chains: [Int: [WeakChain]] = [:]
    private struct WeakChain { weak var chain: VoiceChain? }

    func register(_ chain: VoiceChain, lane: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        chains[lane] = (chains[lane] ?? []).filter { $0.chain != nil } + [WeakChain(chain: chain)]
    }

    func update(lane: Int, _ c: ChainSettings) {
        os_unfair_lock_lock(&lock)
        let list = (chains[lane] ?? []).compactMap(\.chain)
        os_unfair_lock_unlock(&lock)
        for ch in list { ch.update(c) }
    }
    func update(lane: Int, _ eq: VoiceEQ) { update(lane: lane, ChainSettings.preset(eq)) }
}
