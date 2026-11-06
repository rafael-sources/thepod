import Foundation
import AppKit
import LiveKit
import UniformTypeIdentifiers

extension ProdStudio {
    // MARK: Screen sharing

    /// Opens the macOS picker and shares (or only records) the chosen screen or window.
    func shareScreen(recordOnly: Bool) {
        guard !screenOn else { return }
        if remoteScreen != nil && !recordOnly {
            error = String(localized: "\(remoteScreen?.name ?? String(localized: "Otra persona")) ya está compartiendo pantalla. Solo una a la vez.")
            return
        }
        Task {
            guard let filter = await screen.pick() else { return }
            do {
                try await screen.start(filter: filter, room: room, recorder: nil, recordOnly: recordOnly)
                screenOn = true
                if recording { startScreenRecording() }
                flash(recordOnly ? String(localized: "Grabando tu pantalla (no se muestra en la sala)") : String(localized: "Compartiendo tu pantalla"))
            } catch {
                self.error = String(localized: "No se pudo compartir la pantalla: \(error.localizedDescription)")
            }
        }
    }

    func stopScreen() {
        Task {
            await stopScreenRecording()
            await screen.stop(room: room)
            screenOn = false
            flash(String(localized: "Dejaste de compartir la pantalla"))
        }
    }

    /// The screen is recorded while the episode is recorded (so it stays aligned in post).
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
            self.error = String(localized: "No se pudo grabar la pantalla: \(error.localizedDescription)")
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

    // MARK: Raise hand and remove someone

    func toggleHand() {
        myHand.toggle()
        hands[myIdentity] = myHand
        send(["type": "hand_raise", "identity": myIdentity, "up": myHand])
    }

    /// Only whoever created the room, as on the web.
    func kick(_ p: ProdPodClient.Person) {
        guard isOwner else { return }
        send(["type": "kick", "target_identity": "participant_\(p.id)"])
        Task {
            do {
                try await ProdPodClient.shared.send(method: "DELETE", path: "/api/sessions/\(session.id)/participants/\(p.id)")
                flash(String(localized: "Sacaste a \(p.display_name) de la sala"))
                await loadParticipants()
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Live streaming (YouTube, Twitch…)

    func loadStreams() async {
        guard isOwner else { return }
        if rtmpPresets.isEmpty, let d = try? await ProdPodClient.shared.get("/api/rtmp-presets"),
           let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            rtmpPresets = list.map { $0.compactMapValues { $0 as? String } }
        }
        await refreshLive()
    }

    /// Confirms with the server that the stream is still going out. If the platform rejected it
    /// (bad key, live not enabled) or it dropped, it notifies with the reason.
    func refreshLive() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/streams"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        let prev = liveStream?["id"] as? Int
        liveStream = list.first { ["active", "starting"].contains($0["status"] as? String ?? "") }
        if let prev, liveStream == nil,
           let row = list.first(where: { ($0["id"] as? Int) == prev }), (row["status"] as? String) == "failed" {
            error = (row["error"] as? String) ?? String(localized: "La transmisión se cortó.")
        }
    }

    func startStream(platform: String, url: String, key: String, layout: String) {
        Task {
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/streams",
                                                                ["platform": platform, "rtmp_url": url, "stream_key": key, "layout": layout])
                liveStream = r
                flash(String(localized: "Transmitiendo en vivo"))
            } catch { self.error = String(localized: "No se pudo transmitir: \(error.localizedDescription)") }
        }
    }

    func stopStream() {
        guard let id = liveStream?["id"] as? Int else { return }
        Task {
            _ = try? await ProdPodClient.shared.send(method: "DELETE", path: "/api/sessions/\(session.id)/streams/\(id)")
            liveStream = nil
            flash(String(localized: "Transmisión detenida"))
        }
    }
}

// MARK: - Session bundles (export / import)

enum SessionBundle {
    /// Downloads the whole room (recordings, sounds and data) as .zip.
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

    /// Uploads a room .zip and creates it in prodPod.
    @MainActor
    static func importZip() async throws -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = String(localized: "Elige el paquete de una sala de prodPod (.zip)")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = try Data(contentsOf: url)
        let (code, obj) = try await ProdPodClient.shared.multipart("/api/sessions/import", fields: [:], fileField: "file",
                                                                  fileName: url.lastPathComponent, fileData: data)
        guard (200..<300).contains(code) else {
            throw PrePodClient.Failure(message: obj["error"] as? String ?? String(localized: "prodPod respondió \(code)"))
        }
        return true
    }
}
