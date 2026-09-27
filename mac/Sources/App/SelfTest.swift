import Foundation
import SwiftUI
import AppKit

/// Headless end-to-end run used for development:
///   postPod.app/Contents/MacOS/postPod --selftest <file-or-zip> [more files…]
/// Imports, fixes (enhance + transcribe + silences/fillers), suggests reels and exports
/// a landscape video, the first reel (vertical) and the audio. Prints progress and a JSON report.
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--render")
            || CommandLine.arguments.contains("--prepod-test") || CommandLine.arguments.contains("--postpod-test") || CommandLine.arguments.contains("--pre-test") || CommandLine.arguments.contains("--update-test") || CommandLine.arguments.contains("--pre-snapshot") || CommandLine.arguments.contains("--prod-test")
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
    static func render() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--render"), a.count > i + 4,
              let s = Double(a[i + 2]), let e = Double(a[i + 3]), let fmt = ExportFormat(rawValue: a[i + 4]) else {
            print("uso: --render <slug> <inicio> <fin> <formato>"); exit(2)
        }
        Task { @MainActor in
            do {
                let p = try ProjectStore.load(slug: a[i + 1])
                let url = try await Exporter.export(project: p, format: fmt, window: (s, e), baseName: "render-test",
                                                    energy: AudioAnalysis.loadEnergy(p.id)) { _ in }
                print("OK \(url.path)"); fflush(stdout); exit(0)
            } catch { print("ERROR \(error.localizedDescription)"); exit(1) }
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
        if args.contains("--prepod-test") { prepodTest(); return }
        if args.contains("--postpod-test") { postpodTest(); return }
        if let i = args.firstIndex(of: "--pre-snapshot"), args.count > i + 1 {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { preSnapshot(dir) }   // después de esconder la ventana normal
            return
        }
        if args.contains("--prod-test") {            // solo lectura: sesiones de prodPod
            Task { @MainActor in
                do {
                    let list = try await ProdPodClient.shared.sessions()
                    print("OK prodPod sesiones=\(list.count)")
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
                    session.project.reelLayout = .auto
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
