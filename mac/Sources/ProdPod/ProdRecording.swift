import Foundation
import AVFoundation
import AppKit
import LiveKit

/// Diccionario que cruza de hilo (los mensajes de la sala llegan fuera del hilo principal).
struct SendableDict: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

/// Voz tal como sale a la sala (sin eco): con parlantes, esto es lo que se graba.
final class CleanVoiceFeed: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: FragmentRecorder?
    func attach(_ r: FragmentRecorder?) { lock.withLock { recorder = r } }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let r = lock.withLock({ recorder }) else { return }
        // Hora de la muestra en el mismo reloj que la cámara
        let dur = Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let pts = CMTimeSubtract(now, CMTime(seconds: dur, preferredTimescale: 48_000))
        if let sb = PCM.sampleBuffer(pcmBuffer, at: pts) { r.appendAudio(sb) }
    }
}

extension ProdStudio {
    // MARK: Prueba inicial (igual que la web)

    func runPreflight() async {
        preflight = "Midiendo tu conexión…"
        let camHeight = Int(captureSize.split(separator: "×").last ?? "1080") ?? 1080
        do {
            let mbps = try await ProdPodClient.shared.uploadTest()
            uploadMbps = mbps
            var q = RecordingQuality.decide(uploadMbps: mbps, cameraHeight: camHeight)
            if let mh = session.limits?.max_height, q.height > mh { q = RecordingQuality(height: 720, bitrate: 2_500_000) }
            recMax = q
            recQuality = q
            preflight = "Tu grabación irá en \(q.label) · subida \(String(format: "%.1f", mbps)) Mbps"
        } catch {
            let q = RecordingQuality(height: 720, bitrate: 2_500_000)
            recMax = q; recQuality = q
            preflight = "No pude medir tu conexión: grabaré en 720p para ir seguro."
        }
    }

    /// Solo se puede bajar la calidad, nunca subir por encima de lo que dio la prueba.
    var recChoices: [RecordingQuality] {
        RecordingQuality.options.filter { $0.height < recMax.height || ($0.height == recMax.height && $0.bitrate <= recMax.bitrate) }
    }

    // MARK: Al entrar

    func afterJoin() async {
        _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/recording-quality",
                                                    ["quality": recQuality.label, "bitrate": recQuality.bitrate])
        await ChunkUploader.shared.setProgress { [weak self] file, sent, total, done, msg in
            Task { @MainActor in self?.uploadProgress(file: file, sent: sent, total: total, done: done, message: msg) }
        }
        installKeyMonitor()
        updateDirectorPresence()
        await loadSounds()
        await loadSponsors()
        await loadChat()
        await loadStreams()
    }

    func updateDirectorPresence() {
        let inRoom = room?.remoteParticipants.values.contains { $0.identity?.stringValue.hasPrefix("director_") ?? false } ?? false
        directorPresent = inRoom        // igual que la web: solo cuenta si está conectado ahora
    }

    // MARK: Mensajes de la sala

    func send(_ msg: [String: Any]) {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        Task { try? await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: true)) }
    }

    func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready_toggle":
            if let id = m["identity"] as? String { readyMap[id] = (m["ready"] as? Bool) ?? false }
            if isOwner && !directorPresent { maybeFireCountdown() }
        case "ready_request":           // el director pregunta quién está preparado
            send(["type": "ready_toggle", "identity": myIdentity, "ready": ownReady])
        case "countdown_start":
            if let ms = (m["start_at_ms"] as? Double) ?? (m["start_at_ms"] as? Int).map(Double.init) { beginCountdown(ms) }
        case "recording_stop":
            Task { await finishRecording(local: false) }
        case "practice_mode":
            practice = (m["active"] as? Bool) ?? false
        case "sound_trigger":
            if let f = m["filename"] as? String { play(f) }
        case "chat":
            receiveChat(m)
        case "overlay_inject":
            if var o = Overlay.from(m) {
                overlays.removeAll { $0.id == o.id }
                overlays.append(o)
                let sid = session.id
                Task {
                    o.image = await OverlayImages.load(sessionId: sid, filePath: o.filePath)
                    if let i = overlays.firstIndex(where: { $0.id == o.id }) { overlays[i].image = o.image }
                }
            }
        case "overlay_remove":
            if let id = m["event_id"] as? Int { overlays.removeAll { $0.id == id } }
        case "director_chat":
            if let t = m["text"] as? String, !t.isEmpty { flash("Director: \(t)") }
        case "hand_raise":
            if let id = m["identity"] as? String {
                let up = (m["up"] as? Bool) ?? false
                hands[id] = up
                if up { flash("\(people.first(where: { $0.id == id })?.name ?? "Alguien") levantó la mano") }
            }
        case "upload_status":
            if let id = m["identity"] as? String {
                let pending = (m["pending"] as? Int).map(Int64.init) ?? (m["pending"] as? Double).map { Int64($0) }
                let eta = (m["eta"] as? Int) ?? (m["eta"] as? Double).map { Int($0) }
                remoteUploads[id] = UploadState(state: m["state"] as? String ?? "", bytes: Int64(m["bytes"] as? Int ?? 0),
                                                pending: pending, eta: eta)
            }
        case "director_cue":
            let target = m["target"] as? String ?? "all"
            if target == "all" || target == myIdentity {
                var c = m["cue"] as? String ?? ""
                if c == "CUSTOM", let t = m["text"] as? String, !t.isEmpty { c = t }
                cue = c
                Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if cue == c { cue = nil } }
            }
        case "teleprompter":
            handleTeleprompter(m)
        case "ifb_start":
            let t = m["targets"]
            ifbOn = (t as? String) == "all_hosts" || ((t as? [String])?.contains(myIdentity) ?? false)
            applyIFB()
        case "ifb_stop":
            ifbOn = false
            applyIFB()
        case "force_mute":
            if (m["target"] as? String) == myIdentity, micOn { toggleMic(); flash("El director silenció tu micrófono") }
        case "kick":
            if (m["target_identity"] as? String) == myIdentity {
                error = "Te sacaron de la sala."
                Task { await leave() }
            }
        default: break
        }
    }

    /// La voz del director solo se oye mientras te habla al oído.
    func applyIFB() {
        guard let room else { return }
        for p in room.remoteParticipants.values where p.identity?.stringValue.hasPrefix("director_") ?? false {
            for pub in p.audioTracks { (pub.track as? RemoteAudioTrack)?.volume = ifbOn ? 1 : 0 }
        }
        if ifbOn { flash("El director te está hablando") }
    }

    // MARK: Preparado y cuenta regresiva

    func toggleReady() {
        guard !recording, countdown == nil else { return }
        ownReady.toggle()
        readyMap[myIdentity] = ownReady
        send(["type": "ready_toggle", "identity": myIdentity, "ready": ownReady])
        if isOwner && !directorPresent { maybeFireCountdown() }
    }

    /// Sin director, el dueño de la sala arranca cuando todos los conectados están listos.
    func maybeFireCountdown() {
        guard !recording, countdown == nil, !sessionEnded || practice, let room else { return }
        var ids = [myIdentity]
        ids += room.remoteParticipants.values.compactMap { $0.identity?.stringValue }.filter { !$0.hasPrefix("director_") }
        guard ids.allSatisfy({ readyMap[$0] == true }) else { return }
        let startAt = Date().timeIntervalSince1970 * 1000 + 3500
        send(["type": "countdown_start", "start_at_ms": startAt])
        beginCountdown(startAt)
    }

    func beginCountdown(_ startAtMs: Double) {
        guard !recording, countdown == nil else { return }
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let rem = startAtMs - Date().timeIntervalSince1970 * 1000
                if rem <= 0 {
                    t.invalidate()
                    self.countdown = 0
                    await self.beginRecordingNow()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    self.countdown = nil
                } else {
                    self.countdown = Int((rem / 1000).rounded(.up))
                }
            }
        }
    }

    // MARK: Grabar

    func beginRecordingNow() async {
        guard !recording else { return }
        if isOwner && !practice {
            do { _ = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/start") }
            catch {
                // Plan Gratis sin episodios: no se graba, y se avisa a los demás para que tampoco
                if error.localizedDescription.hasPrefix("El plan") {
                    send(["type": "recording_stop"])
                    self.error = error.localizedDescription
                    return
                }
            }
        }
        planWarned = false
        planStopped = false
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("postPod/grabaciones")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let file = dir.appendingPathComponent("sala\(session.id)_\(practice ? "ensayo" : "toma")_\(f.string(from: Date())).mp4")
        do {
            try recorder.start(to: file, quality: recQuality)
        } catch {
            self.error = error.localizedDescription
            return
        }
        recordFile = file
        recordStart = Date()
        recSeconds = 0
        triggerLog = []
        firedSponsors = []
        if isOwner { Task { await loadTeleprompterScript() } }
        // Con audífonos: micrófono directo (mejor calidad). Con parlantes: la voz ya sin eco.
        let raw = headphones
        pipe.recordRawAudio = raw
        voiceFeed.attach(raw ? nil : recorder)
        pipe.recorder = recorder
        recording = true
        if screenOn { startScreenRecording() }
        if !practice {
            uploadSamples = []
            await ChunkUploader.shared.begin(sessionId: session.id, file: file)
            myUpload = UploadState(state: "streaming", bytes: 0)
            // Respaldo grabado por el servidor (red de seguridad si la subida no llega). Si está apagado no hace nada.
            let sid = session.id
            Task { _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(sid)/backup/start") }
        }
        flash(practice ? "Ensayo: se graba solo en tu Mac" : "Grabando")
    }

    /// Botón Detener (solo quien creó la sala, como en la web).
    func stopRecording() {
        guard recording else { return }
        Task {
            if isOwner && !practice { _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/stop") }
            send(["type": "recording_stop"])
            await finishRecording(local: true)
        }
    }

    func finishRecording(local: Bool) async {
        guard recording else { return }
        recording = false
        pipe.recorder = nil
        voiceFeed.attach(nil)
        await recorder.finish()
        await stopScreenRecording()
        let wasPractice = practice
        if let file = recordFile, !wasPractice {
            await ChunkUploader.shared.markDone(file: file, duration: recorder.duration)
            myUpload = UploadState(state: "finalizing", bytes: myUpload?.bytes ?? 0)
            sessionEnded = true
            if !triggerLog.isEmpty {
                _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/sound-triggers", ["triggers": triggerLog])
            }
        }
        ownReady = false
        readyMap = [:]
        flash(wasPractice ? "Ensayo terminado" : "Grabación terminada: subiendo tu pista")
        // Como en la web: la grabación ya se detuvo (las pistas quedan sincronizadas); recién después de
        // avisar con una cuenta 3-2-1 se apagan cámara y micrófono, en vez de cortarlos de golpe.
        for n in [3, 2, 1] {
            endCountdown = n
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        endCountdown = nil
        if camOn { toggleCam() }
        if micOn { toggleMic() }
    }

    func togglePractice() {
        guard isOwner, !recording else { return }
        practice.toggle()
        send(["type": "practice_mode", "active": practice])
    }

    // MARK: Subida

    func uploadProgress(file: String, sent: Int64, total: Int64, done: Bool, message: String?) {
        guard file == recordFile?.path else { return }
        // Cuánto falta y en cuánto tiempo, con la velocidad real de los últimos ~30 s (lo mismo que manda la web)
        let now = Date()
        uploadSamples.append((now, sent))
        uploadSamples.removeAll { now.timeIntervalSince($0.at) > 30 }
        let pending = max(0, total - sent)
        var eta: Int?
        if let first = uploadSamples.first, now.timeIntervalSince(first.at) >= 3, sent > first.sent {
            let speed = Double(sent - first.sent) / now.timeIntervalSince(first.at)
            eta = Int((Double(pending) / speed).rounded(.up))
        }
        let state = done ? "done" : (message != nil ? "error" : (recording ? "streaming" : "finalizing"))
        myUpload = UploadState(state: state, bytes: sent, total: total, message: message, pending: done ? 0 : pending, eta: done ? 0 : eta)
        send(["type": "upload_status", "identity": myIdentity, "state": done ? "done" : (message != nil ? "error" : "streaming"),
              "bytes": sent, "pending": done ? 0 : pending, "eta": done ? 0 : (eta.map { $0 as Any } ?? NSNull())])
        if done { flash("Tu pista ya está en prodPod") }
    }

    var canExport: Bool {
        isOwner && sessionEnded && !recording && !directorPresent && myUpload?.state == "done"
    }

    func exportToPost() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/recordings/export-to-postpod")
                if let e = r["error"] as? String { exportState = e; return }
                let n = r["exported"] as? Int ?? 0
                exportState = n > 0 ? "Enviado a postPod (\(n) \(n == 1 ? "pista" : "pistas")). En post, tócalo en “En postPod web” → Traer a la Mac."
                                    : "Ya estaba en postPod (se envía solo cuando terminan de subir todas las pistas)."
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Momentos

    func markMoment() {
        guard recording, !practice else { return }
        let off = Date().timeIntervalSince(recordStart)
        Task {
            _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/chapter-markers",
                                                         ["tl_offset_seconds": off, "label": ""])
            flash("Momento marcado en \(clock(Int(off)))")
        }
    }

    func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    // MARK: Soundboard

    func loadSounds() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/sounds"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        var pads: [Pad] = []
        for s in list where !((s["director_only"] as? Bool) ?? ((s["director_only"] as? Int) == 1)) {
            guard let id = s["id"] as? Int, let fn = s["filename"] as? String, let url = s["url"] as? String else { continue }
            pads.append(Pad(id: id, name: s["name"] as? String ?? fn, filename: fn,
                            key: (s["shortcut_key"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() },
                            color: s["color"] as? String, url: url))
        }
        sounds = pads
        for p in pads where players[p.filename] == nil {
            if let data = try? await ProdPodClient.shared.get(p.url), let pl = try? AVAudioPlayer(data: data) {
                pl.prepareToPlay()
                players[p.filename] = pl
            }
        }
    }

    func play(_ filename: String) {
        guard let p = players[filename] else { return }
        p.currentTime = 0
        p.play()
    }

    /// Suena para todos. Con ⌥ suena solo para ti (para escucharlo antes).
    func trigger(_ pad: Pad, onlyMe: Bool = false) {
        play(pad.filename)
        guard !onlyMe else { return }
        if recording && !practice {
            triggerLog.append(["filename": pad.filename, "tl_offset_seconds": Date().timeIntervalSince(recordStart)])
        }
        var m: [String: Any] = ["type": "sound_trigger", "filename": pad.filename]
        if let k = pad.key { m["key"] = k }
        send(m)
    }

    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            // No interferir si estás escribiendo
            if NSApp.keyWindow?.firstResponder is NSTextView { return ev }
            if ev.modifierFlags.intersection([.command, .control]).isEmpty,
               let ch = ev.charactersIgnoringModifiers?.lowercased(),
               let pad = self.sounds.first(where: { $0.key == ch }) {
                self.trigger(pad, onlyMe: ev.modifierFlags.contains(.option))
                return nil
            }
            return ev
        }
    }

    func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    // MARK: Sponsors en pantalla

    func loadSponsors() async {
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/chapter-markers"),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return }
        sponsors = list.compactMap { m in
            guard (m["kind"] as? String) == "sponsor", let name = m["sponsor_name"] as? String, !name.isEmpty,
                  let id = m["id"] as? Int else { return nil }
            let at = (m["planned_offset_seconds"] as? Double) ?? (m["tl_offset_seconds"] as? Double) ?? 0
            return SponsorMark(id: id, name: name, copy: m["sponsor_copy"] as? String ?? "", at: at)
        }.sorted { $0.at < $1.at }
    }

    /// Cada décima de segundo mientras se graba: reloj, avisos de sponsor y momento automático.
    func tickRecording() {
        if !overlays.isEmpty { overlays.removeAll { ($0.expires ?? .distantFuture) < Date() } }
        guard recording else { return }
        let t = Date().timeIntervalSince(recordStart)
        recSeconds = Int(t)
        // Plan Gratis: aviso un minuto antes y corte al llegar al máximo (lo detiene quien creó la sala)
        if let maxS = session.limits?.max_record_seconds, maxS > 0, !practice {
            let name = session.limits?.plan_name ?? "Gratis"
            if !planWarned, t >= Double(maxS - 60) {
                planWarned = true
                flash("Queda 1 minuto: el plan \(name) graba hasta \(maxS / 60) minutos")
            }
            if isOwner, t >= Double(maxS), !planStopped {
                planStopped = true
                flash("Llegaste a los \(maxS / 60) minutos del plan \(name): la grabación se detuvo")
                stopRecording()
            }
        }
        tickTeleprompter(t)
        for s in sponsors where !firedSponsors.contains(s.id) {
            let left = s.at - t
            if left <= 60 && left > 0 && sponsorAlert?.id != s.id { sponsorAlert = s }
            if left <= 0 {
                firedSponsors.insert(s.id)
                sponsorAlert = s
                if !practice {
                    Task { _ = try? await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/chapter-markers",
                                                                        ["tl_offset_seconds": t, "label": "SPONSOR: \(s.name)"]) }
                }
                let id = s.id
                Task { try? await Task.sleep(nanoseconds: 15_000_000_000); if sponsorAlert?.id == id { sponsorAlert = nil } }
            }
        }
    }

    func delaySponsor(_ s: SponsorMark) {
        Task {
            _ = try? await ProdPodClient.shared.send(method: "PATCH", path: "/api/sessions/\(session.id)/chapter-markers/\(s.id)/delay",
                                                     json: ["delay_seconds": 90])
            if let i = sponsors.firstIndex(where: { $0.id == s.id }) { sponsors[i].at += 90 }
            if sponsorAlert?.id == s.id { sponsorAlert = nil }
        }
    }
}
