import AVFoundation
import AudioToolbox

/// Apple's voice isolator (the same effect Final Cut uses, «AUSoundIsolation»): a neural network that
/// keeps the voice and removes keys, dog, street, fan. Works on the Mac, offline, on a file.
enum VoiceIsolation {
    private static let desc = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x766f6973 /* 'vois' */,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Whether this Mac has it (recent macOS).
    static var isAvailable: Bool {
        var d = desc
        return AudioComponentFindNext(nil, &d) != nil
    }

    enum Failure: LocalizedError {
        case unavailable, render
        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Esta Mac no trae el aislador de voz.")
            case .render: return String(localized: "No se pudo separar la voz del ruido.")
            }
        }
    }

    /// Processes `input` (WAV) and writes `output` (WAV). `wet` 0…1: how much of the isolated voice (the rest is the original).
    /// Compensates the effect's own latency so the voice stays in sync with the lips.
    static func process(input: URL, output: URL, wet: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isAvailable else { throw Failure.unavailable }
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: input)
            let fmt = file.processingFormat
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let iso = AVAudioUnitEffect(audioComponentDescription: desc)
            engine.attach(player); engine.attach(iso)
            engine.connect(player, to: iso, format: fmt)
            engine.connect(iso, to: engine.mainMixerNode, format: fmt)
            if let p = iso.auAudioUnit.parameterTree?.allParameters.first(where: { $0.displayName.lowercased().contains("wet") }) {
                p.value = AUValue(max(0, min(1, wet)) * 100)
            }
            let chunk: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: chunk)
            try engine.start()
            player.scheduleFile(file, at: nil)
            player.play()
            // The effect delivers the voice slightly late: those first samples are discarded and that much extra is processed at the end
            let latency = AVAudioFramePosition((iso.auAudioUnit.latency * fmt.sampleRate).rounded())
            let total = file.length + latency
            let out = try AVAudioFile(forWriting: output, settings: fmt.settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else { throw Failure.render }
            var skip = latency
            var last = Date.distantPast
            while engine.manualRenderingSampleTime < total {
                let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - engine.manualRenderingSampleTime))
                switch try engine.renderOffline(n, to: buf) {
                case .success:
                    if skip >= AVAudioFramePosition(buf.frameLength) {
                        skip -= AVAudioFramePosition(buf.frameLength)
                    } else if skip > 0 {
                        // Write only what comes after the latency
                        let rest = AVAudioFrameCount(AVAudioFramePosition(buf.frameLength) - skip)
                        if let tail = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: rest) {
                            tail.frameLength = rest
                            for ch in 0..<Int(buf.format.channelCount) {
                                if let s = buf.floatChannelData?[ch], let d = tail.floatChannelData?[ch] {
                                    d.update(from: s + Int(skip), count: Int(rest))
                                }
                            }
                            try out.write(from: tail)
                        }
                        skip = 0
                    } else {
                        try out.write(from: buf)
                    }
                case .error: throw Failure.render
                default: break
                }
                if Date().timeIntervalSince(last) > 0.25 {
                    last = Date()
                    progress(Double(engine.manualRenderingSampleTime) / Double(max(1, total)))
                }
            }
            engine.stop()
            progress(1)
        }.value
    }
}
