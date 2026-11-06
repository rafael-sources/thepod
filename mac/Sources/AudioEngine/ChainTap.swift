import AVFoundation
import MediaToolbox
import QuartzCore

/// Hooks a person's voice chain into their track inside the mix (`AVAudioMix`), before the
/// mix volume (like a pre-fader insert). The same tap serves the preview (AVPlayer) and
/// the export (AVAssetExportSession): that's why what you hear is what comes out.
///
/// Also measures the level of what passes, for the timeline meter (`recent`), as `LevelTap` did.
final class ChainTap: @unchecked Sendable, LoudnessSource {
    let chain: VoiceChain
    let laneId: Int
    let loudness = LoudnessAccumulator()
    /// The tap created with makeProcessor (to recognize it in the mix).
    var processor: MTAudioProcessingTap?
    func recentPower() -> (power: Double, mediaTime: Double, stamp: CFTimeInterval)? { loudness.recent() }
    private var sampleTime: Double = 0
    private var maxFrames: UInt32 = 4096

    // Meter
    private var lock = os_unfair_lock()
    private var level: Float = -120
    private var stamp: CFTimeInterval = 0

    /// How to go from the video second (what the tap sees) to the episode second (the automation).
    private let keep: [EditEngine.Span]
    private let introDuration: Double

    /// Pan (−1…1), applied after the chain with constant power; only does something with two channels.
    var pan: Double = 0
    /// Noise-print reduction, before the chain (nil = off).
    var noise: NoiseReducer?
    /// De-click, before the chain (nil = off).
    var declick: DeClicker?

    init(laneId: Int, settings: ChainSettings, keep: [EditEngine.Span] = [], introDuration: Double = 0) {
        self.laneId = laneId
        self.keep = keep
        self.introDuration = introDuration
        chain = VoiceChain(settings: settings)
        VoiceChainRegistry.shared.register(chain, lane: laneId)
    }

    /// Episode second for a second of the final video (nil if there's no map).
    private func timelineTime(output: Double) -> Double? {
        guard !keep.isEmpty else { return nil }
        return EditEngine.toTimeline(max(0, output - introDuration), keep: keep)
    }
    private var sampleRate: Double = 48_000

    /// Recent level in dB, or nil if no audio has passed for more than `maxAge` s.
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

    // The input Audio Unit asks for audio: we copy it the block we already pulled from the track in `process`
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

    /// The processor for `AVMutableAudioMixInputParameters.audioTapProcessor`.
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
                me.noise?.prepare(channels: Int(format.pointee.mChannelsPerFrame))
                me.declick?.prepare(channels: Int(format.pointee.mChannelsPerFrame))
                me.chain.prepare(format: format.pointee, maxFrames: UInt32(maxFrames))
                me.chain.setInput(ChainTap.pull, refCon: MTAudioProcessingTapGetStorage(tap))
            },
            unprepare: { tap in
                Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().chain.teardown()
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let me = Unmanaged<ChainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                // 1) The track's audio and at which video second it goes
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let tl = range.start.isValid ? me.timelineTime(output: range.start.seconds) : nil
                // 1b) Noise-print reduction, on the source, before the chain
                if !VoiceChainRegistry.shared.bypassAll {
                    me.declick?.process(bufferList, frames: Int(framesOut.pointee))
                    me.noise?.process(bufferList, frames: Int(framesOut.pointee))
                }
                // 2) Through the chain (the input AU copies from this same block)
                me.sourceList = bufferList
                me.sourceFrames = framesOut.pointee
                let st = me.chain.render(into: bufferList, frames: UInt32(frames), sampleTime: me.sampleTime, timelineTime: tl)
                me.sourceList = nil
                if st != noErr {
                    // If the chain fails, the audio is already as-is in the buffer: the track is never left muted
                    _ = st
                }
                me.sampleTime += Double(frames)
                // Conversation panning: constant-power L/R gains on the already processed buffer
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
