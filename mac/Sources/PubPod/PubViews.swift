import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// pubPod es el blanco de las estrellas de la bandera: publicar te hace una estrella.
    static let pubPod = Color.white
}

/// Redes donde publica pubPod (las conexiones se hacen en prePod → Configurar podcast → Redes).
struct PubNet: Identifiable, Hashable {
    let id: String; let name: String; let symbol: String
    static let all = [PubNet(id: "instagram", name: "Instagram", symbol: "camera"),
                      PubNet(id: "youtube", name: "YouTube", symbol: "play.rectangle"),
                      PubNet(id: "tiktok", name: "TikTok", symbol: "music.note")]
    static func named(_ id: String) -> PubNet { all.first { $0.id == id } ?? PubNet(id: id, name: id, symbol: "paperplane") }
}

// MARK: - pubPod: publicar lo que sale de postPod

struct PubHomeView: View {
    @EnvironmentObject var app: AppModel

    enum Choice: Hashable { case episode, reel(UUID), file(URL) }

    @State private var projectId: String?
    @State private var choice: Choice?
    @State private var accounts: [String: PrePodClient.PubAccount] = [:]
    @State private var accountsFor: String?
    @State private var error: String?
    @State private var title = ""
    @State private var pick: [String: Bool] = [:]
    @State private var captions: [String: String] = [:]
    @State private var later = false
    @State private var whenDate = Date().addingTimeInterval(3600)
    @State private var sending = false          // subida desde la compu (no pasa por el editor)
    @State private var progress = 0.0
    @State private var done: String?
    @State private var postsVersion = 0

    private var project: Project? {
        guard let projectId else { return nil }
        if let s = app.session, s.project.id == projectId { return s.project }
        return app.projects.first { $0.id == projectId }
    }
    private var slug: String? { project?.episode.prepodSlug }
    private var session: ProjectSession? { app.session.flatMap { $0.project.id == projectId ? $0 : nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                    SectionSwitcher()
                    Spacer()
                    SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
                }
                Text("Publica lo que sale de postPod: tus reels y el episodio completo, al momento o programado.")
                    .font(.title3).foregroundStyle(Theme.secondary)
                if !PrePodClient.isConfigured {
                    Card {
                        Label("Conecta la app con thePod en Ajustes para publicar.", systemImage: "person.badge.key")
                        SettingsLink { Text("Abrir Ajustes") }
                    }
                }
                HStack(alignment: .top, spacing: 20) {
                    episodesColumn.frame(width: 300)
                    VStack(alignment: .leading, spacing: 14) {
                        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        if let project { publishPane(project) } else {
                            Card { Text("Elige un episodio de la izquierda.").foregroundStyle(Theme.secondary) }
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }
                if let slug {
                    PubPostsList(slug: slug).id("\(slug)-\(postsVersion)")
                }
            }
            .padding(28)
        }
        .tint(.pubPod)
        .onAppear {
            app.reload()
            if projectId == nil { projectId = app.session?.project.id ?? app.projects.first?.id }
            loadAccounts()
        }
        .onChange(of: projectId) { _, _ in choice = nil; done = nil; error = nil; loadAccounts() }
        .onChange(of: session?.isBusy ?? false) { _, busy in
            // Terminó de exportar y subir desde el editor: el resultado o el error se ven aquí
            guard !busy, let s = session else { return }
            if s.reelPosts != nil { done = later ? "Quedó programado." : "Enviado: sale en unos minutos."; postsVersion += 1 }
            else if let m = s.errorMessage { error = m; s.errorMessage = nil }
        }
    }

    // MARK: Episodios

    private var episodesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Episodios de postPod").font(.headline)
            if app.projects.isEmpty {
                Text("Todavía no hay episodios en postPod.").foregroundStyle(Theme.secondary)
            }
            ForEach(app.projects) { p in
                Button { select(p) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).bold().lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(p.reels.count) \(p.reels.count == 1 ? "reel" : "reels") · \(EditEngine.clock(p.duration))")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(projectId == p.id ? Theme.panelStrong : Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(projectId == p.id ? Color.pubPod : Theme.stroke))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(_ p: Project) {
        if let s = app.session, s.project.id != p.id, s.isBusy {
            error = "Espera a que termine «\(s.job?.title ?? "lo que se está haciendo")» en el otro episodio."
            return
        }
        projectId = p.id
    }

    // MARK: Qué publicar

    @ViewBuilder
    private func publishPane(_ p: Project) -> some View {
        if p.episode.prepodSlug == nil {
            Card {
                Label("Este episodio todavía no está vinculado a su podcast", systemImage: "link").font(.headline)
                Text("Vincúlalo una vez en postPod → Publicar y vuelve aquí.").foregroundStyle(Theme.secondary)
                Button("Ir a vincularlo") {
                    if app.session?.project.id != p.id { app.open(p) }
                    app.session?.step = .publish
                    app.section = .post
                }
            }
        } else {
            Card {
                Text("¿Qué publicas?").font(.headline)
                optionRow(.episode, "Episodio completo", "16:9 · \(EditEngine.clock(p.duration)) · solo YouTube", "rectangle.ratio.16.to.9")
                ForEach(p.reels) { r in
                    optionRow(.reel(r.id), r.title.isEmpty ? "Reel" : r.title, "Reel vertical · \(EditEngine.clock(r.length))", "rectangle.portrait")
                }
                if p.reels.isEmpty {
                    Text("Este episodio no tiene reels: márcalos en postPod → Reels.").font(.caption).foregroundStyle(Theme.secondary)
                }
                Button { chooseFile() } label: {
                    Label({ if case .file(let u) = choice { return "Video de la compu: \(u.lastPathComponent)" }; return "Subir un video desde la compu…" }(),
                          systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            if let choice { formCard(p, choice) }
            if let done { Label(done, systemImage: "star.fill").foregroundStyle(Color.pubPod).font(.headline) }
        }
    }

    private func optionRow(_ c: Choice, _ name: String, _ detail: String, _ symbol: String) -> some View {
        Button { set(c) } label: {
            HStack(spacing: 10) {
                Image(systemName: choice == c ? "largecircle.fill.circle" : "circle")
                Image(systemName: symbol).foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func set(_ c: Choice) {
        guard let p = project else { return }
        choice = c
        done = nil
        error = nil
        switch c {
        case .episode:
            title = Exporter.episodeTitle(p)
            let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
            captions = ["youtube": Exporter.notes(project: p, keep: keep, introDuration: p.intro.map { max(1, $0.seconds) } ?? 0)]
        case .reel(let id):
            let r = p.reels.first { $0.id == id }
            title = r?.title ?? ""
            let text = (r?.hook?.isEmpty == false ? r?.hook : nil) ?? title
            captions = Dictionary(uniqueKeysWithValues: PubNet.all.map { ($0.id, text) })
        case .file(let u):
            title = u.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            captions = [:]
        }
        pick = Dictionary(uniqueKeysWithValues: nets(for: c).map { ($0.id, accounts[$0.id]?.connected == true) })
    }

    private func nets(for c: Choice) -> [PubNet] {
        if case .episode = c { return [PubNet.named("youtube")] }
        return PubNet.all
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let u = panel.url else { return }
        set(.file(u))
    }

    // MARK: Formulario

    private func formCard(_ p: Project, _ c: Choice) -> some View {
        let options = nets(for: c)
        let working = sending || (session?.isBusy ?? false)
        return Card {
            TextField("Título", text: $title).textFieldStyle(.roundedBorder).disabled(working)
            ForEach(options) { n in
                if accounts[n.id]?.connected == true {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { pick[n.id] ?? false }, set: { pick[n.id] = $0 })) {
                            HStack(spacing: 6) {
                                Image(systemName: n.symbol)
                                Text(isShort(c, n) ? "YouTube Shorts" : n.name).bold()
                                if let u = accounts[n.id]?.username { Text(n.id == "instagram" ? "@\(u)" : u).foregroundStyle(Theme.secondary) }
                            }
                        }
                        .disabled(working)
                        if pick[n.id] == true {
                            TextEditor(text: Binding(get: { captions[n.id] ?? "" }, set: { captions[n.id] = $0 }))
                                .font(.callout).frame(height: c == .episode ? 120 : 60)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                                .disabled(working)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: n.symbol).foregroundStyle(Theme.secondary)
                        Text(n.name).foregroundStyle(Theme.secondary)
                        Text("· sin conectar").font(.caption).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Conectar en prePod") { app.section = .pre }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            if pick["tiktok"] == true, c != .episode {
                Text("TikTok: el video llega a tu bandeja y lo terminas de publicar desde el teléfono.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Picker("", selection: $later) {
                Text("Publicar ahora").tag(false)
                Text("Programar").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280).disabled(working)
            if later { DatePicker("Fecha y hora", selection: $whenDate, in: Date()...).disabled(working) }
            if let s = session, s.isBusy { PubProgress(session: s) }
            if sending { ProgressView(value: progress) { Text("Subiendo el video…").font(.caption) } }
            HStack {
                Button(actionTitle(c)) { publish(p, c) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || !options.contains { pick[$0.id] == true && accounts[$0.id]?.connected == true })
                Spacer()
            }
            if case .file = c {} else {
                Text("Se exporta tal como está en el editor de postPod.").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func isShort(_ c: Choice, _ n: PubNet) -> Bool { n.id == "youtube" && c != .episode }

    private func actionTitle(_ c: Choice) -> String {
        if case .file = c { return later ? "Subir y programar" : "Subir y publicar" }
        return later ? "Exportar y programar" : "Exportar y publicar"
    }

    private func publish(_ p: Project, _ c: Choice) {
        guard let slug = p.episode.prepodSlug else { return }
        if later && whenDate < Date() { error = "Esa fecha ya pasó."; return }
        let targets = nets(for: c).filter { pick[$0.id] == true && accounts[$0.id]?.connected == true }
            .map { (platform: $0.id, caption: captions[$0.id] ?? "") }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let at = later ? whenDate : nil
        error = nil
        done = nil
        switch c {
        case .file(let url):
            sending = true
            progress = 0
            Task {
                do {
                    let upload = try await PrePodClient.shared.upload(file: url) { f in Task { @MainActor in progress = f } }
                    _ = try await PrePodClient.shared.createReelPosts(slug: slug, episodeId: p.episode.prepodEpisodeId,
                                                                      uploadId: upload, title: cleanTitle, targets: targets, at: at)
                    done = later ? "Quedó programado." : "Enviado: sale en unos minutos."
                    postsVersion += 1
                } catch { self.error = error.localizedDescription }
                sending = false
            }
        case .episode, .reel:
            // Exportar necesita el episodio abierto en el editor (sin cambiar de pantalla)
            if app.session?.project.id != p.id { app.open(p) }
            guard let s = app.session else { return }
            if s.isBusy { error = "Espera a que termine «\(s.job?.title ?? "lo que se está haciendo")»."; return }
            if case .reel(let id) = c {
                guard var reel = s.project.reels.first(where: { $0.id == id }) else { return }
                reel.title = cleanTitle
                s.publishReel(reel, targets: targets, at: at)
            } else {
                s.publishEpisode(title: cleanTitle, description: captions["youtube"] ?? "", at: at)
            }
        }
    }

    private func loadAccounts() {
        guard PrePodClient.isConfigured, let slug, accountsFor != slug || accounts.isEmpty else { return }
        accountsFor = slug
        Task {
            do { accounts = try await PrePodClient.shared.pubAccounts(slug: slug) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Progreso de lo que el editor está exportando y subiendo para pubPod.
private struct PubProgress: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        if let j = session.job {
            VStack(alignment: .leading, spacing: 4) {
                Text(j.detail.isEmpty ? j.title : j.detail).font(.caption)
                if let f = j.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
            }
        }
    }
}

// MARK: - Publicaciones de un podcast

struct PubPostsList: View {
    let slug: String
    @State private var posts: [PrePodClient.PubPost] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Publicaciones").font(.title3.bold())
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Actualizar")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if loaded && posts.isEmpty { Text("Todavía no hay publicaciones.").foregroundStyle(Theme.secondary) }
            ForEach(posts) { p in card(p) }
        }
        .task { await load() }
        .task {
            // Mientras algo esté saliendo, se actualiza solo cada 10 s
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let soon = Date().addingTimeInterval(60)
                if posts.contains(where: { $0.status == "publishing" || ($0.status == "scheduled" && (date($0) ?? .distantFuture) <= soon) }) {
                    await load()
                }
            }
        }
    }

    private func card(_ p: PrePodClient.PubPost) -> some View {
        let net = PubNet.named(p.platform)
        return Card {
            HStack(spacing: 8) {
                Image(systemName: net.symbol)
                Text(p.title).bold().lineLimit(1)
                Spacer()
                Text(statusText(p)).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(statusColor(p).opacity(0.15)))
                    .foregroundStyle(statusColor(p))
            }
            HStack(spacing: 12) {
                Text("\(p.platform == "youtube" && p.kind != "episode" ? "YouTube Shorts" : net.name) · \(when(p))")
                    .font(.caption).foregroundStyle(Theme.secondary)
                if let s = p.result_url, let u = URL(string: s) { Link("Ver publicación", destination: u).font(.caption) }
                if p.status == "scheduled" { Button("Cancelar") { act(p, "cancel") }.buttonStyle(.borderless).font(.caption) }
                if p.status == "error" { Button("Reintentar") { act(p, "retry") }.buttonStyle(.borderless).font(.caption) }
            }
            if p.status == "inbox" {
                HStack {
                    Text("Abre TikTok en tu teléfono: te llegó una notificación para terminar de publicarlo.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    if let c = p.caption, !c.isEmpty {
                        Button("Copiar el texto") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            if p.status == "private" {
                Text("YouTube lo dejó en privado mientras thePod espera su aprobación. Ábrelo y cámbialo a «Público».")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if let e = p.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func statusText(_ p: PrePodClient.PubPost) -> String {
        if p.status == "scheduled", let d = date(p), d <= Date() { return "En cola" }
        return ["scheduled": "Programado", "publishing": "Publicando…", "published": "Publicado",
                "private": "Subido en privado", "inbox": "En tu bandeja de TikTok",
                "error": "No se publicó", "cancelled": "Cancelado"][p.status] ?? p.status
    }
    private func statusColor(_ p: PrePodClient.PubPost) -> Color {
        switch p.status {
        case "published", "inbox": return Theme.good
        case "error": return .red
        case "cancelled": return Theme.secondary
        default: return .orange
        }
    }
    private func date(_ p: PrePodClient.PubPost) -> Date? { p.scheduled_at.flatMap { ISO8601DateFormatter().date(from: $0) } }
    private func when(_ p: PrePodClient.PubPost) -> String { date(p)?.formatted(date: .abbreviated, time: .shortened) ?? "" }

    private func load() async {
        do { posts = try await PrePodClient.shared.pubPosts(slug: slug); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }
    private func act(_ p: PrePodClient.PubPost, _ action: String) {
        Task {
            do { try await PrePodClient.shared.pubPostAction(slug: slug, id: p.id, action: action); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
