import AVFoundation
import MediaToolbox
import QuartzCore

/// Engancha la cadena de voz de una persona a su pista dentro de la mezcla (`AVAudioMix`), antes del
/// volumen de la mezcla (como un insert pre-fader). El mismo tap sirve en la vista previa (AVPlayer) y
/// en el export (AVAssetExportSession): por eso lo que se oye es lo que sale.
///
/// También mide el nivel de lo que pasa, para el medidor del timeline (`recent`), como hacía `LevelTap`.
final class ChainTap: @unchecked Sendable {
    let chain: VoiceChain
    let laneId: Int
    private var sampleTime: Double = 0
    private var currentTap: MTAudioProcessingTap?
    private var maxFrames: UInt32 = 4096

    // Medidor
    private var lock = os_unfair_lock()
    private var level: Float = -120
    private var stamp: CFTimeInterval = 0

    init(laneId: Int, settings: VoiceEQ) {
        self.laneId = laneId
        chain = VoiceChain(settings: settings)
        VoiceChainRegistry.shared.register(chain, lane: laneId)
    }

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

    // El Audio Unit de entrada pide audio: se lo damos de la pista
    private static let pull: AURenderCallback = { refCon, flags, _, _, frames, ioData in
        let me = Unmanaged<ChainTap>.fromOpaque(refCon).takeUnretainedValue()
        guard let tap = me.currentTap, let ioData else { return noErr }
        var got: CMItemCount = 0
        var tapFlags = MTAudioProcessingTapFlags()
        let st = MTAudioProcessingTapGetSourceAudio(tap, CMItemCount(frames), ioData, &tapFlags, nil, &got)
        if st == noErr, got < CMItemCount(frames) {
            // Fin de la pista: lo que falta va en silencio
            for buf in UnsafeMutableAudioBufferListPointer(ioData) {
                guard let d = buf.mData else { continue }
                let bytes = Int(got) * MemoryLayout<Float>.size
                if bytes < Int(buf.mDataByteSize) { memset(d + bytes, 0, Int(buf.mDataByteSize) - bytes) }
            }
        }
        return st
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
                me.chain.prepare(format: format.pointee, maxFrames: UInt32(maxFrames))
                me.chain.setInput(ChainTap.pull, refCon: MTAudioProcessingTapGetStorage(tap))
            },
            unprepare: { tap in
                Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().chain.teardown()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let me = Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.currentTap = tap
                let st = me.chain.render(into: bufferList, frames: UInt32(frames), sampleTime: me.sampleTime)
                me.currentTap = nil
                if st != noErr {
                    // Si la cadena falla, pasa el audio tal cual: nunca dejar la pista muda
                    _ = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                } else {
                    framesOut.pointee = frames
                }
                me.sampleTime += Double(frames)
                me.measure(bufferList)
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
