import AVFoundation

/// Quitar clics y chasquidos de boca (sin IA): un clic es un salto brusco de muy corta duración (menos de 2,5 ms).
/// Se vigila la segunda diferencia de la señal frente a su nivel típico reciente; cuando se dispara, ese trocito
/// se sustituye por una línea entre la muestra anterior y la siguiente sanas. La voz no se toca.
///
/// Trabaja con un adelanto de 256 muestras (5 ms a 48 kHz) para ver el final del clic antes de decidir.
final class DeClicker {
    static let lookahead = 256
    static let maxClick = 120            // muestras: 2,5 ms a 48 kHz
    /// Sensibilidad 0…1: cuántas veces por encima del nivel típico tiene que ir el salto (de 14× a 6×).
    var amount: Float = 0.5
    private var threshold: Float { 14 - 8 * amount }

    private final class Channel {
        var ring = [Float](repeating: 0, count: lookahead + maxClick + 8)
        var w = 0                         // escritura
        var filled = 0
        var ema: Float = 1e-4             // nivel típico de |d2|
        var prev1: Float = 0, prev2: Float = 0
        var inClick = -1                  // posición (en muestras absolutas) donde empezó el clic, o −1
        var count = 0                     // muestras totales entradas
    }
    private var channels: [Channel] = []
    private(set) var clicks = 0

    func prepare(channels n: Int) { channels = (0..<max(1, n)).map { _ in Channel() }; clicks = 0 }
    var latency: Int { Self.lookahead }

    /// Procesa en sitio (salida retardada `latency` muestras).
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
                // detección sobre la muestra que entra
                let d2 = abs(x - 2 * c.prev1 + c.prev2)
                let isSpike = d2 > thr * c.ema && d2 > 1e-3
                if !isSpike { c.ema += 0.002 * (d2 - c.ema) }          // el nivel típico no aprende de los clics
                c.prev2 = c.prev1; c.prev1 = x
                c.ring[c.w] = x
                if isSpike {
                    if c.inClick < 0 { c.inClick = c.count }
                } else if c.inClick >= 0 {
                    // terminó el clic: de inClick−2 hasta la muestra actual (sana), si es corto, se interpola en el anillo
                    let start = max(0, c.inClick - 2), end = c.count          // [start, end) se sustituye
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
                    c.inClick = -1                                        // demasiado largo: no era un clic
                }
                // salida: la muestra de hace `lookahead`
                let outIdx = (c.w - Self.lookahead + size) % size
                p[i] = c.filled >= Self.lookahead ? c.ring[outIdx] : 0
                c.w = (c.w + 1) % size
                c.count += 1
                if c.filled < size { c.filled += 1 }
            }
            ci += 1
        }
    }

    /// Índice en el anillo de la muestra absoluta `abs` (la última escrita es `count` en la posición `w`).
    private static func idx(_ w: Int, _ count: Int, _ abs: Int, _ size: Int) -> Int {
        let back = count - abs
        return ((w - back) % size + size) % size
    }
}
