import AVFoundation
import MediaToolbox
import QuartzCore

/// Engancha la cadena de voz de una persona a su pista dentro de la mezcla (`AVAudioMix`), antes del
/// volumen de la mezcla (como un insert pre-fader). El mismo tap sirve en la vista previa (AVPlayer) y
/// en el export (AVAssetExportSession): por eso lo que se oye es lo que sale.
///
/// También mide el nivel de lo que pasa, para el medidor del timeline (`recent`), como hacía `LevelTap`.
final class ChainTap: @unchecked Sendable, LoudnessSource {
    let chain: VoiceChain
    let laneId: Int
    let loudness = LoudnessAccumulator()
    /// El tap creado con makeProcessor (para reconocerlo en la mezcla).
    var processor: MTAudioProcessingTap?
    func recentPower() -> (power: Double, mediaTime: Double, stamp: CFTimeInterval)? { loudness.recent() }
    private var sampleTime: Double = 0
    private var maxFrames: UInt32 = 4096

    // Medidor
    private var lock = os_unfair_lock()
    private var level: Float = -120
    private var stamp: CFTimeInterval = 0

    /// Cómo pasar del segundo del video (lo que ve el tap) al segundo del episodio (la automatización).
    private let keep: [EditEngine.Span]
    private let introDuration: Double

    /// Panorama (−1…1), aplicado después de la cadena con potencia constante; solo hace algo con dos canales.
    var pan: Double = 0

    init(laneId: Int, settings: ChainSettings, keep: [EditEngine.Span] = [], introDuration: Double = 0) {
        self.laneId = laneId
        self.keep = keep
        self.introDuration = introDuration
        chain = VoiceChain(settings: settings)
        VoiceChainRegistry.shared.register(chain, lane: laneId)
    }

    /// Segundo del episodio para un segundo del video final (nil si no hay mapa).
    private func timelineTime(output: Double) -> Double? {
        guard !keep.isEmpty else { return nil }
        return EditEngine.toTimeline(max(0, output - introDuration), keep: keep)
    }
    private var sampleRate: Double = 48_000

    /// Nivel reciente en dB, o nil si hace más de `maxAge` s que no pasa audio.
    func recent(maxAge: Double = 0.3) -> Float? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return CACurrentMediaTime() - stamp <= maxAge ? level : nil
    }

    private func measure(_ list: UnsafeMutablePointer<AudioBufferList>) {
        var sum: Double = 0, count = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let f = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { sum += Double(f[i] * f[i]) }
            count += n
        }
        guard count > 0 else { return }
        let rms = sqrt(sum / Double(count))
        let db = rms > 0 ? Float(20 * log10(rms)) : -120
        os_unfair_lock_lock(&lock)
        let now = CACurrentMediaTime()
        let fall = Float(now - stamp) * 20
        level = stamp == 0 ? db : max(db, level - fall)
        stamp = now
        os_unfair_lock_unlock(&lock)
    }

    // El Audio Unit de entrada pide audio: le copiamos el bloque que ya pedimos a la pista en `process`
    private var sourceList: UnsafeMutablePointer<AudioBufferList>?
    private var sourceFrames: CMItemCount = 0
    private static let pull: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let me = Unmanaged<ChainTap>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData, let src = me.sourceList else { return noErr }
        let dst = UnsafeMutableAudioBufferListPointer(ioData)
        let from = UnsafeMutableAudioBufferListPointer(src)
        for (i, buf) in dst.enumerated() {
            guard let d = buf.mData else { continue }
            let want = Int(buf.mDataByteSize)
            if i < from.count, let s = from[i].mData {
                let have = min(want, Int(me.sourceFrames) * MemoryLayout<Float>.size, Int(from[i].mDataByteSize))
                memcpy(d, s, have)
                if have < want { memset(d + have, 0, want - have) }
            } else {
                memset(d, 0, want)
            }
        }
        return noErr
    }

    /// El procesador para `AVMutableAudioMixInputParameters.audioTapProcessor`.
    func makeProcessor() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                let me = Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.maxFrames = UInt32(maxFrames)
                me.sampleTime = 0
                me.sampleRate = format.pointee.mSampleRate > 0 ? format.pointee.mSampleRate : 48_000
                me.loudness.prepare(sampleRate: me.sampleRate, channels: Int(format.pointee.mChannelsPerFrame))
                me.chain.prepare(format: format.pointee, maxFrames: UInt32(maxFrames))
                me.chain.setInput(ChainTap.pull, refCon: MTAudioProcessingTapGetStorage(tap))
            },
            unprepare: { tap in
                Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().chain.teardown()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let me = Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                // 1) El audio de la pista y en qué segundo del video va
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let tl = range.start.isValid ? me.timelineTime(output: range.start.seconds) : nil
                // 2) Por la cadena (el AU de entrada copia de este mismo bloque)
                me.sourceList = bufferList
                me.sourceFrames = framesOut.pointee
                let st = me.chain.render(into: bufferList, frames: UInt32(frames), sampleTime: me.sampleTime, timelineTime: tl)
                me.sourceList = nil
                if st != noErr {
                    // Si la cadena falla, el audio ya está tal cual en el buffer: nunca se deja la pista muda
                    _ = st
                }
                me.sampleTime += Double(frames)
                // Panorama de conversación: ganancias L/R de potencia constante sobre el buffer ya procesado
                if abs(me.pan) > 0.001 {
                    let list = UnsafeMutableAudioBufferListPointer(bufferList)
                    let theta = (me.pan + 1) / 2 * Double.pi / 2
                    let gL = Float(cos(theta)) * Float(2).squareRoot(), gR = Float(sin(theta)) * Float(2).squareRoot()
                    let n = Int(framesOut.pointee)
                    if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
                        let lp = l.assumingMemoryBound(to: Float.self), rp = r.assumingMemoryBound(to: Float.self)
                        for i in 0..<n { lp[i] *= gL; rp[i] *= gR }
                    } else if list.count == 1, list[0].mNumberChannels == 2, let d = list[0].mData {
                        let p = d.assumingMemoryBound(to: Float.self)
                        for i in 0..<n { p[2 * i] *= gL; p[2 * i + 1] *= gR }
                    }
                }
                me.measure(bufferList)
                me.loudness.add(bufferList, frames: Int(framesOut.pointee), mediaTime: range.start.isValid ? range.start.seconds : 0)
            })
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        if err != noErr {
            Unmanaged<ChainTap>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}
