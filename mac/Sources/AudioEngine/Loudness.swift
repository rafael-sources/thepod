import AVFoundation
import MediaToolbox
import QuartzCore

/// Filtro K (ITU-R BS.1770): estante alto de +4 dB alrededor de 1,7 kHz y paso alto a 38 Hz. Lo que pesa el
/// oído, para medir sonoridad (LUFS). Coeficientes de la norma para 48 kHz; para otra frecuencia se
/// recalculan con las fórmulas del Anexo.
struct KWeight {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0   // estante
    private var c0 = 1.0, c1 = 0.0, c2 = 0.0, d1 = 0.0, d2 = 0.0   // paso alto
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var u1 = 0.0, u2 = 0.0, w1 = 0.0, w2 = 0.0

    init(sampleRate fs: Double) {
        // Estante alto (pre-filtro)
        do {
            let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
            let K = tan(Double.pi * f0 / fs), Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
            let a0 = 1 + K / Q + K * K
            b0 = (Vh + Vb * K / Q + K * K) / a0
            b1 = 2 * (K * K - Vh) / a0
            b2 = (Vh - Vb * K / Q + K * K) / a0
            a1 = 2 * (K * K - 1) / a0
            a2 = (1 - K / Q + K * K) / a0
        }
        // Paso alto (RLB)
        do {
            let f0 = 38.13547087602444, Q = 0.5003270373238773
            let K = tan(Double.pi * f0 / fs)
            let a0 = 1 + K / Q + K * K
            c0 = 1 / a0; c1 = -2 / a0; c2 = 1 / a0
            d1 = 2 * (K * K - 1) / a0
            d2 = (1 - K / Q + K * K) / a0
        }
    }

    /// Potencia media (cuadrado) del bloque ya filtrado.
    mutating func meanSquare(_ x: UnsafePointer<Float>, _ n: Int) -> Double {
        var sum = 0.0
        for i in 0..<n {
            let v = Double(x[i])
            let s = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = s
            let h = c0 * s + c1 * u1 + c2 * u2 - d1 * w1 - d2 * w2
            u2 = u1; u1 = s; w2 = w1; w1 = h
            sum += h * h
        }
        return n > 0 ? sum / Double(n) : 0
    }
}

/// Lo que mide una fuente de la mezcla: potencia K de los últimos 400 ms y en qué segundo del video va.
protocol LoudnessSource: AnyObject {
    /// (potencia K media de los últimos 400 ms, segundo del video del último bloque, cuándo se midió)
    func recentPower() -> (power: Double, mediaTime: Double, stamp: CFTimeInterval)?
}

/// Acumula bloques por canal para una fuente; lo usan el tap de voz y el tap de solo medir.
final class LoudnessAccumulator: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var filters: [KWeight] = []
    private var ring: [(power: Double, frames: Int)] = []   // bloques recientes
    private var ringFrames = 0
    private var sampleRate = 48_000.0
    private var mediaTime = 0.0
    private var stamp: CFTimeInterval = 0

    func prepare(sampleRate: Double, channels: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        self.sampleRate = sampleRate
        filters = (0..<max(1, channels)).map { _ in KWeight(sampleRate: sampleRate) }
        ring = []; ringFrames = 0
    }

    func add(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, mediaTime: Double) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var power = 0.0
        var ch = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buf.mData, ch < filters.count else { continue }
            let n = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            power += filters[ch].meanSquare(data.assumingMemoryBound(to: Float.self), n)
            ch += 1
        }
        ring.append((power, frames)); ringFrames += frames
        let window = Int(sampleRate * 0.4)
        while ringFrames > window, let first = ring.first { ring.removeFirst(); ringFrames -= first.frames }
        self.mediaTime = mediaTime
        stamp = CACurrentMediaTime()
    }

    func recent() -> (power: Double, mediaTime: Double, stamp: CFTimeInterval)? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard ringFrames > 0 else { return nil }
        let p = ring.reduce(0.0) { $0 + $1.power * Double($1.frames) } / Double(ringFrames)
        return (p, mediaTime, stamp)
    }
}

/// Tap que solo mide (música, efectos, cortinas): no toca el audio.
final class MeterTap: @unchecked Sendable, LoudnessSource {
    let acc = LoudnessAccumulator()
    func recentPower() -> (power: Double, mediaTime: Double, stamp: CFTimeInterval)? { acc.recent() }

    func makeProcessor() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<MeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let me = Unmanaged<MeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.acc.prepare(sampleRate: format.pointee.mSampleRate, channels: Int(format.pointee.mChannelsPerFrame))
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
                let me = Unmanaged<MeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                me.acc.add(bufferList, frames: Int(framesOut.pointee), mediaTime: range.start.isValid ? range.start.seconds : 0)
            })
        var tap: MTAudioProcessingTap?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        if err != noErr { Unmanaged<MeterTap>.fromOpaque(callbacks.clientInfo!).release(); return nil }
        return tap
    }
}

/// La sonoridad de la mezcla en la vista previa: suma las potencias K de cada pista (cada una con el
/// volumen que la mezcla le da en ese segundo) y la convierte a LUFS. Es una estimación —las pistas
/// se suman como señales independientes, que para voces y música es lo normal—; la medida exacta
/// (EBU R128 sobre el archivo) se hace al exportar.
final class MixLoudness: @unchecked Sendable {
    struct Source { let tap: LoudnessSource; let gain: (Double) -> Double }
    private var lock = os_unfair_lock()
    private var sources: [Source] = []
    // Integrado con compuerta (desde que se empezó a reproducir / último reinicio)
    private var blocks: [Double] = []          // potencias de bloques de 400 ms cada 100 ms
    private var lastBlockStamp: CFTimeInterval = 0
    private var lastMediaTime: Double = -1

    func add(_ tap: LoudnessSource, gain: @escaping (Double) -> Double) {
        os_unfair_lock_lock(&lock); sources.append(Source(tap: tap, gain: gain)); os_unfair_lock_unlock(&lock)
    }

    func reset() { os_unfair_lock_lock(&lock); blocks = []; lastMediaTime = -1; os_unfair_lock_unlock(&lock) }

    /// Potencia K total ahora (solo fuentes que han sonado en los últimos 0,5 s).
    private func totalPower(now: CFTimeInterval) -> (power: Double, mediaTime: Double)? {
        var total = 0.0, any = false, mt = 0.0
        for s in sources {
            guard let r = s.tap.recentPower(), now - r.stamp < 0.5 else { continue }
            let g = s.gain(r.mediaTime)
            total += r.power * g * g
            any = true; mt = max(mt, r.mediaTime)
        }
        return any ? (total, mt) : nil
    }

    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -120 }

    /// (momentánea, integrada) en LUFS; nil si no está sonando nada.
    func read() -> (momentary: Double, integrated: Double?)? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let now = CACurrentMediaTime()
        guard let (p, mt) = totalPower(now: now) else { return nil }
        // Un salto hacia atrás o grande en el tiempo del video = seek: se empieza de nuevo
        if lastMediaTime >= 0, (mt < lastMediaTime - 0.5 || mt > lastMediaTime + 2) { blocks = [] }
        lastMediaTime = mt
        if now - lastBlockStamp >= 0.1 { blocks.append(p); lastBlockStamp = now }
        let m = Self.lufs(p)
        // Integrado: compuerta absoluta −70 LUFS y relativa −10 LU (BS.1770-4)
        let abs = blocks.filter { Self.lufs($0) > -70 }
        var integrated: Double?
        if abs.count >= 3 {
            let meanAbs = abs.reduce(0, +) / Double(abs.count)
            let gate = Self.lufs(meanAbs) - 10
            let kept = abs.filter { Self.lufs($0) > gate }
            if !kept.isEmpty { integrated = Self.lufs(kept.reduce(0, +) / Double(kept.count)) }
        }
        return (m, integrated)
    }
}

/// Presets de cadena de voz guardados por la persona («mi cadena para Admin»): viven en esta Mac.
/// (Sincronizarlos con el podcast en prePod queda para más adelante.)
enum ChainPresets {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var chain: ChainSettings
    }
    private static let key = "estudio.presets"

    static func all() -> [Item] {
        guard let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([Item].self, from: d) else { return [] }
        return v
    }
    static func save(_ items: [Item]) {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func add(name: String, chain: ChainSettings) {
        var c = chain; c.automation = [:]            // el preset es la cadena, no su automatización
        var items = all().filter { $0.name != name }
        items.append(Item(name: name, chain: c))
        save(items)
    }
    static func remove(_ id: UUID) { save(all().filter { $0.id != id }) }
}
