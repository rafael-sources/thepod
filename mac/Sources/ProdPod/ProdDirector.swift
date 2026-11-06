import Foundation
import AVFoundation
import AppKit
import LiveKit

/// El director desde la Mac: ve y oye a todos, controla la grabación, manda avisos,
/// habla al oído, silencia, pone cintillos (sponsors y podcast) y envía a post.
@MainActor
final class DirectorStudio: NSObject, ObservableObject {
    struct Feed: Identifiable {
        let id: String            // identity participant_N
        let pid: Int?
        let name: String
        let camera: VideoTrack?
        let screen: VideoTrack?
        let speaking: Bool
        let micOn: Bool
    }
    struct SponsorInfo: Identifiable, Hashable { let id: Int; let name: String; let copy: String; let logoURL: String? }

    let session: ProdPodClient.Session
    @Published var connected = false
    @Published var joining = false
    @Published var error: String?
    @Published var note: String?
    @Published var feeds: [Feed] = []
    @Published var participants: [ProdPodClient.Person] = []
    @Published var readyMap: [String: Bool] = [:]
    @Published var uploads: [String: String] = [:]         // identity → estado
    @Published var uploadBytes: [String: Int64] = [:]
    @Published var practice = false
    @Published var countdown: Int?
    @Published var recording = false
    @Published var recSeconds = 0
    @Published var finished = false
    @Published var exportResult: String?
    @Published var exporting = false
    @Published var overlays: [Overlay] = []
    @Published var chat: [(id: Int, author: String, text: String)] = []
    @Published var sounds: [ProdStudio.Pad] = []
    @Published var ifbTarget: String?                      // "all_hosts" o identity mientras se habla
    @Published var sponsors: [SponsorInfo] = []
    @Published var podcastName = ""
    @Published var podcastLogo: NSImage?

    private(set) var room: Room?
    private var ifbTrack: LocalAudioTrack?
    private var ifbWork: Task<Void, Never>?                 // publicar/silenciar el audio al oído (se espera antes de salir)
    private var leaving = false
    private var recStart = Date()
    private var timer: Timer?
    private var myIdentity = ""
    private var assetPaths: [String: String] = [:]         // logo → file_path en el servidor
    private var sponsorLogos: [Int: Data] = [:]
    private var podcastLogoData: Data?
    private var joined = false
    static weak var current: DirectorStudio?

    init(session: ProdPodClient.Session) {
        self.session = session
        super.init()
        Self.current = self
    }

    // MARK: Entrar / salir

    func join() {
        guard !joining, !connected else { return }
        joining = true
        Task {
            defer { joining = false }
            do {
                let info = try await ProdPodClient.shared.directorJoin(session.id)
                joined = true
                myIdentity = "director_\(info.participant_id)"
                let room = Room(delegate: self)
                self.room = room
                try await room.connect(url: info.livekit_ws_url, token: info.livekit_token,
                                       roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
                connected = true
                finished = session.status == "finished"
                refresh()
                await loadParticipants()
                try? await Task.sleep(nanoseconds: 800_000_000)
                send(["type": "ready_request"])              // que todos digan si están preparados
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                await loadSounds()
                await loadChat()
                await loadBranding()
            } catch {
                self.error = String(localized: "No se pudo entrar como director: \(error.localizedDescription)")
                await leave()
            }
        }
    }

    func leave() async {
        guard !leaving else { return }
        leaving = true
        defer { leaving = false }
        timer?.invalidate(); timer = nil
        ifbTarget = nil
        // Nunca cortar la conexión con una publicación a medias: eso tumbaba la app.
        await ifbWork?.value
        ifbWork = nil
        if let t = ifbTrack, let room {
            try? await t.mute()
            try? await room.localParticipant.unpublishAll(notify: false)
            _ = t
        }
        ifbTrack = nil
        await room?.disconnect()
        room = nil
        connected = false
        feeds = []
        if joined { await ProdPodClient.shared.leave(session.id); joined = false }
    }

    func loadParticipants() async {
        participants = (try? await ProdPodClient.shared.participants(session.id)) ?? participants
    }

    // MARK: Mensajes

    func send(_ msg: [String: Any]) {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: true)) }
    }

    func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready_toggle":
            if let id = m["identity"] as? String { readyMap[id] = (m["ready"] as? Bool) ?? false }
            Task { await loadParticipants() }
        case "practice_mode":
            practice = (m["active"] as? Bool) ?? false
        case "upload_status":
            if let id = m["identity"] as? String {
                uploads[id] = m["state"] as? String ?? ""
                uploadBytes[id] = Int64(m["bytes"] as? Int ?? 0)
            }
        case "countdown_start":
            if let ms = (m["start_at_ms"] as? Double) ?? (m["start_at_ms"] as? Int).map(Double.init) { beginCountdown(ms, callStart: false) }
        case "recording_stop":
            recording = false
            finished = !practice
            readyMap = [:]
        case "director_chat":
            break
        default: break
        }
    }

    // MARK: Grabar

    /// Conductores conectados ahora (los que no están en la sala no bloquean).
    var hostsInRoom: [ProdPodClient.Person] {
        let live = Set(feeds.map(\.id))
        return participants.filter { ["host", "co-host"].contains($0.role) && live.contains("participant_\($0.id)") }
    }
    var allHostsReady: Bool { !hostsInRoom.isEmpty && hostsInRoom.allSatisfy { readyMap["participant_\($0.id)"] == true } }

    func startRecording() {
        guard allHostsReady, !recording, countdown == nil else { return }
        let startAt = Date().timeIntervalSince1970 * 1000 + 3500
        send(["type": "countdown_start", "start_at_ms": startAt])
        beginCountdown(startAt, callStart: true)
    }

    private func beginCountdown(_ startAtMs: Double, callStart: Bool) {
        guard !recording, countdown == nil else { return }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let rem = startAtMs - Date().timeIntervalSince1970 * 1000
                if rem <= 0 {
                    t.invalidate()
                    self.countdown = nil
                    self.recording = true
                    self.recStart = Date()
                    self.uploads = [:]
                    if callStart && !self.practice {
                        Task { _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(self.session.id)/start") }
                    }
                } else {
                    self.countdown = Int((rem / 1000).rounded(.up))
                }
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        Task {
            if !practice { _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/stop") }
            send(["type": "recording_stop"])
            recording = false
            finished = !practice
            readyMap = [:]
        }
    }

    var allUploadsDone: Bool { !uploads.isEmpty && uploads.values.allSatisfy { $0 == "done" } }

    func exportToPost() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/recordings/export-to-postpod")
                if let e = r["error"] as? String { exportResult = e; return }
                let n = r["exported"] as? Int ?? 0, f = r["failed"] as? Int ?? 0
                exportResult = n == 0 && f == 0 ? String(localized: "Ya estaba en postPod.") : String(localized: "Enviado a postPod: \(n) \(n == 1 ? String(localized: "pista") : String(localized: "pistas"))") + (f > 0 ? String(localized: " · \(f) fallaron") : "")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func tick() {
        if recording { recSeconds = Int(Date().timeIntervalSince(recStart)) }
        if !overlays.isEmpty { overlays.removeAll { ($0.expires ?? .distantFuture) < Date() } }
    }

    // MARK: Avisos privados

    static let cues = [String(localized: "CERRAR TEMA"), String(localized: "SIGUIENTE TEMA"), String(localized: "PAUSA"), String(localized: "MÁS RÁPIDO"), String(localized: "MÁS LENTO"), String(localized: "LEER ANUNCIO")]

    func sendCue(_ cue: String, text: String = "", target: String = "all") {
        Task {
            _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/director/cue",
                                                         ["cue": cue, "text": text, "target": target])
            send(["type": "director_cue", "cue": cue, "target": target, "text": text])
            flash(String(localized: "Aviso enviado: \(text.isEmpty ? cue : text)"))
        }
    }

    // MARK: Teleprompter (0.11.0)

    var tpLastId: String?

    /// Manda el teleprompter a una persona o a todos. Con `countdown` > 0 todos ven primero el aviso
    /// ("Viene X en 3 s · ATENTO …") y el texto solo le aparece a quien le toca.
    func sendTeleprompter(target: String, title: String, text: String, speed: String, size: String, countdown: Int) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { error = String(localized: "Escribe el texto del teleprompter"); return }
        let eid = String(localized: "d\(Int(Date().timeIntervalSince1970 * 1000))")
        let ttl = title.isEmpty ? String(localized: "Teleprompter") : title
        send(["type": "teleprompter", "action": "show", "event_id": eid, "target": target,
              "title": ttl, "text": t, "speed": speed, "size": size, "countdown": max(0, countdown)])
        tpLastId = eid
        Task {
            _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/director/inject",
                ["event_type": "teleprompter",
                 "payload": ["target": target, "title": ttl, "text": t, "speed": speed, "size": size]])
        }
        flash(String(localized: "Teleprompter enviado") + (countdown > 0 ? String(localized: " (aviso de \(countdown) s)") : ""))
    }

    func hideTeleprompter() {
        var m: [String: Any] = ["type": "teleprompter", "action": "hide", "target": "all"]
        if let tpLastId { m["event_id"] = tpLastId }
        send(m)
        flash(String(localized: "Teleprompter quitado"))
    }

    func setGuestCues(_ show: Bool) { send(["type": "cue_visibility", "show": show]) }

    // MARK: Hablar al oído (mantener presionado)

    func ifbPress(_ target: String) {
        guard ifbTarget == nil, connected, !leaving, let room else { return }
        ifbTarget = target
        let previous = ifbWork
        ifbWork = Task {
            await previous?.value
            guard !leaving, ifbTarget != nil else { return }
            if ifbTrack == nil {
                let t = await LocalAudioTrack.createTrack(name: "ifb_audio")
                _ = try? await room.localParticipant.publish(audioTrack: t, options: AudioPublishOptions(name: "ifb_audio"))
                ifbTrack = t
            }
            try? await ifbTrack?.unmute()
            send(["type": "ifb_start", "targets": target == "all_hosts" ? "all_hosts" as Any : [target] as Any])
        }
    }

    func ifbRelease() {
        guard ifbTarget != nil else { return }
        ifbTarget = nil
        let previous = ifbWork
        ifbWork = Task {
            await previous?.value
            try? await ifbTrack?.mute()
            send(["type": "ifb_stop"])
        }
    }

    // MARK: Silenciar y sacar

    func forceMute(_ p: ProdPodClient.Person) {
        Task {
            do {
                _ = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/participants/\(p.id)/force-mute")
                send(["type": "force_mute", "target": "participant_\(p.id)"])
                flash(String(localized: "Silenciaste a \(p.display_name)"))
            } catch { self.error = error.localizedDescription }
        }
    }

    func kick(_ p: ProdPodClient.Person) {
        Task {
            do {
                try await ProdPodClient.shared.send(method: "DELETE", path: "/api/sessions/\(session.id)/participants/\(p.id)")
                send(["type": "kick", "target_identity": "participant_\(p.id)"])
                flash(String(localized: "Sacaste a \(p.display_name)"))
                await loadParticipants()
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Cintillos

    /// Logos del podcast y de sus sponsors (desde prePod).
    func loadBranding() async {
        guard let slug = session.source_slug, !slug.isEmpty else { await applyEpisodeBranding(); return }
        let pre = PrePodClient.shared
        if let cfg = try? await pre.podcastConfig(slug) {
            podcastName = cfg.name
            if let u = cfg.logoUrl, !u.isEmpty, let d = try? await pre.media(u) {
                podcastLogoData = d
                podcastLogo = NSImage(data: d)
            }
        }
        if let list = try? await pre.sponsors(slug) {
            sponsors = list.filter(\.isActive).map { SponsorInfo(id: $0.id, name: $0.name, copy: $0.copy, logoURL: $0.logoUrl) }
            for s in list where s.isActive {
                if let u = s.logoUrl, !u.isEmpty, let d = try? await pre.media(u) { sponsorLogos[s.id] = d }
            }
        }
        await applyEpisodeBranding()
    }

    /// Los sponsors de ESTE episodio (los que prodPod guardó al crear la sala) van primero.
    private func applyEpisodeBranding() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/director/branding"),
              let b = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if podcastName.isEmpty, let n = b["podcast_name"] as? String { podcastName = n }
        let eps = (b["sponsors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        guard !eps.isEmpty else { return }
        var ordered: [SponsorInfo] = []
        for (i, n) in eps.enumerated() {
            if let s = sponsors.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { ordered.append(s) }
            else {
                let copy = (b["sponsors"] as? [[String: Any]])?[i]["copy"] as? String ?? ""
                ordered.append(SponsorInfo(id: -1000 - i, name: n, copy: copy, logoURL: nil))
            }
        }
        sponsors = ordered + sponsors.filter { s in !ordered.contains { $0.id == s.id } }
    }

    func sponsorLogo(_ s: SponsorInfo) -> NSImage? { sponsorLogos[s.id].flatMap(NSImage.init(data:)) }

    private func assetPath(key: String, data: Data?) async -> String? {
        if let p = assetPaths[key] { return p }
        guard let data else { return nil }
        let ext = NSImage(data: data).flatMap { _ in "png" } ?? "png"
        // Normalizar a PNG para que cualquier navegador lo muestre
        let png = NSImage(data: data).flatMap { img -> Data? in
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        } ?? data
        guard let p = try? await ProdPodClient.shared.uploadDirectorAsset(session.id, data: png, name: "\(key).\(ext)") else { return nil }
        assetPaths[key] = p
        return p
    }

    /// Cintillo de sponsor: su logo y su texto.
    func showSponsor(_ s: SponsorInfo, text: String, seconds: Double) {
        Task {
            let path = await assetPath(key: "sponsor\(s.id)", data: sponsorLogos[s.id])
            await inject(kind: "sponsor", payload: ["sponsor_name": s.name, "sponsor_copy": text, "style": "cintillo"],
                         filePath: path, seconds: seconds, image: sponsorLogo(s))
        }
    }

    /// Cintillo del podcast: su logo y un texto del momento.
    func showPodcast(title: String, text: String, seconds: Double) {
        Task {
            let path = await assetPath(key: "podcast", data: podcastLogoData)
            await inject(kind: "banner", payload: ["name": title.isEmpty ? podcastName : title, "title": text, "style": "cintillo"],
                         filePath: path, seconds: seconds, image: podcastLogo)
        }
    }

    func showSegment(title: String, subtitle: String) {
        Task { await inject(kind: "segment", payload: ["title": title, "subtitle": subtitle], filePath: nil, seconds: 12, image: nil) }
    }

    private func inject(kind: String, payload: [String: Any], filePath: String?, seconds: Double, image: NSImage?) async {
        var body: [String: Any] = ["event_type": kind, "payload": payload, "duration_seconds": seconds]
        if let filePath { body["file_path"] = filePath }
        do {
            let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/director/inject", body)
            guard let id = r["event_id"] as? Int else { throw PrePodClient.Failure(message: String(localized: "El servidor no confirmó el cintillo")) }
            var msg: [String: Any] = ["type": "overlay_inject", "event_type": kind, "payload": payload, "event_id": id, "duration_seconds": seconds]
            if let filePath { msg["file_path"] = filePath }
            send(msg)
            if var o = Overlay.from(msg) { o.image = image; overlays.append(o) }
        } catch { self.error = String(localized: "No se pudo poner el cintillo: \(error.localizedDescription)") }
    }

    func removeOverlay(_ o: Overlay) {
        overlays.removeAll { $0.id == o.id }
        Task {
            _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/director/events/\(o.id)/remove")
            send(["type": "overlay_remove", "event_id": o.id])
        }
    }

    // MARK: Chat de dirección

    func loadChat() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/chat?channel=director"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        chat = list.compactMap { m in
            guard let id = m["id"] as? Int else { return nil }
            return (id, m["author_name"] as? String ?? "?", m["message_text"] as? String ?? "")
        }
    }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/chat", ["text": t, "channel": "director"])
                let id = r["id"] as? Int ?? 0
                let author = r["author_name"] as? String ?? String(localized: "Director")
                chat.append((id, author, t))
                send(["type": "director_chat", "id": id, "author": author, "text": t])
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Soundboard

    private var players: [String: AVAudioPlayer] = [:]

    func loadSounds() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/sounds"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        sounds = list.compactMap { s in
            guard let id = s["id"] as? Int, let fn = s["filename"] as? String, let url = s["url"] as? String else { return nil }
            return ProdStudio.Pad(id: id, name: s["name"] as? String ?? fn, filename: fn,
                                  key: (s["shortcut_key"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() },
                                  color: s["color"] as? String, url: url)
        }
        for p in sounds where players[p.filename] == nil {
            if let data = try? await ProdPodClient.shared.get(p.url), let pl = try? AVAudioPlayer(data: data) { pl.prepareToPlay(); players[p.filename] = pl }
        }
    }

    func trigger(_ pad: ProdStudio.Pad) {
        if let p = players[pad.filename] { p.currentTime = 0; p.play() }
        var m: [String: Any] = ["type": "sound_trigger", "filename": pad.filename]
        if let k = pad.key { m["key"] = k }
        send(m)
    }

    // MARK: Personas

    func refresh() {
        guard let room else { feeds = []; return }
        feeds = room.remoteParticipants.values.compactMap { p in
            guard let id = p.identity?.stringValue, id.hasPrefix("participant_") else { return nil }
            let cam = p.videoTracks.first { $0.source == .camera }
            let scr = p.videoTracks.first { $0.source == .screenShareVideo }
            return Feed(id: id, pid: Int(id.dropFirst("participant_".count)), name: p.name ?? String(localized: "Alguien"),
                        camera: (cam?.isMuted == false) ? cam?.track as? VideoTrack : nil,
                        screen: (scr?.isMuted == false) ? scr?.track as? VideoTrack : nil,
                        speaking: p.isSpeaking, micOn: p.audioTracks.first.map { !$0.isMuted } ?? false)
        }.sorted { $0.name < $1.name }
    }

    func person(for feed: Feed) -> ProdPodClient.Person? { participants.first { $0.id == feed.pid } }

    func flash(_ s: String) {
        note = s
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if note == s { note = nil } }
    }
}

extension DirectorStudio: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.refresh(); await self.loadParticipants() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let id = participant.identity?.stringValue ?? ""
        Task { @MainActor in self.readyMap[id] = nil; self.refresh(); await self.loadParticipants() }
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
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let payload = SendableDict(obj)
        Task { @MainActor in self.handle(payload.value) }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.connected else { return }
            self.connected = false
            self.error = String(localized: "Se cortó la conexión con la sala") + (error.map { ": \($0.localizedDescription)" } ?? ".")
        }
    }
}
