import Foundation
import SwiftUI
import AppKit
import AVFoundation

/// Headless end-to-end run used for development:
///   postPod.app/Contents/MacOS/postPod --selftest <file-or-zip> [more files…]
/// Imports, fixes (enhance + transcribe + silences/fillers), suggests reels and exports
/// a landscape video, the first reel (vertical) and the audio. Prints progress and a JSON report.
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--render")
            || CommandLine.arguments.contains("--prepod-test") || CommandLine.arguments.contains("--postpod-test") || CommandLine.arguments.contains("--pre-test") || CommandLine.arguments.contains("--update-test") || CommandLine.arguments.contains("--pre-snapshot") || CommandLine.arguments.contains("--prod-test") || CommandLine.arguments.contains("--prod-snapshot") || CommandLine.arguments.contains("--rec-test") || CommandLine.arguments.contains("--prod-recs") || CommandLine.arguments.contains("--cintillo-snapshot") || CommandLine.arguments.contains("--director-snapshot") || CommandLine.arguments.contains("--ama-snapshot") || CommandLine.arguments.contains("--post-snapshot") || CommandLine.arguments.contains("--tts") || CommandLine.arguments.contains("--intro-snapshot") || CommandLine.arguments.contains("--intro-frames") || CommandLine.arguments.contains("--brand-kit") || CommandLine.arguments.contains("--extras-test") || CommandLine.arguments.contains("--sensitive-test") || CommandLine.arguments.contains("--stems-test") || CommandLine.arguments.contains("--sync-test") || CommandLine.arguments.contains("--frame-test") || CommandLine.arguments.contains("--meter-test") || CommandLine.arguments.contains("--filler-test") || CommandLine.arguments.contains("--miccheck-test") || CommandLine.arguments.contains("--chapters-test") || CommandLine.arguments.contains("--enhance-test") || CommandLine.arguments.contains("--pub-snapshot") || CommandLine.arguments.contains("--cover-scan") || CommandLine.arguments.contains("--voice-chain-test") || CommandLine.arguments.contains("--studio-snapshot")
    }

    /// Capturas de pubPod con los episodios y las redes reales (solo lectura: no publica nada).
    @MainActor
    static func pubSnapshot(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render(_ name: String, reel: Bool, after: Double) {
            PubHomeView.snapshotReel = reel
            let host = NSHostingView(rootView: PubHomeView()
                .environmentObject(AppModel())
                .frame(width: 1440, height: 900)
                .preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                    print("snapshot \(name)")
                }
                win.orderOut(nil)
            }
        }
        render("1-episodio", reel: false, after: 14)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { render("2-reel", reel: true, after: 8) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 24) { PubHomeView.snapshotPanel = "reels"; render("3-panel", reel: true, after: 6) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 31) { fflush(stdout); exit(0) }
    }

    /// Capturas de la sección pre, con datos reales y sin mostrar ventanas (solo lectura; deja las preferencias como estaban).
    @MainActor
    static func preSnapshot(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let oldTab = d.object(forKey: "prePestana"), oldCal = d.object(forKey: "preVistaCalendario")
        d.set(0, forKey: "prePestana"); d.set(false, forKey: "preVistaCalendario")
        let oldPod = d.object(forKey: "prePodcast")
        let model = PreModel()
        if let j = CommandLine.arguments.firstIndex(of: "--podcast"), CommandLine.arguments.count > j + 1 {
            model.slug = CommandLine.arguments[j + 1]
        }
        let host = NSHostingView(rootView: PreHomeView(model: model)
            .environmentObject(AppModel())
            .frame(width: 1440, height: 900)
            .background(Theme.background)
            .preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        func shot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            print("snapshot \(name)")
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        Task { @MainActor in
            await wait(7)
            print("podcasts: " + model.podcasts.map { "\($0.slug) (\($0.name))" }.joined(separator: ", "))
            shot("1-tablero")
            d.set(true, forKey: "preVistaCalendario"); await wait(2); shot("2-calendario")
            d.set(false, forKey: "preVistaCalendario")
            if let e = model.nextUp ?? model.episodes.first(where: { $0.statusValue != .archived }) {
                model.open = e
                for (i, n) in ["3-guion", "4-rundown", "5-invitados", "6-ideas", "7-publicacion"].enumerated() {
                    d.set(i, forKey: "prePestana"); await wait(4); shot(n)
                }
            }
            if let oldPod { d.set(oldPod, forKey: "prePodcast") } else { d.removeObject(forKey: "prePodcast") }
            if let oldTab { d.set(oldTab, forKey: "prePestana") } else { d.removeObject(forKey: "prePestana") }
            if let oldCal { d.set(oldCal, forKey: "preVistaCalendario") } else { d.removeObject(forKey: "preVistaCalendario") }
            fflush(stdout); exit(0)
        }
    }

    /// Capturas de prod sin cámara ni micrófono (no pide permisos, no entra a ninguna sala).
    @MainActor
    static func prodSnapshot(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel()
        let host = NSHostingView(rootView: ProdHomeView().environmentObject(app)
            .frame(width: 1440, height: 900).background(Theme.background).preferredColorScheme(.dark))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        func shot(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            print("snapshot \(name)")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            shot("1-salas")
            if let s = try? await ProdPodClient.shared.sessions().first(where: { $0.status != "finished" }) {
                let st = ProdStudio(session: s)
                st.cameras = AVDevices.cameras
                st.mics = AVDevices.microphones
                st.cameraId = st.cameras.first?.uniqueID ?? ""
                st.micId = st.mics.first?.uniqueID ?? ""
                st.previewReady = true
                st.camOn = false
                st.micLevel = -30
                await st.loadParticipants()
                app.studio = st
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                shot("2-antes-de-entrar")
                app.studio = nil
            }
            fflush(stdout); exit(0)
        }
    }

    /// Graba 6 s de imagen sintética en MP4 por fragmentos y lo sube por partes a una sala de prueba.
    @MainActor
    static func recTest(_ sid: Int) {
        Task { @MainActor in
            let rec = FragmentRecorder()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-test-\(sid).mp4")
            do { try rec.start(to: url, quality: RecordingQuality(height: 1080, bitrate: 5_000_000)) }
            catch { print("ERROR start \(error)"); exit(1) }
            await ChunkUploader.shared.setProgress { f, sent, total, done, msg in
                print("subida \(sent)/\(total) \(done ? "LISTA" : "") \(msg ?? "")"); fflush(stdout)
            }
            await ChunkUploader.shared.begin(sessionId: sid, file: url)
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                                               kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pool)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let clock = CMClockGetHostTimeClock()
            for i in 0..<180 {
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
                if let pb {
                    CVPixelBufferLockBaseAddress(pb, [])
                    memset(CVPixelBufferGetBaseAddress(pb), Int32((i * 3) % 255), CVPixelBufferGetDataSize(pb))
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    var desc: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &desc)
                    var t = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMClockGetTime(clock), decodeTimeStamp: .invalid)
                    var sb: CMSampleBuffer?
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: desc!, sampleTiming: &t, sampleBufferOut: &sb)
                    if let sb { rec.appendVideo(sb) }
                }
                let ab = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600)!
                ab.frameLength = 1600
                if let d = ab.floatChannelData { for k in 0..<1600 { d[0][k] = 0.2 * sinf(Float(i * 1600 + k) * 0.0575) } }
                let pts = CMTimeSubtract(CMClockGetTime(clock), CMTime(seconds: 1600.0 / 48000, preferredTimescale: 48000))
                if let asb = PCM.sampleBuffer(ab, at: pts) { rec.appendAudio(asb) }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            await rec.finish()
            print("local: \(rec.bytesWritten) bytes, \(String(format: "%.2f", rec.duration)) s → \(url.path)")
            await ChunkUploader.shared.markDone(file: url, duration: rec.duration)
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await ChunkUploader.shared.pending().isEmpty { break }
            }
            print(await ChunkUploader.shared.pending().isEmpty ? "OK subida finalizada" : "ERROR la subida no terminó")
            fflush(stdout); exit(0)
        }
    }

    /// Capturas de amaPod con datos de ejemplo (no abre ningún evento; solo lee tu lista de eventos, sin cambiar nada).
    @MainActor
    static func amaSnapshot(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let oldTab = defaults.object(forKey: "amaPestana")
        Task { @MainActor in
            do { let evs = try await AmaClient.shared.events(); print("amaPod OK: \(evs.count) eventos") }
            catch { print("amaPod ERROR: \(error.localizedDescription)") }
            let ev = AmaClient.Event(id: 7, title: "Pregúntanos lo que quieras — Lee La Letra Chica", description: "Contratos, letra chica y todo lo que nunca te explicaron.",
                                     status: "active", chat_mode: "moderated", like_count: 128, spectator_count: 342)
            let s = AmaStudio(event: ev)
            func person(_ id: Int, _ n: String, _ st: String, _ pos: Int?, _ q: [String], pre: Int = 0) -> AmaClient.Person {
                AmaClient.Person(id: id, display_name: n, status: st, queue_position: pos, is_preconnected: pre, is_censored: 0, questions: q)
            }
            s.queue = [
                person(11, "Carla Méndez", "on_air", nil, ["¿Qué cláusula debo revisar primero en un contrato de alquiler?", "¿Sirve un contrato firmado por WhatsApp?"]),
                person(12, "Luis Andrade", "in_queue", 1, ["¿Me pueden cobrar una multa que no estaba en el contrato?"], pre: 1),
                person(13, "Ana Torres", "in_queue", 2, [], pre: 1),
                person(14, "Pedro Salas", "in_queue", 3, ["¿Qué hago si el banco cambió la tasa sin avisar?"]),
            ]
            s.requests = [person(15, "María José", "pending", nil, ["¿Cómo leo la letra chica de un seguro médico?", "¿Qué es una cláusula abusiva?"]),
                          person(16, "Pedro Paz", "pending", nil, [])]
            s.chat = [AmaClient.Message(id: 1, sender_name: "Sofía", is_host: 0, message: "¡Saludos desde Quito!"),
                      AmaClient.Message(id: 2, sender_name: "host", is_host: 1, message: "Bienvenidos, ya empezamos con las preguntas"),
                      AmaClient.Message(id: 3, sender_name: "Lucía", is_host: 0, message: "¿Cómo empezaron el podcast?", is_approved: 0, pending: true, can_block: true)]
            s.likes = 128; s.spectators = 342; s.recording = true
            s.phase = .live
            let host = NSHostingView(rootView: AmaStudioView(studio: s, preview: true)
                .environmentObject(AppModel()).frame(width: 1440, height: 900).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()
            func shot(_ name: String) async {
                try? await Task.sleep(nanoseconds: 900_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                    print("snapshot \(name)")
                }
            }
            for (i, name) in ["1-solicitudes", "2-cola", "3-chat", "4-compartir"].enumerated() {
                defaults.set(i, forKey: "amaPestana"); await shot(name)
            }
            s.phase = .prejoin; await shot("5-antes")
            if let oldTab { defaults.set(oldTab, forKey: "amaPestana") } else { defaults.removeObject(forKey: "amaPestana") }
            fflush(stdout); exit(0)
        }
    }

    /// Capturas del cuarto de control con datos de ejemplo (no entra a ninguna sala; solo lee la marca del podcast).
    @MainActor
    static func directorSnapshot(slug: String, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = ProdPodClient.Session(id: 0, title: "Ep 15: Lo que no se dice en las reuniones de trabajo")
        s.source_slug = slug
        let defaults = UserDefaults.standard
        let oldTab = defaults.object(forKey: "directorPestana")
        Task { @MainActor [s] in
            var s = s
            if let list = try? await PrePodClient.shared.podcasts(),
               let m = list.first(where: { $0.slug == slug }) ?? list.first(where: { $0.slug.contains(slug) || $0.name.lowercased().contains(slug.lowercased()) }) {
                s.source_slug = m.slug
                print("podcast: \(m.slug)")
            }
            let d = DirectorStudio(session: s)
            await d.loadBranding()
            d.connected = true
            d.participants = [
                ProdPodClient.Person(id: 1, display_name: "Ana Torres", role: "host", recording_quality: "1080p"),
                ProdPodClient.Person(id: 2, display_name: "María Fernanda", role: "co-host", recording_quality: "1080p"),
                ProdPodClient.Person(id: 3, display_name: "Invitado Especial", role: "guest", recording_quality: "720p"),
            ]
            d.feeds = [
                .init(id: "participant_1", pid: 1, name: "Ana Torres", camera: nil, screen: nil, speaking: true, micOn: true),
                .init(id: "participant_2", pid: 2, name: "María Fernanda", camera: nil, screen: nil, speaking: false, micOn: true),
                .init(id: "participant_3", pid: 3, name: "Invitado Especial", camera: nil, screen: nil, speaking: false, micOn: false),
            ]
            d.readyMap = ["participant_1": true, "participant_2": true]
            d.recording = true; d.recSeconds = 754
            d.uploads = ["participant_1": "uploading", "participant_2": "done"]
            d.uploadBytes = ["participant_1": 182_000_000, "participant_2": 240_000_000]
            d.chat = [(id: 1, author: "María Fernanda", text: "¿Cuánto nos queda para el corte?"), (id: 2, author: "Director", text: "Unos 5 minutos")]
            if let sp = d.sponsors.first {
                d.overlays = [Overlay(id: 9, kind: "sponsor", title: sp.name, text: sp.copy.isEmpty ? "Gracias por acompañarnos" : sp.copy,
                                      filePath: nil, image: d.sponsorLogo(sp), expires: Date().addingTimeInterval(12))]
            }
            let host = NSHostingView(rootView: DirectorView(dir: d, preview: true)
                .environmentObject(AppModel())
                .frame(width: 1440, height: 900)
                .preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()
            for (i, name) in ["1-cintillos", "2-avisos", "3-sala", "4-chat"].enumerated() {
                defaults.set(i, forKey: "directorPestana")
                try? await Task.sleep(nanoseconds: 900_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                    print("snapshot \(name)")
                }
            }
            if let oldTab { defaults.set(oldTab, forKey: "directorPestana") } else { defaults.removeObject(forKey: "directorPestana") }
            fflush(stdout); exit(0)
        }
    }

    /// Editor de postPod (Arreglar y Exportar) con un proyecto real, en una ventana fuera de la pantalla.
    @MainActor
    /// "--studio-snapshot <slug> <carpeta>": la ventana del estudio y el editor del EQ, en PNG.
    static func studioSnapshot(slug: String, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            do {
                let app = AppModel()
                var p = try ProjectStore.load(slug: slug)
                // Una voz «ajustada en el estudio» para ver la etiqueta y los inserts encendidos
                if !p.lanes.isEmpty {
                    var c = ChainSettings.preset(VoiceEQ.preset("clear"))
                    c.bands.append(EQBand(kind: .highshelf, freq: 9000, gain: 2.5, q: 0.7))
                    c.compressorOn = true; c.ratio = 4; c.gateOn = true
                    p.lanes[0].chain = c
                }
                let session = ProjectSession(project: p, app: app)
                app.session = session
                @MainActor func shoot(_ view: some View, _ name: String, w: CGFloat, h: CGFloat) async {
                    let host = NSHostingView(rootView: AnyView(view.environmentObject(app).frame(width: w, height: h).preferredColorScheme(.dark)))
                    host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    win.appearance = NSAppearance(named: .darkAqua)
                    win.contentView = host
                    win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                    win.orderFrontRegardless()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                        print("snapshot \(name)"); fflush(stdout)
                    }
                    win.orderOut(nil)
                }
                await shoot(StudioRoot(), "estudio", w: 1280, h: 820)
                if let lane = p.lanes.first {
                    await shoot(InsertEditor(session: session, ref: .init(laneId: lane.id, kind: .eq)), "eq", w: 660, h: 520)
                    await shoot(InsertEditor(session: session, ref: .init(laneId: lane.id, kind: .compressor)), "compresor", w: 660, h: 330)
                }
                session.step = .fix
                await shoot(ProjectView(session: session), "limpiar-sonido", w: 1440, h: 900)
            } catch { print("ERROR \(error.localizedDescription)") }
            fflush(stdout); exit(0)
        }
    }

    static func postSnapshot(slug: String, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            do {
                let app = AppModel()
                var p = try ProjectStore.load(slug: slug)
                // --words <json>: pone esas palabras y los cortes automáticos (para ver sugerencias y revisión)
                let args = CommandLine.arguments
                if let j = args.firstIndex(of: "--words"), args.count > j + 1,
                   let d = try? Data(contentsOf: URL(fileURLWithPath: args[j + 1])),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                    let lanes = p.lanes.map(\.id)
                    p.words = arr.compactMap { o in
                        guard let w = o["w"] as? String, let s = o["s"] as? Double, let e = o["e"] as? Double, s < p.duration else { return nil }
                        let l = Int((o["lane"] as? Double) ?? 1)
                        return Word(w: w, s: s, e: e, lane: lanes.contains(l) ? l : (lanes.first ?? 1))
                    }
                    p.fix.removeWordFillers = true
                    p.cuts = EditEngine.fillerCuts(words: p.words, includeWordFillers: true) + EditEngine.repeatCuts(words: p.words)
                    p.fix.lastRun = Date()
                }
                let session = ProjectSession(project: p, app: app)
                let host = NSHostingView(rootView: ProjectView(session: session)
                    .environmentObject(app)
                    .frame(width: 1440, height: 900)
                    .preferredColorScheme(.dark))
                host.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                win.orderFrontRegardless()
                for (name, step) in [("1-arreglar", Step.fix), ("2-exportar", .export), ("3-capas", .layers), ("4-reels", .reels), ("5-aspecto", .look), ("6-cintillos", .cintillos)] {
                    session.step = step
                    if step == .cintillos, let c = session.project.cintillos.first {
                        session.selectedTrack = .cintillo(c.id)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        session.seek(timeline: c.start + 2, play: false)
                    }
                    if step == .layers, let o = session.project.overlays.first {
                        session.selectedTrack = .overlay(o.id)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        session.seek(timeline: o.start + 3, play: false)
                    }
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                        print("snapshot \(name)")
                    }
                    // Reels: borrar el que se está viendo con la pantalla abierta (antes la app se cerraba de golpe)
                    if step == .reels, let first = session.project.reels.first {
                        session.project.reels.removeAll { $0.id == first.id }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        host.layoutSubtreeIfNeeded()
                        print("reel borrado sin cerrar la app")
                    }
                }
            } catch { print("ERROR \(error.localizedDescription)") }
            fflush(stdout); exit(0)
        }
    }

    /// Cintillos con los logos y sponsors reales de un podcast (solo lectura, no entra a ninguna sala).
    @MainActor
    static func cintilloSnapshot(slug: String, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = ProdPodClient.Session(id: 0, title: "Prueba")
        s.source_slug = slug
        let d = DirectorStudio(session: s)
        Task { @MainActor in
            await d.loadBranding()
            let sp = d.sponsors.first
            let view = VStack(alignment: .leading, spacing: 30) {
                if let sp {
                    Cintillo(overlay: Overlay(id: 1, kind: "sponsor", title: sp.name, text: sp.copy.isEmpty ? "Gracias por acompañarnos" : sp.copy,
                                              filePath: nil, image: d.sponsorLogo(sp), expires: nil))
                }
                Cintillo(overlay: Overlay(id: 2, kind: "banner", title: d.podcastName, text: "Síguenos en todas las plataformas y comparte el episodio",
                                          filePath: nil, image: d.podcastLogo, expires: nil))
                Cintillo(overlay: Overlay(id: 3, kind: "segment", title: "La cláusula de la vulnerabilidad", text: "Por qué pedir ayuda nos parece una debilidad",
                                          filePath: nil, image: nil, expires: nil))
            }
            .padding(40)
            .frame(width: 1280, height: 720, alignment: .bottomLeading)
            .background(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            win.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 800_000_000)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("cintillos.png"))
            }
            // El mismo cintillo como sale en el video final (1920×1080)
            let logo = d.podcastLogo?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let spLogo = sp.flatMap { d.sponsorLogo($0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            var frame = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            if let a = TextRenderer.cintillo(title: d.podcastName, text: "Síguenos en todas las plataformas y comparte el episodio", tag: "AHORA",
                                             accent: NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1), logo: logo, width: 1152, height: 130) {
                frame = a.transformed(by: .init(translationX: 43, y: 43)).composited(over: frame)
            }
            if let sp, let b = TextRenderer.cintillo(title: sp.name, text: sp.copy, tag: "PATROCINA",
                                                     accent: NSColor(srgbRed: 0.7, green: 0.45, blue: 1, alpha: 1), logo: spLogo, width: 1152, height: 130) {
                frame = b.transformed(by: .init(translationX: 43, y: 220)).composited(over: frame)
            }
            if let c = TextRenderer.cintillo(title: "Segmento de prueba", text: "Sin logo", tag: "SEGMENTO",
                                             accent: NSColor(srgbRed: 0.4, green: 0.62, blue: 1, alpha: 1), logo: nil, width: 1152, height: 130) {
                frame = c.transformed(by: .init(translationX: 43, y: 400)).composited(over: frame)
            }
            let ctx = CIContext()
            if let cg = ctx.createCGImage(frame, from: frame.extent) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("cintillo-video.png"))
            }
            print("sponsors=\(d.sponsors.map(\.name)) logo=\(d.podcastLogo != nil)")
            fflush(stdout); exit(0)
        }
    }

    /// Diagnóstico del login a prePod con el mismo código que usa Ajustes (no imprime la contraseña).
    @MainActor
    static func prepodTest() {
        Task { @MainActor in
            let pw = Keychain.get("prepod-password")
            print("url=\(PrePodClient.baseURL) user=[\(PrePodClient.username)] pwLen=\(pw?.count ?? -1) pwUTF8=\(pw?.utf8.count ?? -1) nonASCII=\(pw?.unicodeScalars.contains { !$0.isASCII } ?? false)")
            do {
                let list = try await PrePodClient.shared.podcasts()
                print("OK podcasts=\(list.count)")
            } catch { print("ERROR \(error.localizedDescription)") }
            fflush(stdout); exit(0)
        }
    }

    /// Lista los proyectos de postPod web; con `--download <slug>` también baja el paquete (sin importarlo).
    @MainActor
    static func postpodTest() {
        Task { @MainActor in
            print("url=\(PostPodWebClient.baseURL) user=[\(PrePodClient.username)] configured=\(PrePodClient.isConfigured)")
            do {
                let list = try await PostPodWebClient.shared.projects()
                print("OK proyectos=\(list.count)")
                for p in list { print("  \(p.slug) · \(p.name) · \(p.owner ?? "-")") }
                let a = CommandLine.arguments
                if let i = a.firstIndex(of: "--download"), a.count > i + 1 {
                    let t0 = Date()
                    let url = try await PostPodWebClient.shared.downloadBundle(slug: a[i + 1]) { phase in
                        switch phase {
                        case .preparing(let f): print(String(format: "  %.0fs preparando %@", Date().timeIntervalSince(t0), f.map { "\(Int($0 * 100))%" } ?? "…"))
                        case .downloading(let got, let total): print(String(format: "  %.0fs %lld/%lld", Date().timeIntervalSince(t0), got, total))
                        case .reconnecting: print("  reconectando…")
                        }
                        fflush(stdout)
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    print("DESCARGADO \(url.path) \(size) bytes en \(Int(Date().timeIntervalSince(t0)))s")
                }
            } catch { print("ERROR \(error.localizedDescription)") }
            fflush(stdout); exit(0)
        }
    }

    /// postPod --render <slug> <start> <end> <landscape|vertical|square>: export a window of an existing project.
    @MainActor
    /// "--enhance-test <slug> <mediaId> <nivel>": limpia la voz de un archivo como «Sonido de estudio» y dice dónde quedó.
    static func enhanceTest() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--enhance-test"), a.count > i + 3, let mid = Int(a[i + 2]), let level = Int(a[i + 3]) else {
            print("uso: --enhance-test <slug> <mediaId> <nivel>"); exit(2)
        }
        Task { @MainActor in
            do {
                let p = try ProjectStore.load(slug: a[i + 1])
                guard let m = p.media.first(where: { $0.id == mid }) else { print("ERROR no existe ese archivo"); exit(1) }
                print("aislador de Apple: \(VoiceIsolation.isAvailable ? "sí" : "no")")
                let t0 = Date()
                let rel = try await AudioAnalysis.enhance(media: m, slug: p.id, level: level) { _ in }
                print(String(format: "OK %@ en %.0f s", ProjectStore.url(rel, in: p.id).path, Date().timeIntervalSince(t0)))
                exit(0)
            } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
        }
    }

    /// "--voice-chain-test": genera un tono de 300 Hz + 7 kHz, lo pasa por la cadena de voz con agudos a −12 dB
    /// y de-esser dentro de un export real (AVAssetExportSession + AVAudioMix + tap), y comprueba que la
    /// banda alta baje y la baja no. Es la misma ruta que la vista previa y el export de verdad.
    static func voiceChainTest() {
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicechain-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let src = dir.appendingPathComponent("tone.caf")
                let sr = 48_000.0, secs = 3.0
                let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
                let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
                let n = AVAudioFrameCount(sr * secs)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
                buf.frameLength = n
                for i in 0..<Int(n) {
                    let t = Double(i) / sr
                    buf.floatChannelData![0][i] = Float(0.25 * sin(2 * .pi * 300 * t) + 0.25 * sin(2 * .pi * 7000 * t))
                }
                try file.write(from: buf)

                func export(_ chainSettings: ChainSettings) async throws -> URL {
                    let asset = AVURLAsset(url: src)
                    let comp = AVMutableComposition()
                    let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    let st = try await asset.loadTracks(withMediaType: .audio).first!
                    try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: st, at: .zero)
                    let p = AVMutableAudioMixInputParameters(track: track)
                    let tap = ChainTap(laneId: 1, settings: chainSettings, keep: [EditEngine.Span(start: 0, end: secs)], introDuration: 0)
                    p.audioTapProcessor = tap.makeProcessor()
                    let mix = AVMutableAudioMix(); mix.inputParameters = [p]
                    let out = dir.appendingPathComponent("out-\(UUID().uuidString).m4a")
                    let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A)!
                    s.audioMix = mix; s.outputURL = out; s.outputFileType = .m4a
                    await s.export()
                    if let e = s.error { throw e }
                    _ = tap
                    return out
                }
                /// Energía (dB) de una banda, con una DFT directa a esa frecuencia (Goertzel) sobre el segundo central.
                func band(_ url: URL, hz: Double, third: Int = 1) throws -> Double {
                    let f = try AVAudioFile(forReading: url)
                    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
                    try f.read(into: b)
                    let x = b.floatChannelData![0], N = Int(b.frameLength)
                    let len = N / 3, a = third * len
                    let w = 2 * Double.pi * hz / f.processingFormat.sampleRate
                    var re = 0.0, im = 0.0
                    for i in 0..<len { let v = Double(x[a + i]); re += v * cos(w * Double(i)); im -= v * sin(w * Double(i)) }
                    let mag = sqrt(re * re + im * im) / Double(len) * 2
                    return 20 * log10(max(mag, 1e-9))
                }
                let flat = try await export(ChainSettings())
                var e = VoiceEQ(); e.high = -12; e.deess = true
                let cut = try await export(ChainSettings.preset(e))
                let lo0 = try band(flat, hz: 300), hi0 = try band(flat, hz: 7000)
                let lo1 = try band(cut, hz: 300), hi1 = try band(cut, hz: 7000)
                print(String(format: "plano: 300 Hz %.1f dB · 7 kHz %.1f dB", lo0, hi0))
                print(String(format: "agudos −12 + siseo: 300 Hz %.1f dB · 7 kHz %.1f dB", lo1, hi1))
                var ok = abs(lo0 - lo1) < 2 && (hi0 - hi1) > 8 && lo0 > -20
                // Automatización: la banda de 7 kHz baja de 0 a −18 dB a lo largo de los 3 s
                var auto = ChainSettings()
                let hb = EQBand(kind: .peak, freq: 7000, gain: 0, q: 0.8)
                auto.bands = [hb]
                auto.automation[ChainSettings.bandGain(hb)] = [AutoPoint(t: 0, v: 0), AutoPoint(t: secs, v: -18)]
                let swept = try await export(auto)
                let first = try band(swept, hz: 7000, third: 0), last = try band(swept, hz: 7000, third: 2)
                print(String(format: "automatización 0 → −18 dB: primer tercio %.1f dB · último tercio %.1f dB", first, last))
                ok = ok && (first - last) > 6
                // Filtro K: un seno de 1 kHz a −20 dBFS debe medir −23,0 LUFS (BS.1770)
                var k = KWeight(sampleRate: 48_000)
                var tone = [Float](repeating: 0, count: 48_000)
                for i in tone.indices { tone[i] = Float(0.1 * sin(2 * .pi * 1000 * Double(i) / 48_000)) }
                _ = tone.withUnsafeBufferPointer { k.meanSquare($0.baseAddress!, 24_000) }   // que asiente el filtro
                let pwr = tone.withUnsafeBufferPointer { k.meanSquare($0.baseAddress! + 24_000, 24_000) }
                let lufs = MixLoudness.lufs(pwr)
                print(String(format: "filtro K: seno 1 kHz a −20 dBFS = %.2f LUFS (esperado −23.0)", lufs))
                ok = ok && abs(lufs + 23.0) < 0.3
                print(ok ? "OK la cadena de voz procesa dentro del export (con automatización) y el filtro K mide bien" : "FAIL")
                try? FileManager.default.removeItem(at: dir)
                exit(ok ? 0 : 1)
            } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
        }
    }

    /// "--chapters-test <slug> [intro_s]": los capítulos que saldrían en las notas y en el archivo.
    static func chaptersTest() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--chapters-test"), a.count > i + 1 else { print("uso: --chapters-test <slug> [intro]"); exit(2) }
        Task { @MainActor in
            do {
                var p = try ProjectStore.load(slug: a[i + 1])
                let intro = a.count > i + 2 ? Double(a[i + 2]) ?? 0 : 0
                if a.contains("--fake") {        // capítulos de mentira (solo en memoria) para probar las reglas
                    let fake: [(Double, String)] = [(4, "Bienvenida"), (40, "Tema uno"), (44, "Muy cerca"),
                                                    (900, "Tema dos"), (1800, "Preguntas = respuestas; #1"), (p.duration - 3, "Al final")]
                    p.moments += fake.enumerated().map { Moment(id: 9000 + $0.offset, time: $0.element.0, duration: nil, label: $0.element.1) }
                }
                let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
                print("marcados: \(p.chapters.count) · cortes: \(p.cuts.count) · dura \(EditEngine.clock(EditEngine.outputDuration(keep)))")
                for c in p.chapters { print("  bruto \(EditEngine.clock(c.time)) \(c.title)") }
                let list = Exporter.chapterList(project: p, keep: keep, introDuration: intro,
                                                total: intro + EditEngine.outputDuration(keep))
                print("capítulos (intro \(intro) s): \(list.count)")
                for c in list { print("  \(EditEngine.clock(c.time)) \(c.title)") }
                if a.contains("--export-audio") {     // MP3 completo con los capítulos adentro
                    let proj = p
                    let url = try await Exporter.export(project: proj, format: .audio, baseName: "render-test",
                                                        energy: AudioAnalysis.loadEnergy(proj.id)) { _ in }
                    print("OK \(url.path)")
                }
                exit(0)
            } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
        }
    }

    static func render() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--render"), a.count > i + 4,
              let s = Double(a[i + 2]), let e = Double(a[i + 3]), let fmt = ExportFormat(rawValue: a[i + 4]) else {
            print("uso: --render <slug> <inicio> <fin> <formato>"); exit(2)
        }
        Task { @MainActor in
            do {
                var p = try ProjectStore.load(slug: a[i + 1])
                let window: EditEngine.Span? = (s <= 0 && e >= p.duration) ? nil : (s, e)   // todo el episodio: sin ventana (con intro/cierre)
                // "--render … vertical reel N": con el diseño del reel N (1 = el primero), como al exportar reels
                if a.count > i + 6, a[i + 5] == "reel", let n = Int(a[i + 6]), n >= 1, n <= p.reels.count {
                    p = p.applying(p.look(for: p.reels[n - 1]), reel: p.reels[n - 1])
                }
                let uhd = a.contains("--uhd")       // "--render … landscape --uhd": en 4K
                let proj = p
                let url = try await ExportFormat.$uhd.withValue(uhd) {
                    try await Exporter.export(project: proj, format: fmt, window: window, baseName: "render-test",
                                              energy: AudioAnalysis.loadEnergy(proj.id)) { _ in }
                }
                print("OK \(url.path)"); fflush(stdout); exit(0)
            } catch {
                let ns = error as NSError
                print("ERROR \(error.localizedDescription) [\(ns.domain) \(ns.code)] \(ns.userInfo)")
                exit(1)
            }
        }
    }

    @MainActor
    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.windows.forEach { $0.orderOut(nil) }   // headless: no window
        }
        let args = CommandLine.arguments
        if args.contains("--render") { render(); return }
        if args.contains("--chapters-test") { chaptersTest(); return }
        if args.contains("--enhance-test") { enhanceTest(); return }
        if args.contains("--voice-chain-test") { voiceChainTest(); return }
        if let i = args.firstIndex(of: "--intro-snapshot"), args.count > i + 1 {
            // Capturas de la entrada (logo con las estrellas) a 0.35 s, 0.8 s y 1.6 s
            let dir = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Task { @MainActor in
                let host = NSHostingView(rootView: IntroView(onFinish: {}).frame(width: 640, height: 480).preferredColorScheme(.dark))
                host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = host
                win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                win.orderFrontRegardless()
                let t0 = Date()
                for (name, t) in [("1-nota1", 0.35), ("2-nota3", 0.8), ("3-final", 1.6)] {
                    let wait = t - Date().timeIntervalSince(t0)
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
                        print("snapshot \(name)")
                    }
                }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--stems-test"), args.count > i + 1 {
            Task { @MainActor in
                guard let p = try? ProjectStore.load(slug: args[i + 1]) else { print("FAIL no project"); exit(1) }
                do {
                    let folder = try await Exporter.exportStems(project: p, energy: AudioAnalysis.loadEnergy(p.id)) { _ in }
                    print("OK \(folder.path)")
                } catch { print("FAIL \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--frame-test"), args.count > i + 4 {
            // Solo lectura: un cuadro de un reel en 9:16 a PNG. Con --crowd le suma (en memoria) un cintillo y un texto
            // abajo en ese momento, para ver que lo automático se acomoda sin pisarse.
            Task { @MainActor in
                // --episode: reel 0 = el episodio en 16:9 y el segundo es tiempo del episodio
                let episode = args.contains("--episode")
                guard var p = try? ProjectStore.load(slug: args[i + 1]), let n = Int(args[i + 2]),
                      episode || (n >= 1 && n <= p.reels.count), let off = Double(args[i + 3]) else { print("FAIL args"); exit(1) }
                if episode {
                    if args.contains("--bgpodcast") {
                        for l in p.lanes { var vb = VirtualBackground(); vb.mode = .podcast; p.laneBackground[l.id] = vb }
                    }
                    do {
                        let built = try await CompositionBuilder.build(project: p, format: .landscape, window: nil,
                                                                       energy: AudioAnalysis.loadEnergy(p.id))
                        let gen = AVAssetImageGenerator(asset: built.asset)
                        gen.videoComposition = built.videoComposition
                        gen.requestedTimeToleranceBefore = .zero
                        gen.requestedTimeToleranceAfter = .zero
                        let outT = (EditEngine.toOutput(off, keep: built.keep) ?? off) + built.introDuration
                        let (img, _) = try await gen.image(at: CMTime(seconds: outT, preferredTimescale: 600))
                        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 4]))
                        print("OK \(args[i + 4])")
                    } catch { print("FAIL \(error.localizedDescription)") }
                    fflush(stdout); exit(0)
                }
                let reel = p.reels[n - 1]
                let at = reel.start + off
                if args.contains("--crowd") {
                    let cint: [String: Any] = ["id": 9001, "kind": "banner", "title": "AHORA", "text": "Lee la letra chica antes de firmar",
                                               "start": at - 1, "duration": 6]
                    let layer: [String: Any] = ["id": 9002, "kind": "text", "start": at - 1, "duration": 6, "text": "¡Suscríbete!",
                                                "style": "label", "color": "#E4002B", "x": 0.5, "y": 0.76]
                    if let c = try? JSONDecoder().decode(DirectorCintillo.self, from: JSONSerialization.data(withJSONObject: cint)) {
                        p.cintillos.append(c); p.showCintillos = true
                    }
                    if let l = try? JSONDecoder().decode(VideoLayer.self, from: JSONSerialization.data(withJSONObject: layer)) { p.overlays.append(l) }
                }
                if args.contains("--capbottom") {   // subtítulos en su lugar de siempre (sin la posición arrastrada)
                    p.captionStyle.freeX = nil; p.captionStyle.freeY = nil
                    p.reelLook.captionStyle?.freeX = nil; p.reelLook.captionStyle?.freeY = nil
                    for k in p.reels.indices { p.reels[k].look?.captionStyle?.freeX = nil; p.reels[k].look?.captionStyle?.freeY = nil }
                }
                if args.contains("--bgpodcast") {   // fondo virtual «Fondo del podcast» para todas las personas
                    for l in p.lanes { var vb = VirtualBackground(); vb.mode = .podcast; p.laneBackground[l.id] = vb }
                }
                if let h = args.firstIndex(of: "--hook"), args.count > h + 1 { p.reels[n - 1].hook = args[h + 1] }   // título de gancho
                let reelNow = p.reels[n - 1]
                p = p.applying(p.look(for: reelNow), reel: reelNow)
                do {
                    let built = try await CompositionBuilder.build(project: p, format: .vertical, window: (reel.start, reel.end),
                                                                   energy: AudioAnalysis.loadEnergy(p.id))
                    let gen = AVAssetImageGenerator(asset: built.asset)
                    gen.videoComposition = built.videoComposition
                    gen.requestedTimeToleranceBefore = .zero
                    gen.requestedTimeToleranceAfter = .zero
                    let outT = EditEngine.toOutput(at, keep: built.keep) ?? off
                    let (img, _) = try await gen.image(at: CMTime(seconds: outT, preferredTimescale: 600))
                    let rep = NSBitmapImageRep(cgImage: img)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 4]))
                    if let sc = built.scene {
                        let plan = sc.arrangement(at: outT, brollFrames: [:])
                        print("subtitulos", plan.captionBand.map { "\(Int($0.minY))-\(Int($0.maxY))" } ?? "-",
                              "cintillos", plan.cintilloY, "sponsors", plan.sponsorY)
                    }
                    print("OK \(args[i + 4])")
                } catch { print("FAIL \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if args.contains("--miccheck-test") {
            // La cuenta de la prueba de micrófono, con voces simuladas (energía de 100 lecturas en dB)
            Task { @MainActor in
                func run(_ name: String, _ levels: [Float], expect: Int?) {
                    let r = ProdStudio.evaluate(power: levels.map { powf(10, $0 / 10) }, peak: levels.max() ?? -160)
                    print(r.suggested == expect ? "OK" : "FAIL", name, "avg", r.avg, "peak", r.peak, "sugerido", r.suggested.map(String.init) ?? "nada")
                }
                run("voz baja", Array(repeating: -36, count: 100), expect: 18)
                run("voz normal", Array(repeating: -18, count: 100), expect: 0)
                run("voz fuerte", Array(repeating: -4, count: 100), expect: -12)
                run("pausas", Array(repeating: -24, count: 50) + Array(repeating: -70, count: 50), expect: 9)
                run("silencio", Array(repeating: -80, count: 100), expect: nil)
                LiveGate.shared.makeupDb = 6
                print(abs(LiveGate.shared.makeupDb - 6) < 0.01 ? "OK" : "FAIL", "ganancia 6 dB =", LiveGate.shared.makeupDb)
                LiveGate.shared.makeupDb = 0
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--meter-test"), args.count > i + 1 {
            // Solo lectura: el medidor mide lo que sale (con el volumen aplicado). Lee 20 s con la persona 1 a volumen
            // normal y al 25 %: la diferencia debe rondar −12 dB.
            Task { @MainActor in
                guard let base = try? ProjectStore.load(slug: args[i + 1]), let lane = base.lanes.first else { print("FAIL no project"); exit(1) }
                func measure(_ vol: Double) async throws -> Float {
                    var p = base
                    p.lanes[0].volume = vol
                    let start = min(300, max(0, p.duration - 30))
                    let built = try await CompositionBuilder.build(project: p, format: .audio, window: (start, start + 20),
                                                                   energy: AudioAnalysis.loadEnergy(p.id), preview: true)
                    guard built.meters[lane.id] != nil else { print("FAIL sin medidor"); return -999 }
                    // Como en la app: reproduciendo con AVPlayer (sin sonido en la Mac)
                    let player = AVPlayer(playerItem: built.playerItem())
                    player.volume = 0
                    player.play()
                    var sum: Float = 0, n: Float = 0
                    for _ in 0..<60 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        if let db = built.levelDB(lane: lane.id, at: player.currentTime().seconds), db > -90 { sum += Float(db); n += 1 }
                    }
                    player.pause()
                    return n > 0 ? sum / n : -999
                }
                do {
                    let a = try await measure(1.0), b = try await measure(0.25)
                    print(String(format: "medidor persona 1: normal %.1f dB, al 25%% %.1f dB, diferencia %.1f dB", a, b, b - a))
                } catch { print("FAIL \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--filler-test"), args.count > i + 1 {
            // Solo lectura: compara las muletillas de antes (todas las palabras de la lista) con las nuevas
            Task { @MainActor in
                // --words <json>: palabras de un archivo (las que deja --sync-test) en vez de las del proyecto
                var words: [Word] = []
                var energy: EnergyMap?
                if let j = args.firstIndex(of: "--words"), args.count > j + 1,
                   let d = try? Data(contentsOf: URL(fileURLWithPath: args[j + 1])),
                   let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                    words = arr.compactMap { o in
                        guard let w = o["w"] as? String, let s = o["s"] as? Double, let e = o["e"] as? Double else { return nil }
                        return Word(w: w, s: s, e: e, lane: Int((o["lane"] as? Double) ?? 1))
                    }
                } else {
                    guard let p = try? ProjectStore.load(slug: args[i + 1]) else { print("FAIL no project"); exit(1) }
                    words = p.words
                    energy = AudioAnalysis.loadEnergy(p.id)
                }
                let oldCount = words.filter { EditEngine.soundFillers.contains(EditEngine.normalize($0.w)) || EditEngine.wordFillers.contains(EditEngine.normalize($0.w)) }.count
                let t0 = Date()
                let f = EditEngine.fillerCuts(words: words, includeWordFillers: true)
                let r = EditEngine.repeatCuts(words: words)
                var snd: [Cut] = []
                if let energy {
                    snd = EditEngine.soundOnlyCuts(words: words, energy: energy).filter { c in !(f + r).contains { $0.start < c.end && $0.end > c.start } }
                }
                print(String(format: "palabras %d · antes %d muletillas cortadas · %.2f s", words.count, oldCount, Date().timeIntervalSince(t0)))
                print("ahora: \(f.filter(\.enabled).count) seguras, \(f.filter { !$0.enabled }.count) dudosas, \(r.count) repetidas, \(snd.count) sonidos sin palabras")
                // contexto de cada «bueno»
                let sorted = words.sorted { $0.s < $1.s }
                for (k, w) in sorted.enumerated() where EditEngine.normalize(w.w) == "bueno" {
                    let ctx = sorted[max(0, k - 3)...min(sorted.count - 1, k + 3)].filter { $0.lane == w.lane }.map(\.w).joined(separator: " ")
                    let c = f.first { $0.start <= w.s + 0.05 && $0.end >= w.e - 0.05 }
                    print("  bueno @\(EditEngine.clock(w.s)) → \(c == nil ? "NO se marca" : (c!.enabled ? "SE CORTA" : "sugerencia")) · …\(ctx)…")
                }
                for c in (f.filter { !$0.enabled } + r + snd).sorted(by: { $0.start < $1.start }).prefix(40) {
                    print("  \(EditEngine.clock(c.start)) \(String(format: "%.2f", c.length))s \(c.label)")
                }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--sync-test"), args.count > i + 1 {
            // Solo lectura: ajusta las palabras al audio y deja el resultado en /tmp (no guarda el proyecto)
            Task { @MainActor in
                guard let p = try? ProjectStore.load(slug: args[i + 1]) else { print("FAIL no project"); exit(1) }
                // Corregir texto: las palabras iguales conservan su tiempo
                let old = [Word(w: "hola", s: 1, e: 1.3), Word(w: "que", s: 1.3, e: 1.5), Word(w: "tal", s: 1.6, e: 2.0)]
                let r1 = EditEngine.retime(old: old, tokens: ["hola", "qué", "tal", "amigos"], lane: 1)
                print("retime 1:", r1.map { "\($0.w)@\(String(format: "%.2f-%.2f", $0.s, $0.e))" }.joined(separator: " "))
                let r2 = EditEngine.retime(old: old, tokens: ["hola", "tal"], lane: 1)
                print("retime 2:", r2.map { "\($0.w)@\(String(format: "%.2f-%.2f", $0.s, $0.e))" }.joined(separator: " "))
                let t0 = Date()
                do {
                    let res = try await SubtitleSync.align(p.words, project: p)
                    print(String(format: "OK %d palabras, %d corridas, típico %+.3f s, %.1f s", p.words.count, res.moved, res.typicalShift, Date().timeIntervalSince(t0)))
                    let out = res.words.map { ["w": $0.w, "s": $0.s, "e": $0.e, "lane": Double($0.lane)] as [String: Any] }
                    let data = try JSONSerialization.data(withJSONObject: out)
                    try data.write(to: URL(fileURLWithPath: "/tmp/thepod-sync-\(p.id).json"))
                    // Volver a escuchar el primer reel (si hay): cuántas palabras y cómo quedan
                    if let reel = p.reels.first, args.contains("--listen") {
                        let t1 = Date()
                        let heard = try await SubtitleSync.listen(project: p, from: reel.start, to: reel.end) { _, _ in }
                        let synced = try await SubtitleSync.align(heard, project: p).words
                        print(String(format: "reel %@: %d palabras escuchadas en %.1f s", reel.title, heard.count, Date().timeIntervalSince(t1)))
                        print(synced.sorted { $0.s < $1.s }.prefix(25).map { "\($0.w)@\(String(format: "%.2f", $0.s))" }.joined(separator: " "))
                        let out = synced.map { ["w": $0.w, "s": $0.s, "e": $0.e, "lane": Double($0.lane)] as [String: Any] }
                        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: "/tmp/thepod-reel-\(p.id).json"))
                    }
                } catch { print("FAIL \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--sensitive-test"), args.count > i + 1 {
            // Busca palabras sensibles en un proyecto, pone pitido en la primera y guarda (en una copia de prueba)
            Task { @MainActor in
                let app = AppModel()
                guard var p = try? ProjectStore.load(slug: args[i + 1]) else { print("FAIL no project"); exit(1) }
                p.sensitive = SensitiveWords.scan(p)
                p.sensitiveScanned = true
                print("encontradas \(p.sensitive.count)")
                for m in p.sensitive.prefix(12) { print("  \(Timecode.string(m.s, tenths: false)) \(p.laneName(m.lane)): \(m.word) → \(m.category.rawValue) / \(m.replacement)") }
                let cw = p.captionWords
                let changed = zip(p.words, cw).filter { $0.0.w != $0.1.w }.count
                print("subtitulos cambiados \(changed)")
                if let first = p.sensitive.first {
                    p.sensitive[0].bleep = true
                    try? ProjectStore.save(p)
                    print("pitido en \(first.s)-\(first.e) lane \(first.lane)")
                }
                _ = app
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--extras-test"), args.count > i + 1 {
            // Deshacer/rehacer, I/O y plantillas, sin ventanas
            Task { @MainActor in
                let app = AppModel()
                guard let p = try? ProjectStore.load(slug: args[i + 1]) else { print("FAIL no project"); exit(1) }
                let session = ProjectSession(project: p, app: app)
                let before = session.project
                session.project.cuts.append(Cut(start: 10, end: 12, kind: .manual, label: "prueba"))
                try? await Task.sleep(nanoseconds: 700_000_000)
                session.project.cuts.append(Cut(start: 20, end: 22, kind: .manual, label: "prueba 2"))
                guard session.project.cuts.count == before.cuts.count + 2 else { print("FAIL cuts"); exit(1) }
                session.undoChange()
                guard session.project.cuts.count == before.cuts.count + 1 else { print("FAIL undo 1: \(session.project.cuts.count)"); exit(1) }
                session.undoChange()
                guard session.project == before else { print("FAIL undo 2"); exit(1) }
                session.redoChange()
                guard session.project.cuts.count == before.cuts.count + 1 else { print("FAIL redo"); exit(1) }
                // I / O
                session.inPoint = 30
                let n = session.project.reels.count
                session.markOut()           // playhead en 0 → reel 0…30
                guard session.project.reels.count == n + 1, let r = session.project.reels.last, r.start == 0, r.end == 30 else { print("FAIL markOut"); exit(1) }
                session.undoChange()
                guard session.project.reels.count == n else { print("FAIL undo reel"); exit(1) }
                // plantillas
                var look = ReelLook(); look.layout = .stack; look.showNames = false; look.logoFile = "x.png"
                let t = ReelTemplate(name: "prueba", look: look)
                var cur = ReelLook(); cur.logoFile = "mio.png"
                let ap = t.applied(over: cur)
                guard ap.layout == .stack, ap.showNames == false, ap.logoFile == "mio.png" else { print("FAIL template"); exit(1) }
                var list = ReelTemplate.load(); list.removeAll { $0.name == "prueba" }; list.append(t); ReelTemplate.save(list)
                guard ReelTemplate.load().contains(where: { $0.name == "prueba" }) else { print("FAIL template save"); exit(1) }
                list.removeAll { $0.name == "prueba" }; ReelTemplate.save(list)
                print("OK extras: deshacer/rehacer, I/O, plantillas")
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--brand-kit"), args.count > i + 1 {
            Task { @MainActor in
                BrandKit.export(to: URL(fileURLWithPath: args[i + 1]))
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--intro-frames"), args.count > i + 4 {
            // --intro-frames <carpeta> <ancho> <alto> <0 con fondo | 1 transparente | 2 transparente para fondo claro>: cuadros a 30 fps.
            let dir = URL(fileURLWithPath: args[i + 1])
            let w = Double(args[i + 2]) ?? 1920, h = Double(args[i + 3]) ?? 1080
            Task { @MainActor in
                BrandKit.introFrames(to: dir, w: w, h: h, alpha: args[i + 4] != "0", light: args[i + 4] == "2")
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--tts"), args.count > i + 2 {
            // --tts "<texto>" <salida.caf>: prueba de la voz artificial
            Task { @MainActor in
                do {
                    let v = Speech.defaultVoice()
                    try await Speech.synthesize(args[i + 1], voice: v, rate: 0.5, to: URL(fileURLWithPath: args[i + 2]))
                    print("OK voz=\(v?.name ?? "-") \(v?.language ?? "") \(v?.quality ?? "") → \(args[i + 2])")
                    print("voces es: " + Speech.voices().filter { $0.language.hasPrefix("es") }.map { "\($0.name)(\($0.language)\($0.quality.isEmpty ? "" : ",\($0.quality)"))" }.joined(separator: ", "))
                } catch { print("ERROR \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if args.contains("--prepod-test") { prepodTest(); return }
        if args.contains("--postpod-test") { postpodTest(); return }
        if let i = args.firstIndex(of: "--pre-snapshot"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { preSnapshot(dir) }   // después de esconder la ventana normal
            return
        }
        if let i = args.firstIndex(of: "--prod-snapshot"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { prodSnapshot(dir) }
            return
        }
        if let i = args.firstIndex(of: "--rec-test"), args.count > i + 1, let sid = Int(args[i + 1]) {
            recTest(sid)
            return
        }
        if let i = args.firstIndex(of: "--prod-recs"), args.count > i + 1, let sid = Int(args[i + 1]) {
            Task { @MainActor in             // solo lectura: grabaciones, momentos y personas de una sala
                for path in ["/api/sessions/\(sid)/recordings", "/api/sessions/\(sid)/chapter-markers",
                             "/api/sessions/\(sid)/participants", "/api/sessions/\(sid)/sound-triggers/stats"] {
                    let d = (try? await ProdPodClient.shared.get(path)) ?? Data()
                    print("== \(path)\n\(String(data: d, encoding: .utf8) ?? "")")
                }
                fflush(stdout); exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--studio-snapshot"), args.count > i + 2 {
            let slug = args[i + 1], dir = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { studioSnapshot(slug: slug, dir: dir) }
            return
        }
        if let i = args.firstIndex(of: "--post-snapshot"), args.count > i + 2 {
            let slug = args[i + 1], dir = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { postSnapshot(slug: slug, dir: dir) }
            return
        }
        if let i = args.firstIndex(of: "--cover-scan") {   // busca portadas en un proyecto y deja las imágenes en una carpeta
            let slug = args.count > i + 1 ? args[i + 1] : (ProjectStore.listProjects().first?.id ?? "")
            let dir = URL(fileURLWithPath: args.count > i + 2 ? args[i + 2] : "/tmp/coverscan")
            Task { @MainActor in
                do {
                    let project = try ProjectStore.load(slug: slug)
                    let t0 = Date()
                    print("proyecto \(project.id) · \(Int(project.duration)) s · pistas con video: \(project.lanes.count)")
                    let found = try await CoverScout.scan(project: project) { f, what in
                        if Int(f * 100) % 10 == 0 { print(String(format: "  %3d%% %@", Int(f * 100), what)) }
                    }
                    print("encontradas \(found.count) en \(Int(Date().timeIntervalSince(t0))) s")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let imgs = try await CoverScout.renderAll(project: project, times: found.map { $0.time }, energy: AudioAnalysis.loadEnergy(project.id), maxSize: 960) { _ in }
                    for s in found {
                        print(String(format: "  %@  score %.2f  %@  caras %d", EditEngine.clock(s.time), s.score, s.allSmiling ? "SONRÍEN" : "       ", s.faces))
                        if let img = imgs[s.time], let d = CoverScout.jpeg(img) {
                            try? d.write(to: dir.appendingPathComponent(String(format: "%05d.jpg", Int(s.time))))
                        }
                    }
                    print("OK \(dir.path)")
                } catch { print("ERROR \(error)") }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--pub-snapshot"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pubSnapshot(dir: dir) }
            return
        }
        if let i = args.firstIndex(of: "--ama-snapshot"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { amaSnapshot(dir: dir) }
            return
        }
        if let i = args.firstIndex(of: "--director-snapshot"), args.count > i + 2 {
            let slug = args[i + 1], dir = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { directorSnapshot(slug: slug, dir: dir) }
            return
        }
        if let i = args.firstIndex(of: "--cintillo-snapshot"), args.count > i + 2 {
            let slug = args[i + 1], dir = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { cintilloSnapshot(slug: slug, dir: dir) }
            return
        }
        if args.contains("--prod-test") {            // solo lectura: sesiones de prodPod
            Task { @MainActor in
                do {
                    let list = try await ProdPodClient.shared.sessions()
                    print("OK prodPod sesiones=\(list.count)")
                    let dp = (try? await ProdPodClient.shared.directorProjects()) ?? []
                    print("director de: \(dp.count) podcasts; salas dirigibles: \(list.filter { dp.contains($0.shared_project_id ?? "-") }.map(\.id))")
                    for s in list.prefix(8) { print("  #\(s.id) · \(s.title) · \(s.status ?? "-")") }
                } catch { print("ERROR \(error.localizedDescription)") }
                fflush(stdout); exit(0)
            }
            return
        }
        if args.contains("--update-test") {          // qué versión publica el servidor (no baja nada)
            Updater.shared.check()
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Updater.shared.state != .checking { break }
                }
                print("instalada=\(Updater.currentVersion) (\(Updater.currentBuild)) servidor=\(Updater.shared.state)")
                // --download: baja lo publicado (sin instalar) y muestra cómo avanza la barra
                if args.contains("--download") {
                    let rel = Updater.Release(version: "0", build: "0", size: nil, sha256: nil)
                    Updater.shared.download(rel)
                    var seen: [Int] = []
                    for _ in 0..<1200 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if case .downloading(let f) = Updater.shared.state, let f {
                            let pct = Int(f * 100)
                            if seen.last != pct { seen.append(pct) }
                        } else if case .downloading = Updater.shared.state {
                        } else { break }
                    }
                    print("avance visto:", seen.map(String.init).joined(separator: " "), "→", Updater.shared.state)
                }
                fflush(stdout); exit(0)
            }
            return
        }
        if args.contains("--pre-test") {             // solo lectura: podcasts, episodios y el detalle del primero
            Task { @MainActor in
                do {
                    let api = PrePodClient.shared
                    let pods = try await api.prePodcasts()
                    print("podcasts=\(pods.count)")
                    if let p = pods.first(where: { $0.name.contains("Letra") }) ?? pods.first {
                        let c = try await api.podcastConfig(p.slug); let h = try await api.hosts(p.slug)
                        let sp = try await api.sponsors(p.slug); let so = try await api.sounds(p.slug)
                        let di = try await api.distribution(p.slug); let fo = try await api.fonts()
                        print("config \(c.name): colores=\(c.colorPrimary ?? "-") fuente=\(c.fontHeading ?? "-") logo=\(c.logoUrl != nil) · dueño=\(h.owner ?? "-") conductores=\(h.extraHosts.count) directores=\((h.directors ?? []).count) · sponsors=\(sp.count) sonidos=\(so.count) · plataformas=\(di.platforms.keys.sorted()) feed=\(di.feedUrl ?? "-") · fuentes=\(fo.count)")
                        if let u = c.logoUrl { print("logo bytes=\((try? await api.media(u))?.count ?? -1)") }
                        let tp = try await api.templates(p.slug)
                        var td: TemplateDetail?
                        if let first = tp.first { td = try await api.template(p.slug, first.id) }
                        let la = try await api.landing(p.slug); let tm = try await api.team(p.slug)
                        print("plantillas=\(tp.count) [\(td.map { "\($0.name): \($0.blocks.count) bloques, \($0.sections.count) secciones" } ?? "-")] · landing=\(la.template ?? "-") episodios=\(la.showEpisodes ?? false) · equipo=\(tm.count)")
                        let allEps = try await api.preEpisodes(p.slug)
                        if let e = allEps.first(where: { $0.episodeNumber == 14 }) ?? allEps.first {
                            let ide = try await api.ideas(p.slug, e.id); let ln = try await api.links(p.slug, e.id); let sn = try await api.showNotes(p.slug, e.id)
                            print("\(e.label): ideas=\(ide.count) links=\(ln.map(\.platform)) notas=\(sn.text.count) caracteres")
                        }
                    }
                    for p in pods {
                        let eps = try await api.preEpisodes(p.slug)
                        print("  \(p.name): \(eps.count) episodios · " + Dictionary(grouping: eps, by: \.status).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " "))
                        if let e = eps.last {
                            let sc = try await api.script(p.slug, e.id), bl = try await api.blocks(p.slug, e.id), gu = try await api.guests(p.slug, e.id)
                            print("    \(e.label) [\(e.whenText ?? "sin fecha")]: guion=\(sc.count) rundown=\(bl.count) invitados=\(gu.count)")
                        }
                    }
                } catch { print("ERROR \(error)") }
                fflush(stdout); exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let inputs = args[(i + 1)...].filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let skipLandscape = args.contains("--no-landscape")
        Task { @MainActor in
            let t0 = Date()
            func log(_ s: String) {
                print(String(format: "[%6.1fs] ", Date().timeIntervalSince(t0)) + s)
                fflush(stdout)
            }
            do {
                log("Importando \(inputs.map(\.lastPathComponent))")
                var lastPct = -1
                let project = try await Importer.importItems(inputs) { stage, f in
                    let pct = Int(f * 100)
                    if pct / 10 != lastPct / 10 { lastPct = pct; print("   import \(pct)% \(stage)"); fflush(stdout) }
                }
                log("Proyecto \(project.id): \(project.lanes.count) pistas, \(EditEngine.clock(project.duration))")
                let app = AppModel()
                let session = ProjectSession(project: project, app: app)
                let watcher = Task { @MainActor in
                    var last = ""
                    while !Task.isCancelled {
                        if let j = session.job {
                            let line = "   \(j.title) · \(j.detail) \(j.fraction.map { "\(Int($0 * 100))%" } ?? "")"
                            if line != last { print(line); fflush(stdout); last = line }
                        }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
                try await session.performFix()
                log(session.fixSummary ?? "fix sin resumen")
                log("Palabras: \(session.project.words.count), cortes: \(session.project.cuts.count)")
                if session.project.reels.isEmpty {
                    session.project.reels = session.project.reelsFromMoments()
                }
                if session.project.reels.isEmpty {   // no moments marked: test with one manual reel
                    session.project.reels = [Reel(title: "Prueba", start: 60, end: min(session.project.duration, 105))]
                }
                log("Reels: " + session.project.reels.map { "\(EditEngine.clock($0.start))-\(EditEngine.clock($0.end)) \($0.title)" }.joined(separator: " | "))
                var outputs: [String] = []
                if !skipLandscape {
                    outputs.append(try await session.performExport(format: .landscape).path)
                    log("Landscape listo")
                }
                if !session.project.reels.isEmpty {
                    for idx in session.project.reels.indices { session.project.reels[idx].selected = idx == 0 }
                    session.project.reelLook.layout = .auto
                    outputs += try await session.performExportReels().map(\.path)
                    log("Reel listo")
                }
                outputs.append(try await session.performExport(format: .audio).path)
                log("Audio listo")
                watcher.cancel()
                try ProjectStore.save(session.project)
                let report: [String: Any] = [
                    "project": project.id,
                    "folder": ProjectStore.folder(for: project.id).path,
                    "duration": project.duration,
                    "outputDuration": EditEngine.outputDuration(EditEngine.keepRanges(duration: session.project.duration, cuts: session.project.cuts)),
                    "words": session.project.words.count,
                    "cuts": session.project.cuts.count,
                    "reels": session.project.reels.map { ["title": $0.title, "start": $0.start, "end": $0.end] },
                    "outputs": outputs,
                    "seconds": Date().timeIntervalSince(t0),
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                print("REPORT " + (String(data: data, encoding: .utf8) ?? ""))
                fflush(stdout)
                exit(0)
            } catch {
                log("ERROR: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
