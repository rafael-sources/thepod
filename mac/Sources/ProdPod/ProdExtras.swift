import Foundation
import AppKit
import LiveKit
import UniformTypeIdentifiers

extension ProdStudio {
    // MARK: Compartir pantalla

    /// Abre el selector de macOS y comparte (o solo graba) la pantalla o ventana elegida.
    func shareScreen(recordOnly: Bool) {
        guard !screenOn else { return }
        if remoteScreen != nil && !recordOnly {
            error = "\(remoteScreen?.name ?? "Otra persona") ya está compartiendo pantalla. Solo una a la vez."
            return
        }
        Task {
            guard let filter = await screen.pick() else { return }
            do {
                try await screen.start(filter: filter, room: room, recorder: nil, recordOnly: recordOnly)
                screenOn = true
                if recording { startScreenRecording() }
                flash(recordOnly ? "Grabando tu pantalla (no se muestra en la sala)" : "Compartiendo tu pantalla")
            } catch {
                self.error = "No se pudo compartir la pantalla: \(error.localizedDescription)"
            }
        }
    }

    func stopScreen() {
        Task {
            await stopScreenRecording()
            await screen.stop(room: room)
            screenOn = false
            flash("Dejaste de compartir la pantalla")
        }
    }

    /// La pantalla se graba mientras se graba el episodio (así queda alineada en post).
    func startScreenRecording() {
        guard screenRecorder.isRecording == false else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("postPod/grabaciones")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = dir.appendingPathComponent("sala\(session.id)_pantalla_\(f.string(from: Date())).mp4")
        do {
            try screenRecorder.start(to: file, quality: RecordingQuality(height: 1080, bitrate: 3_000_000), withAudio: false, fps: 20)
            screenFile = file
            screen.attach(screenRecorder)
            if !practice { Task { await ChunkUploader.shared.begin(sessionId: session.id, file: file, trackType: "screen") } }
        } catch {
            self.error = "No se pudo grabar la pantalla: \(error.localizedDescription)"
        }
    }

    func stopScreenRecording() async {
        guard screenRecorder.isRecording, let file = screenFile else { return }
        screen.attach(nil)
        await screenRecorder.finish()
        if !practice { await ChunkUploader.shared.markDone(file: file, duration: screenRecorder.duration) }
        screenFile = nil
    }

    // MARK: Chat

    func loadChat() async {
        let me = PrePodClient.username
        func load(_ ch: String) async -> [ChatMsg] {
            guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/chat?channel=\(ch)"),
                  let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
            let myName = participants.first { $0.username == me }?.display_name
            return list.compactMap { m in
                guard let id = m["id"] as? Int else { return nil }
                let author = m["author_name"] as? String ?? "?"
                return ChatMsg(id: id, author: author, text: m["message_text"] as? String ?? "", mine: author == myName)
            }
        }
        chat = await load("main")
        backstage = await load("backstage")
        if let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/host-identities"),
           let ids = (try? JSONSerialization.jsonObject(with: d)) as? [String] {
            hostIdentities = ids
        }
    }

    func sendChat(_ text: String, backstage toHosts: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let channel = toHosts ? "backstage" : "main"
        Task {
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/chat", ["text": t, "channel": channel])
                let id = r["id"] as? Int ?? Int.random(in: 1...Int.max)
                let author = r["author_name"] as? String ?? "Tú"
                let msg = ChatMsg(id: id, author: author, text: t, mine: true)
                if toHosts { backstage.append(msg) } else { chat.append(msg) }
                let payload: [String: Any] = ["type": "chat", "channel": channel, "id": id, "author": author, "text": t,
                                              "ts": ISO8601DateFormatter().string(from: Date())]
                if toHosts {
                    let targets = hostIdentities.filter { $0 != myIdentity }.map { LiveKit.Participant.Identity(from: $0) }
                    if let room, !targets.isEmpty, let data = try? JSONSerialization.data(withJSONObject: payload) {
                        try? await room.localParticipant.publish(data: data, options: DataPublishOptions(destinationIdentities: targets, reliable: true))
                    }
                } else {
                    send(payload)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func receiveChat(_ m: [String: Any]) {
        let id = m["id"] as? Int ?? Int.random(in: 1...Int.max)
        let msg = ChatMsg(id: id, author: m["author"] as? String ?? "?", text: m["text"] as? String ?? "", mine: false)
        if (m["channel"] as? String) == "backstage" {
            if !backstage.contains(where: { $0.id == id }) { backstage.append(msg) }
        } else if !chat.contains(where: { $0.id == id }) {
            chat.append(msg)
        }
        unreadChat += 1
    }

    // MARK: Levantar la mano y sacar a alguien

    func toggleHand() {
        myHand.toggle()
        hands[myIdentity] = myHand
        send(["type": "hand_raise", "identity": myIdentity, "up": myHand])
    }

    /// Solo quien creó la sala, como en la web.
    func kick(_ p: ProdPodClient.Person) {
        guard isOwner else { return }
        send(["type": "kick", "target_identity": "participant_\(p.id)"])
        Task {
            do {
                try await ProdPodClient.shared.send(method: "DELETE", path: "/api/sessions/\(session.id)/participants/\(p.id)")
                flash("Sacaste a \(p.display_name) de la sala")
                await loadParticipants()
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Transmitir en vivo (YouTube, Twitch…)

    func loadStreams() async {
        guard isOwner else { return }
        if rtmpPresets.isEmpty, let d = try? await ProdPodClient.shared.get("/api/rtmp-presets"),
           let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            rtmpPresets = list.map { $0.compactMapValues { $0 as? String } }
        }
        await refreshLive()
    }

    /// Confirma con el servidor que la transmisión sigue saliendo. Si la plataforma la rechazó
    /// (clave mala, directo no habilitado) o se cortó, se avisa con el motivo.
    func refreshLive() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/streams"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        let prev = liveStream?["id"] as? Int
        liveStream = list.first { ["active", "starting"].contains($0["status"] as? String ?? "") }
        if let prev, liveStream == nil,
           let row = list.first(where: { ($0["id"] as? Int) == prev }), (row["status"] as? String) == "failed" {
            error = (row["error"] as? String) ?? "La transmisión se cortó."
        }
    }

    func startStream(platform: String, url: String, key: String, layout: String) {
        Task {
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/streams",
                                                                ["platform": platform, "rtmp_url": url, "stream_key": key, "layout": layout])
                liveStream = r
                flash("Transmitiendo en vivo")
            } catch { self.error = "No se pudo transmitir: \(error.localizedDescription)" }
        }
    }

    func stopStream() {
        guard let id = liveStream?["id"] as? Int else { return }
        Task {
            _ = try? await ProdPodClient.shared.send(method: "DELETE", path: "/api/sessions/\(session.id)/streams/\(id)")
            liveStream = nil
            flash("Transmisión detenida")
        }
    }
}

// MARK: - Paquetes de sesión (exportar / importar)

enum SessionBundle {
    /// Descarga la sala completa (grabaciones, sonidos y datos) como .zip.
    @MainActor
    static func export(_ s: ProdPodClient.Session) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sala-\(s.id).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return nil }
        let data = try await ProdPodClient.shared.get("/api/sessions/\(s.id)/export-bundle")
        try data.write(to: dest)
        return dest
    }

    /// Sube un .zip de sala y la crea en prodPod.
    @MainActor
    static func importZip() async throws -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Elige el paquete de una sala de prodPod (.zip)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = try Data(contentsOf: url)
        let (code, obj) = try await ProdPodClient.shared.multipart("/api/sessions/import", fields: [:], fileField: "file",
                                                                  fileName: url.lastPathComponent, fileData: data)
        guard (200..<300).contains(code) else {
            throw PrePodClient.Failure(message: obj["error"] as? String ?? "prodPod respondió \(code)")
        }
        return true
    }
}
