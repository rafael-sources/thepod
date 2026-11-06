import Foundation
import AVFoundation
import LiveKit

/// Live auto-mute: when you're not speaking, the room gets your microphone 18 dB lower
/// (keys, dog, noises). Runs inside LiveKit's audio processing, only for what's sent.
/// Before touching the audio it hands the unprocessed copy to the recording (`tap`), which thus stays intact.
final class LiveGate: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    static let shared = LiveGate()

    private let lock = NSLock()
    private var _on = true
    private var _tap: AudioRenderer?
    private var _makeup: Float = 1
    /// Microphone test adjustment, in dB (0 = no change). Only for what the room hears.
    var makeupDb: Float {
        get { lock.withLock { 20 * log10(_makeup) } }
        set { lock.withLock { _makeup = powf(10, max(-12, min(18, newValue)) / 20) } }
    }
    var on: Bool {
        get { lock.withLock { _on } }
        set { lock.withLock { _on = newValue } }
    }
    /// Who receives the raw audio (the recording with speakers). nil = nobody.
    var tap: AudioRenderer? {
        get { lock.withLock { _tap } }
        set { lock.withLock { _tap = newValue } }
    }

    // Gate state (only touched from the audio thread)
    private var gain: Float = 1
    private var open = true
    private var lastLoud: TimeInterval = 0
    private let openDB: Float = -42, closeDB: Float = -48, low: Float = 0.125, holdSec: TimeInterval = 0.35

    var audioProcessingName: String { "thepod.autosilencio" }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        gain = 1; open = true; lastLoud = 0
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let (isOn, tap, makeup) = lock.withLock { (_on, _tap, _makeup) }
        if let tap, let pcm = audioBuffer.toAVAudioPCMBuffer() { tap.render(pcmBuffer: pcm) }

        let frames = audioBuffer.frames, channels = audioBuffer.channels
        guard frames > 0, channels > 0 else { return }
        // First the microphone test adjustment (capped so it doesn't clip), then the gate.
        if makeup != 1 {
            for ch in 0..<channels {
                let buf = audioBuffer.rawBuffer(forChannel: ch)
                for i in 0..<frames { buf[i] = max(-32767, min(32767, buf[i] * makeup)) }
            }
        }
        // Level (samples come in Int16 scale)
        var sum: Float = 0
        let c0 = audioBuffer.rawBuffer(forChannel: 0)
        for i in 0..<frames { let v = c0[i] / 32768; sum += v * v }
        let db = 20 * log10(sqrt(sum / Float(frames)) + 1e-9)
        let now = ProcessInfo.processInfo.systemUptime
        if !isOn { open = true }
        else if db > openDB { lastLoud = now; open = true }
        else if db < closeDB && open && now - lastLoud > holdSec { open = false }

        let target: Float = open ? 1 : low
        if target == 1 && gain == 1 { return }   // nothing to change
        // Ramp within the block: opens fast (~15 ms), closes gently (~60 ms)
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
