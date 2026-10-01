import Foundation
import AVFoundation
import LiveKit

/// Auto-silencio en vivo: cuando no hablas, a la sala le llega tu micrófono 18 dB más bajo
/// (teclas, perro, ruidos). Corre dentro del procesado de audio de LiveKit, solo para lo que se envía.
/// Antes de tocar el audio le pasa la copia sin procesar a la grabación (`tap`), que así queda intacta.
final class LiveGate: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    static let shared = LiveGate()

    private let lock = NSLock()
    private var _on = true
    private var _tap: AudioRenderer?
    var on: Bool {
        get { lock.withLock { _on } }
        set { lock.withLock { _on = newValue } }
    }
    /// Quien recibe el audio crudo (la grabación con parlantes). nil = nadie.
    var tap: AudioRenderer? {
        get { lock.withLock { _tap } }
        set { lock.withLock { _tap = newValue } }
    }

    // Estado de la puerta (solo se toca desde el hilo de audio)
    private var gain: Float = 1
    private var open = true
    private var lastLoud: TimeInterval = 0
    private let openDB: Float = -42, closeDB: Float = -48, low: Float = 0.125, holdSec: TimeInterval = 0.35

    var audioProcessingName: String { "thepod.autosilencio" }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        gain = 1; open = true; lastLoud = 0
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let (isOn, tap) = lock.withLock { (_on, _tap) }
        if let tap, let pcm = audioBuffer.toAVAudioPCMBuffer() { tap.render(pcmBuffer: pcm) }

        let frames = audioBuffer.frames, channels = audioBuffer.channels
        guard frames > 0, channels > 0 else { return }
        // Nivel (las muestras vienen en escala de Int16)
        var sum: Float = 0
        let c0 = audioBuffer.rawBuffer(forChannel: 0)
        for i in 0..<frames { let v = c0[i] / 32768; sum += v * v }
        let db = 20 * log10(sqrt(sum / Float(frames)) + 1e-9)
        let now = ProcessInfo.processInfo.systemUptime
        if !isOn { open = true }
        else if db > openDB { lastLoud = now; open = true }
        else if db < closeDB && open && now - lastLoud > holdSec { open = false }

        let target: Float = open ? 1 : low
        if target == 1 && gain == 1 { return }   // nada que cambiar
        // Rampa dentro del bloque: abre rápido (~15 ms), cierra suave (~60 ms)
        let step: Float = target > gain ? 1 / Float(max(1, frames)) * 0.66 : 1 / Float(max(1, frames)) * 0.16
        for ch in 0..<channels {
            let buf = audioBuffer.rawBuffer(forChannel: ch)
            var g = gain
            for i in 0..<frames {
                if g < target { g = min(target, g + step) } else if g > target { g = max(target, g - step) }
                buf[i] *= g
            }
            if ch == channels - 1 { gain = g }
        }
    }

    func audioProcessingRelease() {}
}
