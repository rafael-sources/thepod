import AVFoundation

/// Remove clicks and mouth smacks (no AI): a click is an abrupt jump of very short duration (under 2.5 ms).
/// The signal's second difference is watched against its recent typical level; when it spikes, that bit
/// is replaced by a line between the previous and next healthy samples. The voice isn't touched.
///
/// Works with a 256-sample lookahead (5 ms at 48 kHz) to see the end of the click before deciding.
final class DeClicker {
    static let lookahead = 256
    static let maxClick = 120            // samples: 2.5 ms at 48 kHz
    /// Sensitivity 0…1: how many times above the typical level the jump must go (from 14× to 6×).
    var amount: Float = 0.5
    private var threshold: Float { 14 - 8 * amount }

    private final class Channel {
        var ring = [Float](repeating: 0, count: lookahead + maxClick + 8)
        var w = 0                         // write
        var filled = 0
        var ema: Float = 1e-4             // typical level of |d2|
        var prev1: Float = 0, prev2: Float = 0
        var inClick = -1                  // position (in absolute samples) where the click started, or −1
        var count = 0                     // total samples in
    }
    private var channels: [Channel] = []
    private(set) var clicks = 0

    func prepare(channels n: Int) { channels = (0..<max(1, n)).map { _ in Channel() }; clicks = 0 }
    var latency: Int { Self.lookahead }

    /// Processes in place (output delayed `latency` samples).
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let thr = threshold
        var ci = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData, ci < channels.count else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let cnt = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            let c = channels[ci]
            let size = c.ring.count
            for i in 0..<cnt {
                let x = p[i]
                // detection on the incoming sample
                let d2 = abs(x - 2 * c.prev1 + c.prev2)
                // The first 50 ms only learn the typical level; after that, a click is what exceeds it many times over.
                // During a peak learning is slow (a sustained change isn't a click and must be absorbed).
                let warm = c.count < 2400
                let isSpike = !warm && d2 > thr * c.ema && d2 > 1e-3
                c.ema += (warm ? 0.01 : isSpike ? 0.0003 : 0.002) * (d2 - c.ema)
                c.prev2 = c.prev1; c.prev1 = x
                c.ring[c.w] = x
                if isSpike {
                    if c.inClick < 0 { c.inClick = c.count }
                } else if c.inClick >= 0 {
                    // click ended: from inClick−2 to the current (healthy) sample, if short, it's interpolated in the ring
                    let start = max(0, c.inClick - 2), end = c.count          // [start, end) is replaced
                    if end - start <= Self.maxClick, start >= 1, end - start < Self.lookahead - 2 {
                        let a = Self.idx(c.w, c.count, start - 1, size), b = Self.idx(c.w, c.count, end, size)
                        let va = c.ring[a], vb = c.ring[b]
                        let len = end - start
                        for k in 0..<len {
                            let j = Self.idx(c.w, c.count, start + k, size)
                            c.ring[j] = va + (vb - va) * Float(k + 1) / Float(len + 1)
                        }
                        clicks += 1
                    }
                    c.inClick = -1
                } else if c.inClick >= 0, c.count - c.inClick > Self.maxClick {
                    c.inClick = -1                                        // too long: it wasn't a click
                }
                // output: the sample from `lookahead` ago
                let outIdx = (c.w - Self.lookahead + size) % size
                p[i] = c.filled >= Self.lookahead ? c.ring[outIdx] : 0
                c.w = (c.w + 1) % size
                c.count += 1
                if c.filled < size { c.filled += 1 }
            }
            ci += 1
        }
    }

    /// Ring index of absolute sample `abs` (the last written is `count` at position `w`).
    private static func idx(_ w: Int, _ count: Int, _ abs: Int, _ size: Int) -> Int {
        let back = count - abs
        return ((w - back) % size + size) % size
    }
}
