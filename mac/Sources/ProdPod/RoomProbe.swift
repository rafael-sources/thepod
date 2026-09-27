import Foundation
import AVFoundation
import VideoToolbox
import AppKit
import LiveKit

/// Prueba de sala: entra a una sala de prodPod desde la Mac, manda la cámara en 720p,
/// graba la misma cámara en 1080p en la Mac y guarda la voz tal como sale hacia la sala.
/// Deja un registro (prueba.json) para revisar el resultado.
@MainActor
final class RoomProbe: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, connecting, connected, failed(String) }

    struct Remote: Identifiable {
        let id: String
        let name: String
        let track: VideoTrack?
        var speaking: Bool
    }

    @Published var sessions: [ProdPodClient.Session] = []
    @Published var sessionId: Int?
    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraId: String = ""
    @Published var phase: Phase = .idle
    @Published var remotes: [Remote] = []
    @Published var localTrack: LocalVideoTrack?
    @Published var inviteURL: String?
    @Published var recording = false
    @Published var recordSeconds = 0
    @Published var folder: URL?
    @Published var notes: [String] = []
    @Published var busy = false
    @Published var error: String?

    // Resultados
    @Published var captureSize = ""
    @Published var roomSize = ""
    @Published var framesRecorded = 0
    @Published var framesSent = 0
    @Published var dataMessages = 0

    private(set) var room: Room?
    private var joinedSession: Int?
    private let pipe = CameraPipe()
    private var voice: VoiceTap?
    private var timer: Timer?
    private var startedAt = Date()

    // MARK: Preparar

    func load() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        if cameraId.isEmpty { cameraId = cameras.first?.uniqueID ?? "" }
        Task {
            do {
                sessions = try await ProdPodClient.shared.sessions()
                if sessionId == nil { sessionId = sessions.first(where: { $0.title.hasPrefix("Prueba de sala") })?.id }
            } catch { self.error = error.localizedDescription }
        }
    }

    func createTestSession() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let s = try await ProdPodClient.shared.createSession(title: "Prueba de sala (Mac)")
                sessions.insert(s, at: 0)
                sessionId = s.id
                note("Sala de prueba creada")
            } catch { self.error = error.localizedDescription }
        }
    }

    func makeInvite() {
        guard let sid = sessionId else { return }
        Task {
            do {
                let inv = try await ProdPodClient.shared.invite(sid, name: "Invitado de prueba")
                inviteURL = inv.invite_url
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inv.invite_url, forType: .string)
                note("Link de invitado copiado")
            } catch { self.error = error.localizedDescription }
        }
    }

    static func askPermissions() async -> (camera: Bool, mic: Bool) {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return (cam, mic)
    }

    // MARK: Entrar

    func join() {
        guard let sid = sessionId, let device = cameras.first(where: { $0.uniqueID == cameraId }) ?? cameras.first else {
            error = cameras.isEmpty ? "No encontré ninguna cámara." : "Elige una sala."
            return
        }
        phase = .connecting
        Task {
            let perms = await Self.askPermissions()
            guard perms.camera, perms.mic else {
                phase = .failed("Sin permiso de cámara o micrófono")
                error = "macOS no dio permiso de cámara o micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad."
                return
            }
            do {
                // 1. Cámara en 1080p (o lo máximo que dé)
                let size = try pipe.start(device: device)
                captureSize = "\(size.width)×\(size.height)"
                note("Cámara: \(device.localizedName) a \(captureSize)")

                // 2. Permiso para entrar a la sala
                let info = try await ProdPodClient.shared.join(sid)
                joinedSession = sid
                note("prodPod te dejó entrar como \(info.display_name) (\(info.role))")

                // 3. Conectar a la sala
                let room = Room(delegate: self)
                self.room = room
                try await room.connect(url: info.livekit_ws_url, token: info.livekit_token)
                note("Conectado a la sala")

                // 4. Mandar la cámara en 720p (la misma que se graba en 1080p)
                let track = await LocalVideoTrack.createBufferTrack(
                    name: "camera", source: .camera,
                    options: BufferCaptureOptions(dimensions: Dimensions(width: 1280, height: 720), fps: 30))
                if let cap = track.capturer as? BufferCapturer { pipe.sink = cap }
                try await Task.sleep(nanoseconds: 400_000_000)       // que llegue al menos un cuadro
                _ = try await room.localParticipant.publish(
                    videoTrack: track,
                    options: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30),
                                                 simulcast: true, preferredCodec: .vp8))
                localTrack = track
                note("Tu cámara ya se ve en la sala")

                // 5. Micrófono (con cancelación de eco) y copia de la voz que sale a la sala
                let pub = try await room.localParticipant.setMicrophone(enabled: true)
                if let mic = pub?.track as? LocalAudioTrack {
                    let tap = VoiceTap()
                    voice = tap
                    mic.add(audioRenderer: tap)
                }
                note("Tu micrófono ya se oye en la sala")
                phase = .connected
                startedAt = Date()
                refreshRemotes()
                startTicker()
            } catch {
                phase = .failed(error.localizedDescription)
                self.error = error.localizedDescription
                note("Falló: \(error.localizedDescription)")
                await leave()
            }
        }
    }

    func leave() async {
        if recording { stopRecording() }
        timer?.invalidate(); timer = nil
        if let voice, let mic = room?.localParticipant.audioTracks.first?.track as? LocalAudioTrack { mic.remove(audioRenderer: voice) }
        pipe.stop()
        await room?.disconnect()
        room = nil
        localTrack = nil
        remotes = []
        if let s = joinedSession { await ProdPodClient.shared.leave(s) }
        joinedSession = nil
        if case .connected = phase { phase = .idle }
        writeLog()
    }

    // MARK: Grabar

    func startRecording() {
        let dir = Self.baseFolder.appendingPathComponent(Self.stamp())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try pipe.startRecording(to: dir.appendingPathComponent("camara-1080p.mov"))
            voice?.start(dir.appendingPathComponent("voz-hacia-la-sala.wav"))
            folder = dir
            recording = true
            recordSeconds = 0
            note("Grabando en la Mac…")
        } catch { self.error = error.localizedDescription }
    }

    func stopRecording() {
        pipe.stopRecording()
        voice?.stop()
        recording = false
        note("Grabación guardada (\(recordSeconds) s)")
        writeLog()
    }

    private func startTicker() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.framesRecorded = self.pipe.recordedFrames
                self.framesSent = self.pipe.sentFrames
                if let d = self.localTrack?.dimensions { self.roomSize = "\(d.width)×\(d.height)" }
                if self.recording {
                    self.recordSeconds += 1
                    if self.recordSeconds >= 30 { self.stopRecording() }
                }
                self.refreshRemotes()
            }
        }
    }

    func refreshRemotes() {
        guard let room else { remotes = []; return }
        remotes = room.remoteParticipants.values.map { p in
            Remote(id: p.identity?.stringValue ?? UUID().uuidString,
                   name: p.name ?? p.identity?.stringValue ?? "Alguien",
                   track: p.videoTracks.first?.track as? VideoTrack,
                   speaking: p.isSpeaking)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Registro

    private func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        notes.append("\(f.string(from: Date()))  \(s)")
    }

    private func writeLog() {
        let dir = folder ?? Self.baseFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log: [String: Any] = [
            "camara": captureSize, "sala": roomSize,
            "cuadros_grabados": framesRecorded, "cuadros_enviados": framesSent,
            "personas_en_sala": remotes.map(\.name), "mensajes_de_sala": dataMessages,
            "segundos_grabados": recordSeconds, "notas": notes,
            "version": "\(Updater.currentVersion) (\(Updater.currentBuild))",
        ]
        if let d = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent("prueba.json"))
        }
    }

    static var baseFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("postPod/pruebas-sala")
    }
    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date())
    }
}

extension RoomProbe: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.note("Entró \(participant.name ?? "alguien")"); self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.note("Salió \(participant.name ?? "alguien")"); self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [LiveKit.Participant]) {
        Task { @MainActor in self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let type = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String ?? "?"
        Task { @MainActor in self.dataMessages += 1; self.note("Mensaje de la sala: \(type)") }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            if let error { self.note("Se cortó la sala: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Cámara: una sola captura, dos salidas (grabación 1080p y sala 720p)

final class CameraPipe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "thepod.camera")
    private let audioQueue = DispatchQueue(label: "thepod.camera.audio")
    private let lock = NSLock()
    var sink: BufferCapturer? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }
    private var _sink: BufferCapturer?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var started = false
    private(set) var recordedFrames = 0
    private(set) var sentFrames = 0

    struct Size { let width: Int32; let height: Int32 }

    func start(device: AVCaptureDevice) throws -> Size {
        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PrePodClient.Failure(message: "No se pudo usar la cámara") }
        session.addInput(input)
        if let micDev = AVCaptureDevice.default(for: .audio), let mic = try? AVCaptureDeviceInput(device: micDev), session.canAddInput(mic) {
            session.addInput(mic)
        }

        // El formato más cercano a 1080p a 30 cuadros, sin pasar de 1080p
        let best = device.formats
            .filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.height <= 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
        try device.lockForConfiguration()
        if let best { device.activeFormat = best }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()

        let vOut = AVCaptureVideoDataOutput()
        vOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        vOut.alwaysDiscardsLateVideoFrames = true
        vOut.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(vOut) { session.addOutput(vOut) }
        let aOut = AVCaptureAudioDataOutput()
        aOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(aOut) { session.addOutput(aOut) }
        session.commitConfiguration()
        session.startRunning()

        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return Size(width: d.width, height: d.height)
    }

    func stop() {
        session.stopRunning()
        sink = nil
    }

    // MARK: Grabación

    func startRecording(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        a.expectsMediaDataInRealTime = true
        if w.canAdd(v) { w.add(v) }
        if w.canAdd(a) { w.add(a) }
        lock.withLock {
            writer = w; videoIn = v; audioIn = a; started = false; recordedFrames = 0
        }
    }

    func stopRecording() {
        let w: AVAssetWriter? = lock.withLock {
            let w = writer
            writer = nil
            return w
        }
        guard let w, w.status == .writing else { w?.cancelWriting(); return }
        videoIn?.markAsFinished(); audioIn?.markAsFinished()
        w.finishWriting {}
    }

    // MARK: Cuadros

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        lock.lock()
        if let w = writer {
            if !started, isVideo {
                if w.startWriting() {
                    w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    started = true
                }
            }
            if started {
                if isVideo, let v = videoIn, v.isReadyForMoreMediaData { if v.append(sampleBuffer) { recordedFrames += 1 } }
                if !isVideo, let a = audioIn, a.isReadyForMoreMediaData { a.append(sampleBuffer) }
            }
        }
        let sink = _sink
        lock.unlock()

        guard isVideo, let sink, let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let small = scaled(src) {
            let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
            sink.capture(small, timeStampNs: ts)
            sentFrames += 1
        }
    }

    /// Reduce a 1280×720 para la sala (con el chip de video de la Mac).
    private func scaled(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        if w <= 1280 { return src }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let transfer, let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(transfer, from: src, to: out) == noErr else { return nil }
        return out
    }
}

// MARK: - Voz tal como sale hacia la sala (después de quitar el eco)

final class VoiceTap: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?

    func start(_ url: URL) { lock.withLock { self.url = url; file = nil } }
    func stop() { lock.withLock { file = nil; url = nil } }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings,
                                    commonFormat: pcmBuffer.format.commonFormat, interleaved: pcmBuffer.format.isInterleaved)
        }
        try? file?.write(from: pcmBuffer)
    }
}
