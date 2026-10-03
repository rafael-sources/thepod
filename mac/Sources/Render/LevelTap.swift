import AVFoundation
import MediaToolbox
import QuartzCore

/// Mide lo que realmente suena de una persona en la vista previa: se engancha a su pista de audio (después del
/// volumen, los fades, el silenciar a quien no habla, la línea de volumen y los pitidos) y guarda el nivel.
/// El medidor del timeline lo lee mientras se reproduce.
final class LevelTap: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var level: Float = -120         // dB, con caída suave
    private var stamp: CFTimeInterval = 0

    /// Nivel reciente en dB, o nil si hace más de `maxAge` segundos que no pasa audio (pausa, fuera de la pista).
    func recent(maxAge: Double = 0.3) -> Float? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return CACurrentMediaTime() - stamp <= maxAge ? level : nil
    }

    fileprivate func measure(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        var sum: Double = 0
        var count = 0
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
        // Sube al instante y baja suave (≈ 20 dB por segundo), como un medidor de verdad
        let fall = Float(now - stamp) * 20
        level = stamp == 0 ? db : max(db, level - fall)
        stamp = now
        os_unfair_lock_unlock(&lock)
    }

    /// El procesador para `AVMutableAudioMixInputParameters.audioTapProcessor` (después de los efectos de la mezcla).
    func makeProcessor() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<LevelTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: nil,
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<LevelTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .measure(bufferList, frames: framesOut.pointee)
            })
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        if err != noErr {
            Unmanaged<LevelTap>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}
