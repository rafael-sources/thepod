import Accelerate
import AVFoundation

/// Reducción de ruido por huella (sin IA): resta espectral con compuerta por banda. Se toma la «huella» del ruido
/// —el espectro medio de un segundo en que la persona no habla— y, en cada bloque, las bandas que no superan
/// claramente esa huella se atenúan. Ruido constante (aire, ventilador, zumbido) baja; la voz queda.
///
/// STFT de 1024 muestras con salto de 256 y ventana raíz de Hann a la entrada y a la salida (reconstrucción
/// exacta). Retardo: 768 muestras (16 ms a 48 kHz), el mismo para todo el episodio.
final class NoiseReducer {
    static let n = 1024
    static let hop = 256
    static let bins = n / 2 + 1

    /// La huella: magnitud media por banda (0…bins) de un trozo sin voz.
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

    /// Huella de un archivo entre `start` y `start + seconds` (mezclado a mono).
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

    // MARK: Proceso en tiempo real

    final class FFT {
        let setup: FFTSetup
        let window: [Float]
        private var real = [Float](repeating: 0, count: n / 2)
        private var imag = [Float](repeating: 0, count: n / 2)
        init() {
            setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: n)
            vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
            window = w.map { sqrt($0) }       // raíz de Hann: entrada × salida = Hann, y con salto n/4 suma 1
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        /// Magnitudes de un bloque ya ventaneado.
        func magnitudes(_ frame: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: bins)
            forward(frame) { re, im in
                for k in 0..<(n / 2) { out[k] = sqrt(re[k] * re[k] + im[k] * im[k]) }
                out[n / 2] = abs(im[0])      // Nyquist viene empaquetado en imag[0]
                out[0] = abs(re[0])
            }
            return out
        }

        /// FFT real empaquetada; `body` recibe re/im (n/2) con DC en re[0] y Nyquist en im[0].
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

        /// Inversa de lo que quedó en re/im tras `forward` (ya modificado), al bloque de salida (n muestras).
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
                    var scale = Float(1) / Float(2 * n)     // vDSP escala por 2n en ida y vuelta
                    vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
                }
            }
        }
    }

    /// Un canal: entrada acumulada, salida por solape-suma.
    private final class Channel {
        var inBuf = [Float](repeating: 0, count: n)      // últimas n muestras (anillo)
        var inPos = 0                                    // dónde va la próxima muestra en el anillo
        var outBuf = [Float](repeating: 0, count: n)     // solape-suma pendiente
        var pendingIn = 0                                // muestras nuevas desde el último bloque
        var ready: [Float] = []                          // salida lista para entregar
        var readyIdx = 0
        var gain = [Float](repeating: 1, count: bins)    // ganancias suavizadas por banda
        var primed = false
    }

    private let fft = FFT()
    private var channels: [Channel] = []
    private var frame = [Float](repeating: 0, count: n)
    private var block = [Float](repeating: 0, count: n)
    /// Huella y cuánto reducir (0…1 → de 6 a 18 dB de atenuación tope y umbral de 1,5× a 3× la huella).
    var profile: [Float]?
    var amount: Float = 0.6

    func prepare(channels count: Int) { channels = (0..<max(1, count)).map { _ in Channel() } }
    var latency: Int { Self.n - Self.hop }

    /// Procesa en sitio `frames` muestras de cada canal del buffer (salida retardada `latency` muestras).
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
            if !c.primed { c.ready = [Float](repeating: 0, count: latency); c.primed = true }
            for i in 0..<cnt {
                // entra una muestra en el anillo
                c.inBuf[c.inPos] = p[i]; c.inPos = (c.inPos + 1) % Self.n; c.pendingIn += 1
                if c.pendingIn >= Self.hop {
                    c.pendingIn = 0
                    // bloque ventaneado (en orden, desde la muestra más vieja) → espectro → ganancias → inversa → solape-suma
                    for k in 0..<Self.n { frame[k] = c.inBuf[(c.inPos + k) % Self.n] * fft.window[k] }
                    fft.forward(frame) { re, im in
                        for k in 0..<(Self.n / 2) {
                            let mag = sqrt(re[k] * re[k] + im[k] * im[k])
                            let noise = prof[k] * over
                            var g: Float = mag > noise ? 1 - noise / max(mag, 1e-9) : 0
                            g = max(floorGain, g)
                            // suavizado: baja rápido, sube rápido también pero sin saltos entre bloques
                            c.gain[k] = 0.5 * c.gain[k] + 0.5 * g
                            if k == 0 { re[0] *= c.gain[0]; im[0] *= c.gain[Self.n / 2] } else { re[k] *= c.gain[k]; im[k] *= c.gain[k] }
                        }
                    }
                    fft.inverse(into: &block)
                    for k in 0..<Self.n { c.outBuf[k] += block[k] * fft.window[k] }
                    // las primeras hop muestras ya están completas
                    c.ready.append(contentsOf: c.outBuf[0..<Self.hop])
                    c.outBuf.removeFirst(Self.hop); c.outBuf.append(contentsOf: [Float](repeating: 0, count: Self.hop))
                }
            }
            // entregar: lo que haya listo (retardado); si falta, ceros
            for i in 0..<cnt {
                if c.readyIdx < c.ready.count { p[i] = c.ready[c.readyIdx]; c.readyIdx += 1 } else { p[i] = 0 }
            }
            if c.readyIdx > 8192 { c.ready.removeFirst(c.readyIdx); c.readyIdx = 0 }
            ci += 1
        }
    }
}
