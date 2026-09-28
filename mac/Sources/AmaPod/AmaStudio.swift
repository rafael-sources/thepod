import SwiftUI
import AVFoundation
import LiveKit

/// El estudio del host de un evento de amaPod: tu cámara, quien está al aire, la cola, las solicitudes y el chat.
@MainActor
final class AmaStudio: NSObject, ObservableObject {
    enum Phase: Equatable { case prejoin, joining, live, ended }

    struct Tile: Identifiable {
        let id: String            // participant_<pid>
        let pid: Int?
        let name: String
        let video: VideoTrack?
        let micOn: Bool
        let speaking: Bool
    }

    @Published var event: AmaClient.Event
    @Published var phase: Phase = .prejoin
    @Published var error: String?
    @Published var note: String?

    // Tus equipos
    @Published var cameras: [AVCaptureDevice] = AVDevices.cameras
    @Published var mics: [AVCaptureDevice] = AVDevices.microphones
    @Published var camId: String = UserDefaults.standard.string(forKey: "amaCamara") ?? "" {
        didSet { UserDefaults.standard.set(camId, forKey: "amaCamara"); if phase == .prejoin { startPreview() } }
    }
    @Published var micId: String = UserDefaults.standard.string(forKey: "amaMicrofono") ?? "" {
        didSet { UserDefaults.standard.set(micId, forKey: "amaMicrofono") }
    }
    @Published var camOn = true
    @Published var micOn = true
    @Published private(set) var myVideo: LocalVideoTrack?

    // Lo que pasa en el evento
    @Published var tiles: [Tile] = []
    @Published var queue: [AmaClient.Person] = []
    @Published var requests: [AmaClient.Person] = []
    @Published var chat: [AmaClient.Message] = []
    @Published var recording = false
    @Published var likes = 0
    @Published var spectators = 0
    @Published var busy = false

    var onAir: AmaClient.Person? { queue.first { $0.status == "on_air" } }
    var waiting: [AmaClient.Person] { queue.filter { $0.status == "in_queue" }.sorted { ($0.queue_position ?? 0) < ($1.queue_position ?? 0) } }
    var onAirTile: Tile? { onAir.flatMap { p in tiles.first { $0.pid == p.id } } }

    private var room: Room?
    private var poll: Timer?
    private var chatPoll: Timer?
    private var seenRequests = Set<Int>()
    private var leaving = false

    static weak var current: AmaStudio?

    init(event: AmaClient.Event) {
        self.event = event
        super.init()
        Self.current = self
        if camId.isEmpty || !cameras.contains(where: { $0.uniqueID == camId }) { camId = cameras.first?.uniqueID ?? "" }
        if micId.isEmpty || !mics.contains(where: { $0.uniqueID == micId }) { micId = mics.first?.uniqueID ?? "" }
    }

    // MARK: Vista previa

    func startPreview() {
        Task {
            if let old = myVideo { try? await old.stop() }
            let cam = cameras.first { $0.uniqueID == camId }
            let t = await LocalVideoTrack.createCameraTrack(options: CameraCaptureOptions(device: cam, dimensions: .h720_169, fps: 30))
            do { try await t.start(); myVideo = t } catch { self.error = "No se pudo abrir la cámara: \(error.localizedDescription)" }
        }
    }

    func stopPreview() {
        guard phase == .prejoin, let t = myVideo else { return }
        myVideo = nil
        Task { try? await t.stop() }
    }

    // MARK: Empezar / terminar

    /// Abre el evento (si estaba por empezar), entra a la sala, empieza a grabar en el servidor y a mirar la cola.
    func goLive() {
        guard phase == .prejoin else { return }
        phase = .joining
        Task {
            do {
                if event.status == "created" { event = try await AmaClient.shared.start(event.id) }
                let url = try await AmaClient.shared.livekitURL()
                let tok = try await AmaClient.shared.hostToken(event.id)
                if let mic = mics.first(where: { $0.uniqueID == micId }) { AVDevices.useForRoom(mic) }
                let room = Room(delegate: self)
                self.room = room
                try await room.connect(url: url, token: tok.token, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
                if myVideo == nil { startPreview(); try? await Task.sleep(nanoseconds: 600_000_000) }
                if let v = myVideo {
                    _ = try await room.localParticipant.publish(videoTrack: v, options: VideoPublishOptions(simulcast: true))
                    if !camOn { try? await v.mute() }
                }
                _ = try await room.localParticipant.setMicrophone(enabled: micOn)
                phase = .live
                startPolling()
                if !(await AmaClient.shared.recordingActive(event.id)) {
                    do { try await AmaClient.shared.startRecording(event.id); recording = true }
                    catch { flash("No se pudo empezar a grabar en el servidor: \(error.localizedDescription)") }
                } else { recording = true }
            } catch {
                self.error = "No se pudo abrir el evento: \(error.localizedDescription)"
                await disconnect()
                phase = .prejoin
            }
        }
    }

    /// Cierra el evento para todos. Si se grabó, amaPod lo manda a postPod.
    func finish() {
        Task {
            busy = true
            defer { busy = false }
            do {
                if recording { try? await AmaClient.shared.stopRecording(event.id); recording = false }
                event = try await AmaClient.shared.finish(event.id)
                send(["type": "event_ended"])
                try? await Task.sleep(nanoseconds: 300_000_000)
                await disconnect()
                phase = .ended
            } catch { self.error = "No se pudo terminar el evento: \(error.localizedDescription)" }
        }
    }

    /// Sales de la sala sin terminar el evento (sigue abierto para el público).
    func leave() async {
        await disconnect()
        if let t = myVideo { myVideo = nil; try? await t.stop() }
    }

    private func disconnect() async {
        guard !leaving else { return }
        leaving = true
        defer { leaving = false }
        poll?.invalidate(); poll = nil
        chatPoll?.invalidate(); chatPoll = nil
        if let room { await room.disconnect() }
        room = nil
        tiles = []
    }

    // MARK: Controles

    func toggleMic() {
        micOn.toggle()
        Task { _ = try? await room?.localParticipant.setMicrophone(enabled: micOn) }
    }

    func toggleCam() {
        camOn.toggle()
        Task { if camOn { try? await myVideo?.unmute() } else { try? await myVideo?.mute() } }
    }

    func toggleRecording() {
        Task {
            do {
                if recording { try await AmaClient.shared.stopRecording(event.id); recording = false; flash("Grabación detenida") }
                else { try await AmaClient.shared.startRecording(event.id); recording = true; flash("Grabando en el servidor") }
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Cola

    func approve(_ p: AmaClient.Person) { act { try await AmaClient.shared.approve(self.event.id, p.id) } }
    func reject(_ p: AmaClient.Person) { act { try await AmaClient.shared.reject(self.event.id, p.id) } }
    func remove(_ p: AmaClient.Person) { act { try await AmaClient.shared.remove(self.event.id, p.id) } }

    func next() {
        act {
            if let p = try await AmaClient.shared.next(self.event.id) {
                self.flash("\(p.display_name) al aire")
                self.send(["type": "turn_change", "participant": ["id": p.id, "display_name": p.display_name]])
            } else {
                self.flash(self.onAir == nil ? "No hay nadie en la cola" : "Listo. No queda nadie en la cola")
            }
        }
    }

    func putOnAir(_ p: AmaClient.Person) {
        act {
            let r = try await AmaClient.shared.skip(self.event.id, to: p.id)
            self.flash("\(r.display_name) al aire")
            self.send(["type": "turn_change", "participant": ["id": r.id, "display_name": r.display_name]])
        }
    }

    func censor(_ p: AmaClient.Person) {
        act {
            if p.censored {
                try await AmaClient.shared.uncensor(self.event.id, p.id)
                self.send(["type": "uncensor", "participant_id": p.id])
            } else {
                try await AmaClient.shared.censor(self.event.id, p.id)
                self.send(["type": "censor", "participant_id": p.id])
                self.flash("\(p.display_name) silenciado y oculto")
            }
        }
    }

    /// Mueve a alguien en la cola (arrastrando).
    func move(from: IndexSet, to: Int) {
        var list = waiting
        list.move(fromOffsets: from, toOffset: to)
        let order = list.map(\.id)
        // Se ve el cambio al instante; el servidor lo confirma en la próxima lectura.
        let onAirNow = queue.filter { $0.status == "on_air" }
        queue = onAirNow + list.enumerated().map { i, p in var q = p; q.queue_position = i + 1; return q }
        act { try await AmaClient.shared.reorder(self.event.id, order) }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            await self.load()
        }
    }

    // MARK: Chat

    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                let m = try await AmaClient.shared.say(event.id, t)
                if !chat.contains(where: { $0.id == m.id }) { chat.append(m) }
                send(["type": "chat", "sender_name": m.sender_name, "message": m.message, "is_host": 1])
            } catch { self.error = error.localizedDescription }
        }
    }

    func deleteMessage(_ m: AmaClient.Message) {
        Task {
            try? await AmaClient.shared.deleteMessage(event.id, m.id)
            chat.removeAll { $0.id == m.id }
        }
    }

    // MARK: Leer el estado

    private func startPolling() {
        Task { await load(); await loadChat() }
        poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
        chatPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.loadChat() }
        }
    }

    func load() async {
        let id = event.id
        async let q = try? AmaClient.shared.queue(id)
        async let r = try? AmaClient.shared.requests(id)
        async let i = try? AmaClient.shared.publicInfo(id)
        if let q = await q { queue = q }
        if let r = await r {
            let fresh = r.filter { !seenRequests.contains($0.id) }
            if !fresh.isEmpty, !seenRequests.isEmpty || phase == .live {
                flash(fresh.count == 1 ? "\(fresh[0].display_name) quiere preguntar" : "\(fresh.count) personas quieren preguntar")
            }
            fresh.forEach { seenRequests.insert($0.id) }
            requests = r
        }
        if let i = await i { likes = i.like_count ?? likes; spectators = i.spectator_count ?? spectators }
        refresh()
    }

    func loadChat() async {
        if let c = try? await AmaClient.shared.chat(event.id) { chat = c }
    }

    func refresh() {
        guard let room else { tiles = []; return }
        tiles = room.remoteParticipants.values.compactMap { p in
            guard let id = p.identity?.stringValue, id.hasPrefix("participant_") else { return nil }
            let cam = p.videoTracks.first { $0.source == .camera }
            return Tile(id: id, pid: Int(id.dropFirst("participant_".count)), name: p.name ?? "Alguien",
                        video: (cam?.isMuted == false) ? cam?.track as? VideoTrack : nil,
                        micOn: p.audioTracks.first.map { !$0.isMuted } ?? false, speaking: p.isSpeaking)
        }
    }

    private func send(_ msg: [String: Any]) {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: true)) }
    }

    func flash(_ s: String) {
        note = s
        Task { try? await Task.sleep(nanoseconds: 2_800_000_000); if note == s { note = nil } }
    }

    func copy(_ s: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        flash("Link \(what) copiado")
    }
}

extension AmaStudio: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.refresh() }
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
    nonisolated func room(_ room: Room, participant: LiveKit.Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], obj["type"] as? String == "chat" else { return }
        Task { @MainActor in await self.loadChat() }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.phase == .live, !self.leaving else { return }
            self.error = "Se cortó la conexión con la sala" + (error.map { ": \($0.localizedDescription)" } ?? ".")
        }
    }
}
