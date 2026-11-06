import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Recording quality on the Mac, decided by the initial test (same as prodPod web).
struct RecordingQuality: Hashable {
    var height: Int          // 1080 or 720
    var bitrate: Int         // video bits per second
    var label: String { "\(height)p" }
    var width: Int { height == 1080 ? 1920 : 1280 }

    /// prodPod web's table: never below 720p.
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
    var title: String { String(localized: "\(label) · \(String(format: "%.1f", Double(bitrate) / 1_000_000)) Mbps") }
}

/// Records camera and voice into a fragmented MP4: each fragment is saved on the Mac and
/// handed over for upload while recording. Joined, the fragments form a valid file.
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
    /// Notifies when there are new bytes in the file.
    var onBytes: (@Sendable (Int64) -> Void)?

    var isRecording: Bool { lock.withLock { writer != nil } }
    var duration: Double {
        lock.withLock { (firstPTS.isValid && lastPTS.isValid) ? CMTimeGetSeconds(lastPTS - firstPTS) : 0 }
    }

    /// withAudio=false for screen sharing (video only).
    func start(to url: URL, quality: RecordingQuality, withAudio: Bool = true, fps: Int = 30) throws {
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
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        v.mediaTimeScale = 90_000          // fine timestamps: no frame repeats a time
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 256_000,
        ])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(v), !withAudio || w.canAdd(a) else { throw PrePodClient.Failure(message: String(localized: "No se pudo preparar la grabación")) }
        w.add(v)
        if withAudio { w.add(a) }
        lock.withLock {
            writer = w; videoIn = v; audioIn = withAudio ? a : nil; handle = h; fileURL = url
            started = false; bytesWritten = 0; firstPTS = .invalid; lastPTS = .invalid
        }
    }

    /// The file starts at 0: the first frame's time is subtracted from everything.
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

    /// Finishes the file (the last fragment arrives through the delegate before returning).
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

    // Each fragment: appended to the end of the local file.
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

// MARK: - Clean voice (no echo) to samples for the recorder

enum PCM {
    /// Converts a block of room audio into a timestamped sample, to record it.
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

// MARK: - Safe chunked upload (resumable, reads from the file on the Mac)

/// Uploads the recording file in parts with "offset": if a part repeats it isn't duplicated,
/// if something's missing the server says where to continue from. If the app closes, it resumes on return.
actor ChunkUploader {
    struct Job: Codable, Equatable {
        var sessionId: Int
        var file: String
        var trackType: String? = "video"
        var takeId: String? = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var sent: Int64 = 0
        var recordingDone = false      // the recording ended (the file no longer grows)
        var finalized = false
        var duration: Double = 0
    }

    static let shared = ChunkUploader()
    private var jobs: [String: Job] = [:]          // by file path
    private var running: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()
    /// Progress notices: (file, bytes uploaded, total, finished, error)
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

    func begin(sessionId: Int, file: URL, trackType: String = "video") {
        jobs[file.path] = Job(sessionId: sessionId, file: file.path, trackType: trackType)
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

    /// Resumes everything pending (when opening prod).
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
                // During recording, parts of up to 2 MB with a short pause; if it fell behind (more than 16 MB
                // pending) or already finished, 8 MB parts without pause. Never slower than what the video produces.
                let behind = size - j.sent > 16 << 20
                let piece = min(size - j.sent, (j.recordingDone || behind) ? 8 << 20 : 2 << 20)
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
                    onProgress?(key, j.sent, size, false, failures >= 3 ? String(localized: "Sin conexión, reintentando…") : nil)
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
                    continue
                }
                if !j.recordingDone && !behind { try? await Task.sleep(nanoseconds: 500_000_000) }
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
                    onProgress?(key, j.sent, size, false, String(localized: "No se pudo cerrar la subida, reintentando…"))
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
                }
                continue
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)     // waiting for more recording
        }
    }

    private static func read(_ path: String, from: Int64, count: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(from))
        return try h.read(upToCount: count) ?? Data()
    }

    /// Returns how many bytes the server has.
    private func post(_ j: Job, chunk: Data?, offset: Int64, finalize: Bool) async throws -> Int64 {
        var fields = ["track_type": j.trackType ?? "video", "ext": ".mp4", "offset": String(offset)]
        if let t = j.takeId { fields["take_id"] = t }      // each recording is its own take
        if finalize { fields["finalize"] = "1"; fields["duration_seconds"] = String(format: "%.2f", j.duration) }
        let (code, obj) = try await ProdPodClient.shared.multipart("/api/sessions/\(j.sessionId)/recordings/stream",
                                                                  fields: fields, fileField: chunk == nil ? nil : "chunk",
                                                                  fileName: "chunk.mp4", fileData: chunk)
        if code == 409, let b = obj["bytes_received"] as? Int { return Int64(b) }      // continue from where the server is
        guard (200..<300).contains(code) else {
            throw PrePodClient.Failure(message: (obj["error"] as? String) ?? String(localized: "prodPod respondió \(code)"))
        }
        if finalize { return offset }
        if let b = obj["bytes_received"] as? Int { return Int64(b) }
        return offset + Int64(chunk?.count ?? 0)
    }
}
