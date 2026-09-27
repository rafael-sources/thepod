import Foundation

/// Thin wrapper around the ffmpeg CLI. Used only for the jobs AVFoundation can't do:
/// decoding WebM (VP8/VP9/Opus) from prodPod, the speech-enhancement DSP chain and MP3.
/// Rendering/preview is 100% AVFoundation.
enum FFmpeg {
    enum Failure: LocalizedError {
        case notFound
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notFound:
                return "A esta copia de thePod le falta una parte que necesita para procesar video. Vuelve a instalar la app."
            case .failed(let msg):
                return "No se pudo procesar el archivo. (\(msg))"
            }
        }
    }

    static var executableURL: URL? {
        // La copia que viene dentro de la app (Contents/MacOS/ffmpeg) manda: es la versión con la que se prueba.
        // Homebrew queda solo como respaldo para compilaciones de desarrollo sin Vendor/ffmpeg.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static var isAvailable: Bool { executableURL != nil }

    /// Speech chain identical to postPod web (exporter.py §3.13).
    static let speechChain = "highpass=f=80,afftdn=nr=12,equalizer=f=4000:t=q:w=1:g=3,acompressor=threshold=-18dB:ratio=3:attack=5:release=100,loudnorm=I=-16:TP=-1.5:LRA=11"

    /// Runs ffmpeg. `duration` (seconds of input) enables progress 0...1.
    @discardableResult
    static func run(_ args: [String], duration: Double? = nil, allowFailure: Bool = false,
                    progress: ((Double) -> Void)? = nil) async throws -> String {
        guard let exe = executableURL else { throw Failure.notFound }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["-hide_banner", "-nostdin", "-y"] + args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let collector = OutputCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            collector.append(chunk)
            if let duration, duration > 0, let t = lastTime(in: chunk) {
                progress?(min(1, max(0, t / duration)))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                process.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let s = String(data: rest, encoding: .utf8) { collector.append(s) }
                    let log = collector.text
                    if p.terminationStatus == 0 || (allowFailure && p.terminationReason == .exit) {
                        cont.resume(returning: log)
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        let tail = log.split(separator: "\n").suffix(4).joined(separator: "\n")
                        cont.resume(throwing: Failure.failed(tail))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Fast duration probe that also works on MediaRecorder WebM files without a duration header:
    /// remuxes to null and reads the last timestamp.
    static func probeDuration(_ url: URL) async throws -> Double {
        let log = try await run(["-i", url.path, "-map", "0", "-c", "copy", "-f", "null", "-"])
        if let t = lastTime(in: log), t > 0 { return t }
        if let d = headerDuration(in: log) { return d }
        return 0
    }

    /// ffmpeg's stream listing for a file (works even when decoding the first frames fails).
    static func inspect(_ url: URL) async -> String {
        (try? await run(["-i", url.path], allowFailure: true)) ?? ""
    }

    static func hasStream(_ kind: String, in url: URL) async -> Bool {
        let log = await inspect(url)
        return log.contains("Stream #") && log.contains(": \(kind):")
    }

    static var probeURL: URL? {
        guard let ff = executableURL else { return nil }
        let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: probe.path) ? probe : nil
    }

    /// First timestamp of the video and audio streams. prodPod files that lost their first
    /// chunks keep absolute timestamps (e.g. video starts at 510 s); we pad so every lane stays in sync.
    static func streamStarts(_ url: URL) async -> (video: Double?, audio: Double?) {
        guard let probe = probeURL else { return (nil, nil) }
        let p = Process()
        p.executableURL = probe
        p.arguments = ["-v", "quiet", "-show_entries", "stream=codec_type,start_time", "-of", "csv=p=0", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil) }
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        var v: Double?, a: Double?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: ",")
            guard parts.count >= 2, let t = Double(parts[1]) else { continue }
            if parts[0] == "video", v == nil { v = t }
            if parts[0] == "audio", a == nil { a = t }
        }
        return (v, a)
    }

    // MARK: parsing

    static func lastTime(in text: String) -> Double? {
        var result: Double?
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: "time=", range: searchRange) {
            let after = text[r.upperBound...]
            let token = after.prefix { !$0.isWhitespace }
            if let secs = parseClock(String(token)) { result = secs }
            searchRange = r.upperBound..<text.endIndex
        }
        return result
    }

    static func headerDuration(in text: String) -> Double? {
        guard let r = text.range(of: "Duration: ") else { return nil }
        let token = text[r.upperBound...].prefix { $0 != "," }
        return parseClock(String(token))
    }

    static func parseClock(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) {
        lock.lock()
        buffer += s
        if buffer.count > 200_000 { buffer = String(buffer.suffix(100_000)) }
        lock.unlock()
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}
