import Accelerate
import AVFoundation

/// Noise-print reduction (no AI): spectral subtraction with a per-band gate. The noise «print» is taken
/// —the mean spectrum of a second where the person isn't speaking— and, in each block, bands that don't clearly
/// exceed that print are attenuated. Constant noise (air, fan, hum) drops; the voice stays.
///
/// 1024-sample STFT with a 256 hop and root-Hann window on input and output (exact
/// reconstruction). Latency: 1024 samples (21 ms at 48 kHz), the same for the whole episode.
final class NoiseReducer {
    static let n = 1024
    static let hop = 256
    static let bins = n / 2 + 1

    /// The print: mean magnitude per band (0…bins) of a voiceless chunk.
    static func profile(samples: UnsafePointer<Float>, count: Int) -> [Float]? {
        guard count >= n else { return nil }
        let fft = FFT()
        var acc = [Float](repeating: 0, count: bins)
        var frames = 0
        var pos = 0
        var frame = [Float](repeating: 0, count: n)
        while pos + n <= count {
            for i in 0..<n { frame[i] = samples[pos + i] * fft.window[i] }
            let mag = fft.magnitudes(frame)
            for k in 0..<bins { acc[k] += mag[k] }
            frames += 1; pos += hop
        }
        guard frames > 0 else { return nil }
        return acc.map { $0 / Float(frames) }
    }

    /// Print of a file between `start` and `start + seconds` (mixed to mono).
    static func profile(url: URL, start: Double, seconds: Double = 1) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat, sr = fmt.sampleRate, ch = Int(fmt.channelCount)
        let count = AVAudioFrameCount(sr * seconds)
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else { return nil }
        f.framePosition = AVAudioFramePosition(start * sr)
        guard (try? f.read(into: b, frameCount: count)) != nil, b.frameLength > 0, let d = b.floatChannelData else { return nil }
        var mono = [Float](repeating: 0, count: Int(b.frameLength))
        for i in 0..<mono.count { var v: Float = 0; for c in 0..<ch { v += d[c][i] }; mono[i] = v / Float(ch) }
        return mono.withUnsafeBufferPointer { profile(samples: $0.baseAddress!, count: $0.count) }
    }

    // MARK: Real-time processing

    final class FFT {
        let setup: FFTSetup
        let window: [Float]
        /// How much the window (input × output) sums overlapped every `hop`: with Hann and hop n/4 it's 1.5.
        let olaGain: Float
        private var real = [Float](repeating: 0, count: n / 2)
        private var imag = [Float](repeating: 0, count: n / 2)
        init() {
            setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: n)
            vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            window = w.map { sqrt($0) }       // root Hann on input and output
            var g: Float = 0
            var i = 0
            while i < n { g += w[i]; i += hop }
            olaGain = g
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// Magnitudes of an already windowed block.
        func magnitudes(_ frame: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: bins)
            forward(frame) { re, im in
                for k in 0..<(n / 2) { out[k] = sqrt(re[k] * re[k] + im[k] * im[k]) }
                out[n / 2] = abs(im[0])      // Nyquist comes packed in imag[0]
                out[0] = abs(re[0])
            }
            return out
        }

        /// Packed real FFT; `body` receives re/im (n/2) with DC in re[0] and Nyquist in im[0].
        func forward(_ frame: [Float], _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                    body(rp.baseAddress!, ip.baseAddress!)
                }
            }
        }

        /// Inverse of what's left in re/im after `forward` (already modified), into the output block (n samples).
        func inverse(into out: inout [Float]) {
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_INVERSE))
                    out.withUnsafeMutableBufferPointer { op in
                        op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                            vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(n / 2))
                        }
                    }
                    // vDSP scales by 2n round-trip with zrip; plus the window sum
                    var scale = Float(1) / (Float(2 * n) * olaGain)
                    vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
                }
            }
        }
    }

    /// One channel: accumulated input, overlap-add output.
    private final class Channel {
        var inBuf = [Float](repeating: 0, count: n)      // last n samples (ring)
        var inPos = 0                                    // where the next sample goes in the ring
        var outBuf = [Float](repeating: 0, count: n)     // pending overlap-add
        var pendingIn = 0                                // new samples since the last block
        var ready: [Float] = []                          // output ready to deliver
        var readyIdx = 0
        var gain = [Float](repeating: 1, count: bins)    // smoothed gains per band
        var primed = false
    }

    private let fft = FFT()
    private var channels: [Channel] = []
    private var frame = [Float](repeating: 0, count: n)
    private var block = [Float](repeating: 0, count: n)
    /// Print and how much to reduce (0…1 → from 6 to 18 dB max attenuation and threshold from 1.5× to 3× the print).
    var profile: [Float]?
    var amount: Float = 0.6

    func prepare(channels count: Int) { channels = (0..<max(1, count)).map { _ in Channel() } }
    /// Total latency: the output queue is primed with one hop (so a sample is never missing) and the block takes
    /// n − hop to complete: n samples (21 ms at 48 kHz).
    var latency: Int { Self.n }

    /// Processes in place `frames` samples of each buffer channel (output delayed `latency` samples).
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard let prof = profile, !channels.isEmpty else { return }
        let floorGain = powf(10, -(6 + 12 * amount) / 20)
        let over: Float = 1.5 + 1.5 * amount
        var ci = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData, ci < channels.count else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let cnt = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            let c = channels[ci]
            if !c.primed { c.ready = [Float](repeating: 0, count: Self.hop); c.primed = true }
            for i in 0..<cnt {
                // a sample enters the ring
                c.inBuf[c.inPos] = p[i]; c.inPos = (c.inPos + 1) % Self.n; c.pendingIn += 1
                if c.pendingIn >= Self.hop {
                    c.pendingIn = 0
                    // windowed block (in order, from the oldest sample) → spectrum → gains → inverse → overlap-add
                    for k in 0..<Self.n { frame[k] = c.inBuf[(c.inPos + k) % Self.n] * fft.window[k] }
                    fft.forward(frame) { re, im in
                        for k in 0..<(Self.n / 2) {
                            let mag = sqrt(re[k] * re[k] + im[k] * im[k])
                            let noise = prof[k] * over
                            var g: Float = mag > noise ? 1 - noise / max(mag, 1e-9) : 0
                            g = max(floorGain, g)
                            // smoothing: drops fast, rises fast too but without jumps between blocks
                            c.gain[k] = 0.5 * c.gain[k] + 0.5 * g
                            if k == 0 { re[0] *= c.gain[0]; im[0] *= c.gain[Self.n / 2] } else { re[k] *= c.gain[k]; im[k] *= c.gain[k] }
                        }
                    }
                    fft.inverse(into: &block)
                    for k in 0..<Self.n { c.outBuf[k] += block[k] * fft.window[k] }
                    // the first hop samples are already complete
                    c.ready.append(contentsOf: c.outBuf[0..<Self.hop])
                    c.outBuf.removeFirst(Self.hop); c.outBuf.append(contentsOf: [Float](repeating: 0, count: Self.hop))
                }
            }
            // deliver: whatever is ready (delayed); if short, zeros
            for i in 0..<cnt {
                if c.readyIdx < c.ready.count { p[i] = c.ready[c.readyIdx]; c.readyIdx += 1 } else { p[i] = 0 }
            }
            if c.readyIdx > 8192 { c.ready.removeFirst(c.readyIdx); c.readyIdx = 0 }
            ci += 1
        }
    }
}
