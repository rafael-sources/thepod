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
        didSet {
            UserDefaults.standard.set(micId, forKey: "prodMicro")
            if micId != oldValue { cancelMicCheck(); micCheck = nil; micGainDb = Self.savedGain(micId) }
        }
    }
    /// Prueba de micrófono (10 s): mide tu voz y sugiere cuánto subirla o bajarla para la sala.
    /// El ajuste se guarda por micrófono y solo cambia lo que oye la sala; la grabación queda intacta.
    struct MicCheck: Equatable { var peak: Float; var avg: Float; var suggested: Int? }
    @Published var micCheck: MicCheck?
    @Published var micCheckLeft: Int?          // segundos que faltan; nil = no está corriendo
    @Published var micGainDb = 0 {
        didSet { LiveGate.shared.makeupDb = Float(micGainDb) }
    }
    private var micCheckStart: Date?
    private var micCheckPower: [Float] = []
    private var micCheckPeak: Float = -160
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
    /// Auto-silencio en vivo (lo que oye la sala); la grabación no se toca.
    @Published var gateOn = UserDefaults.standard.object(forKey: "prodpod.gate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(gateOn, forKey: "prodpod.gate"); LiveGate.shared.on = gateOn }
    }
    @Published var camOn = true
    @Published var elapsed = 0
    @Published var error: String?
    @Published var note: String?
    @Published var permissionDenied = false

    // Grabación (etapa 2)
    @Published var preflight: String?                 // "Midiendo tu conexión…" / resultado
    @Published var uploadMbps: Double?
    var planWarned = false              // plan Gratis: ya se avisó que queda un minuto
    var planStopped = false             // plan Gratis: ya se cortó al llegar al máximo
    @Published var recMax = RecordingQuality(height: 1080, bitrate: 8_000_000)
    @Published var recQuality = RecordingQuality(height: 1080, bitrate: 8_000_000)
    @Published var ownReady = false
    @Published var readyMap: [String: Bool] = [:]
    @Published var countdown: Int?
    @Published var endCountdown: Int?           // «La grabación terminó · Apagamos cámara y micrófono en 3, 2, 1»
    var uploadSamples: [(at: Date, sent: Int64)] = []   // para estimar cuánto falta (últimos ~30 s)
    @Published var recording = false
    @Published var practice = false
    @Published var sessionEnded = false
    @Published var recSeconds = 0
    @Published var myUpload: UploadState?
    @Published var remoteUploads: [String: UploadState] = [:]
    @Published var sounds: [Pad] = []
    @Published var sponsors: [SponsorMark] = []
    @Published var sponsorAlert: SponsorMark?
    @Published var cue: String?
    @Published var tpNotice: TPNotice?
    @Published var tpActive: TPActive?
    @Published var directorPresent = false
    @Published var exportState: String?
    @Published var exporting = false

    struct UploadState: Equatable {
        var state: String; var bytes: Int64; var total: Int64 = 0; var message: String?
        var pending: Int64? = nil       // bytes que faltan por subir (lo manda cada persona en upload_status)
        var eta: Int? = nil             // segundos estimados para terminar
    }
    struct Pad: Identifiable, Equatable {
        let id: Int; let name: String; let filename: String; let key: String?; let color: String?; let url: String
    }
    struct SponsorMark: Identifiable, Equatable {
        let id: Int; let name: String; let copy: String; var at: Double
    }

    var myIdentity = ""
    var isOwner: Bool { session.created_by == PrePodClient.username }
    let recorder = FragmentRecorder()
    let voiceFeed = CleanVoiceFeed()
    var recordFile: URL?
    var recordStart = Date()
    var countdownTimer: Timer?
    var players: [String: AVAudioPlayer] = [:]
    var triggerLog: [[String: Any]] = []
    var firedSponsors: Set<Int> = []
    var tpScript: [TPSection] = []
    var tpFired: Set<Int> = []
    var tpPeople: [String: String] = [:]      // identity -> nombre
    var tpUsernames: [String: String] = [:]   // identity -> usuario
    var tpNoticeTask: Task<Void, Never>?
    var tpShowTask: Task<Void, Never>?
    var tpHideTask: Task<Void, Never>?
    var keyMonitor: Any?
    var ifbOn = false

    // Etapa 3: pantalla, chat, manos, transmisión
    let screen = ScreenShare()
    let screenRecorder = FragmentRecorder()
    var screenFile: URL?
    @Published var screenOn = false
    @Published var remoteScreen: (name: String, track: VideoTrack)?
    @Published var chat: [ChatMsg] = []
    @Published var backstage: [ChatMsg] = []
    @Published var unreadChat = 0
    @Published var hands: [String: Bool] = [:]
    @Published var overlays: [Overlay] = []
    @Published var myHand = false
    @Published var liveStream: [String: Any]?
    @Published var rtmpPresets: [[String: String]] = []
    var hostIdentities: [String] = []

    struct ChatMsg: Identifiable, Equatable { let id: Int; let author: String; let text: String; let mine: Bool }

    let pipe = CameraPipe()
    private(set) var room: Room?
    private var videoTrack: LocalVideoTrack?
    private var audioTrack: LocalAudioTrack?
    private var timer: Timer?
    private var lastSpoke: [String: Date] = [:]
    private var joinedAt = Date()
    private var joined = false

    /// La sala abierta ahora (para salir bien al cerrar la app).
    static weak var current: ProdStudio?
    /// Transmitir en vivo queda escondido hasta la última etapa del plan.
    static let liveEnabled = false

    init(session: ProdPodClient.Session) {
        self.session = session
        super.init()
        Self.current = self
    }

    // MARK: Pantalla previa

    func prepare() {
        micGainDb = Self.savedGain(micId)
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
            await runPreflight()
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
                myIdentity = "participant_\(info.participant_id)"
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

                // La puerta va en el procesado de LiveKit; la grabación recibe la copia cruda a través de ella.
                LiveGate.shared.on = gateOn
                LiveGate.shared.tap = voiceFeed
                AudioManager.shared.capturePostProcessingDelegate = LiveGate.shared
                let pub = try await room.localParticipant.setMicrophone(enabled: true)
                audioTrack = pub?.track as? LocalAudioTrack
                if !micOn { try? await audioTrack?.mute() }
                await afterJoin()

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
        if recording { await finishRecording(local: true) }
        removeKeyMonitor()
        await disconnect()
        pipe.stop()
        timer?.invalidate(); timer = nil
    }

    func disconnect() async {
        LiveGate.shared.tap = nil
        AudioManager.shared.capturePostProcessingDelegate = nil
        pipe.sink = nil
        await room?.disconnect()
        room = nil
        videoTrack = nil
        audioTrack = nil
        people = []
        if joined { await ProdPodClient.shared.leave(session.id); joined = false }
    }

    func flash(_ s: String) {
        note = s
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if note == s { note = nil } }
    }

    // MARK: Prueba de micrófono

    static func savedGain(_ micId: String) -> Int {
        UserDefaults.standard.integer(forKey: "prodpod.micGainDb." + (micId.isEmpty ? "default" : micId))
    }

    func runMicCheck() {
        guard pipe.micLevel != nil else { error = "No hay micrófono activo."; return }
        micCheck = nil
        micCheckPower = []
        micCheckPeak = -160
        micCheckStart = Date()
        micCheckLeft = 10
    }

    func cancelMicCheck() {
        micCheckStart = nil
        micCheckLeft = nil
    }

    func applyMicGain() {
        guard let db = micCheck?.suggested else { return }
        setMicGain(db)
    }

    func setMicGain(_ db: Int) {
        UserDefaults.standard.set(db, forKey: "prodpod.micGainDb." + (micId.isEmpty ? "default" : micId))
        micGainDb = db
    }

    private func tickMicCheck() {
        guard let start = micCheckStart else { return }
        let level = pipe.micLevel ?? -160
        micCheckPower.append(powf(10, max(-90, level) / 10))
        micCheckPeak = max(micCheckPeak, pipe.micPeak ?? level)
        let t = Date().timeIntervalSince(start)
        micCheckLeft = max(0, 10 - Int(t))
        guard t >= 10 else { return }
        micCheckStart = nil
        micCheckLeft = nil
        micCheck = Self.evaluate(power: micCheckPower, peak: micCheckPeak)
    }

    /// Promedio de energía a dBFS y sugerencia hacia −18 dBFS, igual que la web:
    /// entre −12 y +18 dB; si casi no hubo señal (< −55) no se sugiere nada.
    static func evaluate(power: [Float], peak: Float) -> MicCheck {
        let mean = power.isEmpty ? 0 : power.reduce(0, +) / Float(power.count)
        let avg = mean > 0 ? max(-90, 10 * log10f(mean)) : -90
        let pk = max(-90, min(0, peak))
        let suggested: Int? = avg < -55 ? nil : Int(max(-12, min(18, (-18 - avg).rounded())))
        return MicCheck(peak: (pk * 10).rounded() / 10, avg: (avg * 10).rounded() / 10, suggested: suggested)
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
        tickMicCheck()
        tickRecording()
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
        var scr: (String, VideoTrack)?
        for p in room.remoteParticipants.values {
            if let pub = p.videoTracks.first(where: { $0.source == .screenShareVideo }), !pub.isMuted, let t = pub.track as? VideoTrack {
                scr = (p.name ?? "Alguien", t)
            }
        }
        if (scr == nil) != (remoteScreen == nil) || scr?.1 !== remoteScreen?.track {
            remoteScreen = scr.map { (name: $0.0, track: $0.1) }
        }
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
        let id = participant.identity?.stringValue ?? ""
        Task { @MainActor in
            if id.hasPrefix("director_") {
                self.directorPresent = true
                self.flash("El director está conectado")
                if self.ownReady { self.send(["type": "ready_toggle", "identity": self.myIdentity, "ready": true]) }
            } else {
                self.flash("\(n) entró")
            }
            self.refresh(); await self.loadParticipants()
        }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let n = participant.name ?? "Alguien"
        let id = participant.identity?.stringValue ?? ""
        Task { @MainActor in
            if id.hasPrefix("director_") { self.updateDirectorPresence() } else { self.flash("\(n) salió") }
            self.readyMap[id] = nil
            self.refresh()
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let payload = SendableDict(obj)
        Task { @MainActor in self.handle(payload.value) }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let isDirector = participant.identity?.stringValue.hasPrefix("director_") ?? false
        if isDirector, let a = publication.track as? RemoteAudioTrack { a.volume = 0 }   // solo se oye cuando habla al oído
        Task { @MainActor in
            if isDirector { self.applyIFB() }
            self.refresh()
        }
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
