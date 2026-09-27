import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Calidad de la grabación en la Mac, decidida por la prueba inicial (igual que prodPod web).
struct RecordingQuality: Hashable {
    var height: Int          // 1080 o 720
    var bitrate: Int         // bits por segundo del video
    var label: String { "\(height)p" }
    var width: Int { height == 1080 ? 1920 : 1280 }

    /// La tabla de prodPod web: nunca menos de 720p.
    static func decide(uploadMbps: Double, cameraHeight: Int) -> RecordingQuality {
        var q: RecordingQuality
        if uploadMbps >= 8 { q = .init(height: 1080, bitrate: 8_000_000) }
        else if uploadMbps >= 4 { q = .init(height: 1080, bitrate: 5_000_000) }
        else if uploadMbps >= 2 { q = .init(height: 720, bitrate: 2_500_000) }
        else { q = .init(height: 720, bitrate: 1_500_000) }
        if cameraHeight < 1080 && q.height == 1080 { q = .init(height: 720, bitrate: 2_500_000) }
        return q
    }
    static let options: [RecordingQuality] = [
        .init(height: 1080, bitrate: 8_000_000), .init(height: 1080, bitrate: 5_000_000),
        .init(height: 720, bitrate: 2_500_000), .init(height: 720, bitrate: 1_500_000),
    ]
    var title: String { "\(label) · \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps" }
}

/// Graba cámara y voz en un MP4 por fragmentos: cada fragmento se guarda en la Mac y
/// se entrega para subirlo mientras se graba. Unidos, los fragmentos forman un archivo válido.
final class FragmentRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var started = false
    private var handle: FileHandle?
    private(set) var fileURL: URL?
    private(set) var bytesWritten: Int64 = 0
    private(set) var firstPTS: CMTime = .invalid
    private(set) var lastPTS: CMTime = .invalid
    private var finishCont: CheckedContinuation<Void, Never>?
    /// Avisa cuando hay bytes nuevos en el archivo.
    var onBytes: (@Sendable (Int64) -> Void)?

    var isRecording: Bool { lock.withLock { writer != nil } }
    var duration: Double {
        lock.withLock { (firstPTS.isValid && lastPTS.isValid) ? CMTimeGetSeconds(lastPTS - firstPTS) : 0 }
    }

    func start(to url: URL, quality: RecordingQuality) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)

        let w = AVAssetWriter(contentType: UTType.mpeg4Movie)
        w.outputFileTypeProfile = .mpeg4AppleHLS
        w.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        w.delegate = self

        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: quality.width, AVVideoHeightKey: quality.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        v.mediaTimeScale = 90_000          // marcas de tiempo finas: ningún cuadro repite hora
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 256_000,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(v), w.canAdd(a) else { throw PrePodClient.Failure(message: "No se pudo preparar la grabación") }
        w.add(v); w.add(a)
        lock.withLock {
            writer = w; videoIn = v; audioIn = a; handle = h; fileURL = url
            started = false; bytesWritten = 0; firstPTS = .invalid; lastPTS = .invalid
        }
    }

    /// El archivo empieza en 0: se resta la hora del primer cuadro a todo.
    func appendVideo(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let w = writer, let v = videoIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !started {
            w.initialSegmentStartTime = .zero
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: .zero)
            started = true
            firstPTS = pts
        }
        guard pts > lastPTS || !lastPTS.isValid, let r = Self.retimed(sb, minus: firstPTS) else { return }
        if v.isReadyForMoreMediaData, v.append(r) { lastPTS = pts }
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard started, let a = audioIn, a.isReadyForMoreMediaData else { return }
        if CMSampleBufferGetPresentationTimeStamp(sb) < firstPTS { return }
        if let r = Self.retimed(sb, minus: firstPTS) { a.append(r) }
    }

    private static func retimed(_ sb: CMSampleBuffer, minus base: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in 0..<info.count {
            info[i].presentationTimeStamp = CMTimeSubtract(info[i].presentationTimeStamp, base)
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = CMTimeSubtract(info[i].decodeTimeStamp, base) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: info.count,
                                              sampleTimingArray: &info, sampleBufferOut: &out)
        return out
    }

    /// Termina el archivo (el último fragmento llega por el delegado antes de volver).
    func finish() async {
        let w: AVAssetWriter? = lock.withLock { writer }
        guard let w else { return }
        if w.status == .writing {
            lock.withLock { videoIn?.markAsFinished(); audioIn?.markAsFinished() }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                w.finishWriting { c.resume() }
            }
        } else {
            w.cancelWriting()
        }
        lock.withLock {
            try? handle?.close()
            handle = nil; writer = nil; videoIn = nil; audioIn = nil
        }
    }

    // Cada fragmento: se agrega al final del archivo local.
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        var total: Int64 = 0
        lock.withLock {
            try? handle?.write(contentsOf: segmentData)
            bytesWritten += Int64(segmentData.count)
            total = bytesWritten
        }
        onBytes?(total)
    }
}

// MARK: - Voz limpia (sin eco) a muestras para el grabador

enum PCM {
    /// Convierte un bloque de audio de la sala en una muestra con su hora, para grabarla.
    static func sampleBuffer(_ buf: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: buf.format.streamDescription, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buf.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: desc, sampleCount: CMItemCount(buf.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: buf.audioBufferList) == noErr else { return nil }
        return sb
    }
}

// MARK: - Subida segura por partes (reanudable, lee del archivo en la Mac)

/// Sube el archivo de la grabación por partes con "offset": si una parte se repite no se duplica,
/// si falta algo el servidor dice desde dónde seguir. Si se cierra la app, se retoma al volver.
actor ChunkUploader {
    struct Job: Codable, Equatable {
        var sessionId: Int
        var file: String
        var sent: Int64 = 0
        var recordingDone = false      // la grabación terminó (el archivo ya no crece)
        var finalized = false
        var duration: Double = 0
    }

    static let shared = ChunkUploader()
    private var jobs: [String: Job] = [:]          // por ruta de archivo
    private var running: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()
    /// Avisos de avance: (archivo, bytes subidos, total, terminado, error)
    var onProgress: (@Sendable (String, Int64, Int64, Bool, String?) -> Void)?

    init() {
        if let d = try? Data(contentsOf: Self.store), let j = try? JSONDecoder().decode([String: Job].self, from: d) {
            jobs = j.filter { !$0.value.finalized && FileManager.default.fileExists(atPath: $0.key) }
        }
    }

    func setProgress(_ f: @escaping @Sendable (String, Int64, Int64, Bool, String?) -> Void) { onProgress = f }

    static var store: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("postPod/subidas-pendientes.json")
    }
    private func save() {
        try? FileManager.default.createDirectory(at: Self.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(jobs) { try? d.write(to: Self.store) }
    }

    func pending() -> [Job] { Array(jobs.values) }

    func begin(sessionId: Int, file: URL) {
        jobs[file.path] = Job(sessionId: sessionId, file: file.path)
        save()
        kick(file.path)
    }

    func markDone(file: URL, duration: Double) {
        guard var j = jobs[file.path] else { return }
        j.recordingDone = true
        j.duration = duration
        jobs[file.path] = j
        save()
        kick(file.path)
    }

    /// Retoma todo lo pendiente (al abrir prod).
    func resumeAll() { for k in jobs.keys { kick(k) } }

    private func kick(_ key: String) {
        guard !running.contains(key) else { return }
        running.insert(key)
        Task { await self.loop(key) }
    }

    private func loop(_ key: String) async {
        defer { running.remove(key) }
        var failures = 0
        while var j = jobs[key], !j.finalized {
            let size = (try? FileManager.default.attributesOfItem(atPath: key)[.size] as? Int64) ?? 0
            if j.sent < size {
                // Durante la grabación, partes de hasta 2 MB con pausa; al terminar, a toda velocidad.
                let piece = min(size - j.sent, j.recordingDone ? 8 << 20 : 2 << 20)
                do {
                    let data = try Self.read(key, from: j.sent, count: Int(piece))
                    let got = try await post(j, chunk: data, offset: j.sent, finalize: false)
                    j.sent = got
                    jobs[key] = j
                    save()
                    failures = 0
                    onProgress?(key, j.sent, size, false, nil)
                } catch {
                    failures += 1
                    onProgress?(key, j.sent, size, false, failures >= 3 ? "Sin conexión, reintentando…" : nil)
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
                    continue
                }
                if !j.recordingDone { try? await Task.sleep(nanoseconds: 500_000_000) }
                continue
            }
            if j.recordingDone {
                do {
                    _ = try await post(j, chunk: nil, offset: j.sent, finalize: true)
                    j.finalized = true
                    jobs[key] = nil
                    save()
                    onProgress?(key, size, size, true, nil)
                } catch {
                    failures += 1
                    onProgress?(key, j.sent, size, false, "No se pudo cerrar la subida, reintentando…")
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
                }
                continue
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)     // esperando más grabación
        }
    }

    private static func read(_ path: String, from: Int64, count: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(from))
        return try h.read(upToCount: count) ?? Data()
    }

    /// Devuelve cuántos bytes tiene el servidor.
    private func post(_ j: Job, chunk: Data?, offset: Int64, finalize: Bool) async throws -> Int64 {
        var fields = ["track_type": "video", "ext": ".mp4", "offset": String(offset)]
        if finalize { fields["finalize"] = "1"; fields["duration_seconds"] = String(format: "%.2f", j.duration) }
        let (code, obj) = try await ProdPodClient.shared.multipart("/api/sessions/\(j.sessionId)/recordings/stream",
                                                                  fields: fields, fileField: chunk == nil ? nil : "chunk",
                                                                  fileName: "chunk.mp4", fileData: chunk)
        if code == 409, let b = obj["bytes_received"] as? Int { return Int64(b) }      // seguir desde donde tiene el servidor
        guard (200..<300).contains(code) else {
            throw PrePodClient.Failure(message: (obj["error"] as? String) ?? "prodPod respondió \(code)")
        }
        if finalize { return offset }
        if let b = obj["bytes_received"] as? Int { return Int64(b) }
        return offset + Int64(chunk?.count ?? 0)
    }
}
