import Foundation
import AVFoundation
import AppKit
import LiveKit

/// Calidad de lo que se manda a la sala (igual que prodPod web: Baja 360p, Media 480p, Alta 720p).
enum RoomQuality: String, CaseIterable, Identifiable {
    case low, med, high
    var id: String { rawValue }
    var title: String { ["low": "Baja · 360p", "med": "Media · 480p", "high": "Alta · 720p"][rawValue]! }
    var size: (width: Int, height: Int) {
        switch self { case .low: return (640, 360); case .med: return (854, 480); case .high: return (1280, 720) }
    }
    var fps: Int { self == .high ? 30 : 24 }
    var maxBitrate: Int { switch self { case .low: return 600_000; case .med: return 1_200_000; case .high: return 2_500_000 } }
    var layers: [VideoParameters] {
        switch self {
        case .low:
            return [VideoParameters(dimensions: Dimensions(width: 320, height: 180), encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 12))]
        case .med:
            return [VideoParameters(dimensions: Dimensions(width: 320, height: 180), encoding: VideoEncoding(maxBitrate: 150_000, maxFps: 15)),
                    VideoParameters(dimensions: Dimensions(width: 640, height: 360), encoding: VideoEncoding(maxBitrate: 500_000, maxFps: 24))]
        case .high:
            return [VideoParameters(dimensions: Dimensions(width: 320, height: 180), encoding: VideoEncoding(maxBitrate: 200_000, maxFps: 15)),
                    VideoParameters(dimensions: Dimensions(width: 640, height: 360), encoding: VideoEncoding(maxBitrate: 700_000, maxFps: 24))]
        }
    }
    static var saved: RoomQuality {
        get { RoomQuality(rawValue: UserDefaults.standard.string(forKey: "prodCalidadSala") ?? "") ?? .high }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "prodCalidadSala") }
    }
}

/// Una persona en la sala, como la ve la Mac.
struct RoomPerson: Identifiable {
    let id: String
    let name: String
    let isLocal: Bool
    let video: VideoTrack?
    let speaking: Bool
    let micOn: Bool
    let camOn: Bool
    let lastSpokeAt: Date
}

/// Estado de la sala de grabación en la Mac: pantalla previa, conexión, personas y controles.
@MainActor
final class ProdStudio: NSObject, ObservableObject {
    enum Phase: Equatable { case prejoin, joining, inRoom, failed(String) }
    enum Layout: String { case grid, speaker }

    let session: ProdPodClient.Session
    @Published var phase: Phase = .prejoin
    @Published var cameras: [AVCaptureDevice] = []
    @Published var mics: [AVCaptureDevice] = []
    @Published var cameraId = UserDefaults.standard.string(forKey: "prodCamara") ?? "" {
        didSet { UserDefaults.standard.set(cameraId, forKey: "prodCamara") }
    }
    @Published var micId = UserDefaults.standard.string(forKey: "prodMicro") ?? "" {
        didSet { UserDefaults.standard.set(micId, forKey: "prodMicro") }
    }
    @Published var quality = RoomQuality.saved { didSet { RoomQuality.saved = quality; pipe.target = quality.size } }
    @Published var layout = Layout(rawValue: UserDefaults.standard.string(forKey: "prodVista") ?? "") ?? .speaker {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "prodVista") }
    }
    @Published var captureSize = ""
    @Published var micLevel: Float = -160
    @Published var headphones = AVDevices.headphonesLikely
    @Published var previewReady = false
    @Published var people: [RoomPerson] = []
    @Published var participants: [ProdPodClient.Person] = []
    @Published var micOn = true
    @Published var camOn = true
    @Published var elapsed = 0
    @Published var error: String?
    @Published var note: String?
    @Published var permissionDenied = false

    let pipe = CameraPipe()
    private(set) var room: Room?
    private var videoTrack: LocalVideoTrack?
    private var audioTrack: LocalAudioTrack?
    private var timer: Timer?
    private var lastSpoke: [String: Date] = [:]
    private var joinedAt = Date()
    private var joined = false

    init(session: ProdPodClient.Session) {
        self.session = session
        super.init()
    }

    // MARK: Pantalla previa

    func prepare() {
        cameras = AVDevices.cameras
        mics = AVDevices.microphones
        if !cameras.contains(where: { $0.uniqueID == cameraId }) { cameraId = cameras.first?.uniqueID ?? "" }
        if !mics.contains(where: { $0.uniqueID == micId }) {
            micId = AVCaptureDevice.default(for: .audio)?.uniqueID ?? mics.first?.uniqueID ?? ""
        }
        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard cam, mic else { permissionDenied = true; return }
            restartCapture()
            startTicker()
            await loadParticipants()
        }
    }

    func restartCapture() {
        guard let cam = cameras.first(where: { $0.uniqueID == cameraId }) ?? cameras.first else {
            error = "No encontré ninguna cámara conectada."
            return
        }
        let mic = mics.first(where: { $0.uniqueID == micId })
        pipe.target = quality.size
        do {
            pipe.stop()
            let size = try pipe.start(device: cam, mic: mic)
            captureSize = "\(size.width)×\(size.height)"
            previewReady = true
            if let mic { AVDevices.useForRoom(mic) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadParticipants() async {
        participants = (try? await ProdPodClient.shared.participants(session.id)) ?? participants
    }

    // MARK: Entrar

    func join() {
        guard phase != .joining else { return }
        phase = .joining
        Task {
            do {
                if !previewReady { restartCapture() }
                if let mic = mics.first(where: { $0.uniqueID == micId }) { AVDevices.useForRoom(mic) }
                let info = try await ProdPodClient.shared.join(session.id)
                joined = true
                let room = Room(delegate: self)
                self.room = room
                try await room.connect(url: info.livekit_ws_url, token: info.livekit_token,
                                       roomOptions: RoomOptions(adaptiveStream: true, dynacast: true, suspendLocalVideoTracksInBackground: false))

                let track = await LocalVideoTrack.createBufferTrack(
                    name: "camera", source: .camera,
                    options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(quality.size.width), height: Int32(quality.size.height)),
                                                  fps: quality.fps))
                if let cap = track.capturer as? BufferCapturer { pipe.sink = cap }
                try await Task.sleep(nanoseconds: 400_000_000)
                _ = try await room.localParticipant.publish(
                    videoTrack: track,
                    options: VideoPublishOptions(encoding: VideoEncoding(maxBitrate: quality.maxBitrate, maxFps: quality.fps),
                                                 simulcast: true, simulcastLayers: quality.layers, preferredCodec: .vp8))
                videoTrack = track
                if !camOn { try? await track.mute() }

                let pub = try await room.localParticipant.setMicrophone(enabled: true)
                audioTrack = pub?.track as? LocalAudioTrack
                if !micOn { try? await audioTrack?.mute() }

                joinedAt = Date()
                elapsed = 0
                phase = .inRoom
                refresh()
                await loadParticipants()
            } catch {
                phase = .failed(error.localizedDescription)
                self.error = "No se pudo entrar a la sala: \(error.localizedDescription)"
                await disconnect()
                phase = .prejoin
            }
        }
    }

    // MARK: Controles

    func toggleMic() {
        micOn.toggle()
        Task { if micOn { try? await audioTrack?.unmute() } else { try? await audioTrack?.mute() }; refresh() }
    }

    func toggleCam() {
        camOn.toggle()
        Task { if camOn { try? await videoTrack?.unmute() } else { try? await videoTrack?.mute() }; refresh() }
    }

    func copyInvite(_ url: String, name: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        flash("Link de \(name) copiado")
    }

    func invite(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            do {
                let inv = try await ProdPodClient.shared.invite(session.id, name: n)
                copyInvite(inv.invite_url, name: n)
                await loadParticipants()
            } catch { self.error = error.localizedDescription }
        }
    }

    func leave() async {
        await disconnect()
        pipe.stop()
        timer?.invalidate(); timer = nil
    }

    private func disconnect() async {
        pipe.sink = nil
        await room?.disconnect()
        room = nil
        videoTrack = nil
        audioTrack = nil
        people = []
        if joined { await ProdPodClient.shared.leave(session.id); joined = false }
    }

    private func flash(_ s: String) {
        note = s
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if note == s { note = nil } }
    }

    // MARK: Personas

    private func startTicker() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var ticks = 0
    private func tick() {
        ticks += 1
        micLevel = pipe.micLevel ?? -160
        if ticks % 10 == 0 {
            headphones = AVDevices.headphonesLikely
            if phase == .inRoom { elapsed = Int(Date().timeIntervalSince(joinedAt)); refresh() }
        }
    }

    func refresh() {
        guard let room else { people = []; return }
        let now = Date()
        var list: [RoomPerson] = []
        let me = room.localParticipant
        let myId = me.identity?.stringValue ?? "yo"
        if me.isSpeaking { lastSpoke[myId] = now }
        list.append(RoomPerson(id: myId, name: "Tú", isLocal: true,
                               video: camOn ? videoTrack : nil, speaking: me.isSpeaking && micOn,
                               micOn: micOn, camOn: camOn, lastSpokeAt: lastSpoke[myId] ?? .distantPast))
        for p in room.remoteParticipants.values {
            let id = p.identity?.stringValue ?? UUID().uuidString
            if p.isSpeaking { lastSpoke[id] = now }
            let camPub = p.videoTracks.first { $0.source == .camera } ?? p.videoTracks.first { $0.source != .screenShareVideo }
            let micPub = p.audioTracks.first
            list.append(RoomPerson(id: id, name: p.name ?? "Invitado", isLocal: false,
                                   video: (camPub?.isMuted == false) ? camPub?.track as? VideoTrack : nil,
                                   speaking: p.isSpeaking,
                                   micOn: micPub.map { !$0.isMuted } ?? false,
                                   camOn: camPub.map { !$0.isMuted } ?? false,
                                   lastSpokeAt: lastSpoke[id] ?? .distantPast))
        }
        people = list
    }

    /// Quien habla (o habló último) va grande en la vista "quien habla". Si nadie habló, el primero que no seas tú.
    var featured: RoomPerson? {
        let others = people.filter { !$0.isLocal }
        if let s = people.filter({ $0.lastSpokeAt > .distantPast }).max(by: { $0.lastSpokeAt < $1.lastSpokeAt }) { return s }
        return others.first ?? people.first
    }
}

extension ProdStudio: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let n = participant.name ?? "Alguien"
        Task { @MainActor in self.flash("\(n) entró"); self.refresh(); await self.loadParticipants() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let n = participant.name ?? "Alguien"
        Task { @MainActor in self.flash("\(n) salió"); self.refresh() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [LiveKit.Participant]) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            if connectionState == .reconnecting { self.flash("Se cortó la conexión, reconectando…") }
            if connectionState == .connected, oldConnectionState == .reconnecting { self.flash("Conexión recuperada") }
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.phase == .inRoom else { return }
            self.error = "Saliste de la sala" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            await self.disconnect()
            self.phase = .prejoin
        }
    }
}
