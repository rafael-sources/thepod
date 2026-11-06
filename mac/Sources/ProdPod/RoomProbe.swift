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
                let s = try await ProdPodClient.shared.createSession(title: String(localized: "Prueba de sala (Mac)"))
                sessions.insert(s, at: 0)
                sessionId = s.id
                note(String(localized: "Sala de prueba creada"))
            } catch { self.error = error.localizedDescription }
        }
    }

    func makeInvite() {
        guard let sid = sessionId else { return }
        Task {
            do {
                let inv = try await ProdPodClient.shared.invite(sid, name: String(localized: "Invitado de prueba"))
                inviteURL = inv.invite_url
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(inv.invite_url, forType: .string)
                note(String(localized: "Link de invitado copiado"))
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
            error = cameras.isEmpty ? String(localized: "No encontré ninguna cámara.") : String(localized: "Elige una sala.")
            return
        }
        phase = .connecting
        Task {
            let perms = await Self.askPermissions()
            guard perms.camera, perms.mic else {
                phase = .failed(String(localized: "Sin permiso de cámara o micrófono"))
                error = String(localized: "macOS no dio permiso de cámara o micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad.")
                return
            }
            do {
                // 1. Cámara en 1080p (o lo máximo que dé)
                let size = try pipe.start(device: device)
                captureSize = "\(size.width)×\(size.height)"
                note(String(localized: "Cámara: \(device.localizedName) a \(captureSize)"))

                // 2. Permiso para entrar a la sala
                let info = try await ProdPodClient.shared.join(sid)
                joinedSession = sid
                note(String(localized: "prodPod te dejó entrar como \(info.display_name) (\(info.role))"))

                // 3. Conectar a la sala
                let room = Room(delegate: self)
                self.room = room
                try await room.connect(url: info.livekit_ws_url, token: info.livekit_token)
                note(String(localized: "Conectado a la sala"))

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
                note(String(localized: "Tu cámara ya se ve en la sala"))

                // 5. Micrófono (con cancelación de eco) y copia de la voz que sale a la sala
                let pub = try await room.localParticipant.setMicrophone(enabled: true)
                if let mic = pub?.track as? LocalAudioTrack {
                    let tap = VoiceTap()
                    voice = tap
                    mic.add(audioRenderer: tap)
                }
                note(String(localized: "Tu micrófono ya se oye en la sala"))
                phase = .connected
                startedAt = Date()
                refreshRemotes()
                startTicker()
            } catch {
                phase = .failed(error.localizedDescription)
                self.error = error.localizedDescription
                note(String(localized: "Falló: \(error.localizedDescription)"))
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
            note(String(localized: "Grabando en la Mac…"))
        } catch { self.error = error.localizedDescription }
    }

    func stopRecording() {
        pipe.stopRecording()
        voice?.stop()
        recording = false
        note(String(localized: "Grabación guardada (\(recordSeconds) s)"))
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
                   name: p.name ?? p.identity?.stringValue ?? String(localized: "Alguien"),
                   track: p.videoTracks.first?.track as? VideoTrack,
                   speaking: p.isSpeaking)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Registro

    private func note(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        notes.append(String(localized: "\(f.string(from: Date()))  \(s)"))
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
        Task { @MainActor in self.note(String(localized: "Entró \(participant.name ?? "alguien")")); self.refreshRemotes() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.note(String(localized: "Salió \(participant.name ?? "alguien")")); self.refreshRemotes() }
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
        Task { @MainActor in self.dataMessages += 1; self.note(String(localized: "Mensaje de la sala: \(type)")) }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            if let error { self.note(String(localized: "Se cortó la sala: \(error.localizedDescription)")) }
        }
    }
}

