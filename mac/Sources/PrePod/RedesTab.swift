import SwiftUI
import UniformTypeIdentifiers

/// prePod → Configurar podcast → Redes: conectar Instagram, YouTube y TikTok (pubPod)
/// y ver cómo van las publicaciones de reels. Lo mismo que la pestaña Redes de prePod web.
struct RedesTab: View {
    let slug: String

    private struct Net: Identifiable { let id: String; let name: String; let symbol: String; let note: String }
    private let nets = [
        Net(id: "instagram", name: "Instagram", symbol: "camera",
            note: "Necesitas una cuenta profesional de Instagram (creador o empresa)."),
        Net(id: "youtube", name: "YouTube Shorts", symbol: "play.rectangle",
            note: "Es el mismo canal que usas para los episodios."),
        Net(id: "tiktok", name: "TikTok", symbol: "music.note",
            note: "El reel llega a tu bandeja de TikTok y lo terminas de publicar desde el teléfono."),
    ]

    @State private var accounts: [String: PrePodClient.PubAccount] = [:]
    @State private var available: [String: Bool] = [:]
    @State private var posts: [PrePodClient.PubPost] = []
    @State private var loaded = false
    @State private var connecting: String?
    @State private var error: String?
    @State private var watcher: Task<Void, Never>?
    // Nuevo reel (igual que en prePod web)
    @State private var file: URL?
    @State private var title = ""
    @State private var pick: [String: Bool] = [:]
    @State private var captions: [String: String] = [:]
    @State private var later = false
    @State private var whenDate = Date().addingTimeInterval(3600)
    @State private var sending = false
    @State private var progress = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Publica tus reels en tus redes, al momento o programados.")
                .foregroundStyle(Theme.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !loaded { ProgressView() }
            ForEach(nets) { n in netCard(n) }
            Card {
                HStack {
                    Image(systemName: "f.square").foregroundStyle(Theme.secondary)
                    Text("Facebook").font(.headline).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("muy pronto").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            newReelCard
            HStack {
                Text("Publicaciones").font(.title3.bold())
                Spacer()
                Button { Task { await loadPosts() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Actualizar")
            }
            .padding(.top, 8)
            if loaded && posts.isEmpty {
                Text("Todavía no hay publicaciones.").foregroundStyle(Theme.secondary)
            }
            ForEach(posts) { p in postCard(p) }
        }
        .task { await load() }
        .task {
            // Igual que la web: mientras haya algo saliendo, se actualiza solo cada 10 s
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let soon = Date().addingTimeInterval(60)
                if posts.contains(where: { $0.status == "publishing" || ($0.status == "scheduled" && (date($0) ?? .distantFuture) <= soon) }) {
                    await loadPosts()
                }
            }
        }
        .onDisappear { watcher?.cancel() }
    }

    // MARK: Redes

    private func netCard(_ n: Net) -> some View {
        let acc = accounts[n.id]
        let on = acc?.connected == true
        return Card {
            HStack(spacing: 8) {
                Image(systemName: n.symbol)
                Text(n.name).font(.headline)
                Spacer()
                if on {
                    Label(display(n.id, acc?.username), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good).lineLimit(1)
                } else if available[n.id] == false {
                    Text("muy pronto").font(.caption).foregroundStyle(Theme.secondary)
                } else {
                    Text("Sin conectar").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Text(n.note).font(.caption).foregroundStyle(Theme.secondary)
            if available[n.id] != false || on {
                HStack {
                    if on {
                        Button("Desconectar", role: .destructive) { disconnect(n.id) }
                    } else if connecting == n.id {
                        ProgressView().controlSize(.small)
                        Text("Termina de dar el permiso en el navegador…").font(.caption).foregroundStyle(Theme.secondary)
                        Button("Cancelar") { watcher?.cancel(); connecting = nil }.buttonStyle(.borderless)
                    } else {
                        Button("Conectar \(n.name)") { connect(n.id) }.buttonStyle(.borderedProminent)
                            .disabled(connecting != nil)
                    }
                }
            }
        }
    }

    private func display(_ net: String, _ user: String?) -> String {
        guard let user, !user.isEmpty else { return "Conectado" }
        return net == "instagram" ? "@\(user)" : user
    }

    // MARK: Nuevo reel

    private var connectedNets: [Net] { nets.filter { accounts[$0.id]?.connected == true } }

    private var newReelCard: some View {
        Card {
            Text("Nuevo reel").font(.headline)
            if connectedNets.isEmpty {
                Text("Conecta al menos una red para publicar.").foregroundStyle(Theme.secondary)
            } else {
                HStack {
                    Button(file == nil ? "Elegir video (vertical)…" : "Cambiar video…") { chooseFile() }
                        .disabled(sending)
                    if let file { Text(file.lastPathComponent).lineLimit(1).foregroundStyle(Theme.secondary) }
                }
                TextField("Título", text: $title).textFieldStyle(.roundedBorder).disabled(sending)
                ForEach(connectedNets) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { pick[n.id] ?? true }, set: { pick[n.id] = $0 })) {
                            Label(n.name, systemImage: n.symbol)
                        }
                        .disabled(sending)
                        if pick[n.id] ?? true {
                            TextEditor(text: Binding(get: { captions[n.id] ?? "" }, set: { captions[n.id] = $0 }))
                                .font(.callout).frame(height: 60)
                                .overlay(alignment: .topLeading) {
                                    if (captions[n.id] ?? "").isEmpty {
                                        Text(n.id == "youtube" ? "Descripción del Short"
                                             : n.id == "tiktok" ? "Texto para pegar en TikTok al publicarlo"
                                             : "Texto del reel, con tus hashtags")
                                            .font(.callout).foregroundStyle(Theme.secondary).padding(6).allowsHitTesting(false)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                                .disabled(sending)
                        }
                    }
                }
                Picker("", selection: $later) {
                    Text("Publicar ahora").tag(false)
                    Text("Programar").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280).disabled(sending)
                if later { DatePicker("Fecha y hora", selection: $whenDate, in: Date()...).disabled(sending) }
                HStack {
                    Button(sending ? "Subiendo \(Int(progress * 100)) %" : (later ? "Programar" : "Publicar")) { publish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || file == nil || title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || !connectedNets.contains { pick[$0.id] ?? true })
                    if sending { ProgressView(value: progress).frame(maxWidth: 200) }
                }
            }
        }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return }
        file = u
        if title.isEmpty {
            title = u.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        }
    }

    private func publish() {
        guard let file else { return }
        if later && whenDate < Date() { error = "Esa fecha ya pasó."; return }
        let targets = connectedNets.filter { pick[$0.id] ?? true }.map { (platform: $0.id, caption: captions[$0.id] ?? "") }
        error = nil
        sending = true
        progress = 0
        Task {
            do {
                let upload = try await PrePodClient.shared.upload(file: file) { f in
                    Task { @MainActor in progress = f }
                }
                _ = try await PrePodClient.shared.createReelPosts(slug: slug, episodeId: nil, uploadId: upload,
                                                                  title: title.trimmingCharacters(in: .whitespaces),
                                                                  targets: targets, at: later ? whenDate : nil)
                self.file = nil
                title = ""
                captions = [:]
                later = false
                await loadPosts()
            } catch { self.error = error.localizedDescription }
            sending = false
        }
    }

    // MARK: Publicaciones

    private func postCard(_ p: PrePodClient.PubPost) -> some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: nets.first { $0.id == p.platform }?.symbol ?? "paperplane")
                Text(p.title).bold().lineLimit(1)
                Spacer()
                Text(statusText(p)).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(statusColor(p).opacity(0.15)))
                    .foregroundStyle(statusColor(p))
            }
            HStack(spacing: 12) {
                Text("\(nets.first { $0.id == p.platform }?.name ?? p.platform) · \(when(p))")
                    .font(.caption).foregroundStyle(Theme.secondary)
                if let s = p.result_url, let u = URL(string: s) { Link("Ver publicación", destination: u).font(.caption) }
                if p.status == "scheduled" {
                    Button("Cancelar") { act(p, "cancel") }.buttonStyle(.borderless).font(.caption)
                }
                if p.status == "error" {
                    Button("Reintentar") { act(p, "retry") }.buttonStyle(.borderless).font(.caption)
                }
            }
            if p.status == "inbox" {
                HStack {
                    Text("Abre TikTok en tu teléfono: te llegó una notificación para terminar de publicarlo.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    if let c = p.caption, !c.isEmpty {
                        Button("Copiar el texto") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string)
                        }.buttonStyle(.borderless).font(.caption)
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

    private func date(_ p: PrePodClient.PubPost) -> Date? {
        p.scheduled_at.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private func when(_ p: PrePodClient.PubPost) -> String {
        date(p)?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    // MARK: Acciones

    private func load() async {
        available = await PrePodClient.shared.pubNetworks()
        do {
            accounts = try await PrePodClient.shared.pubAccounts(slug: slug)
            error = nil
        } catch { self.error = error.localizedDescription }
        await loadPosts()
        loaded = true
    }

    private func loadPosts() async {
        do { posts = try await PrePodClient.shared.pubPosts(slug: slug) }
        catch { self.error = error.localizedDescription }
    }

    /// Abre la página de la red en el navegador y espera a que la conexión aparezca (hasta 5 minutos).
    private func connect(_ net: String) {
        error = nil
        connecting = net
        watcher?.cancel()
        watcher = Task {
            do {
                let url = try await PrePodClient.shared.connectURL(network: net, slug: slug)
                NSWorkspace.shared.open(url)
                for _ in 0..<100 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let acc = try await PrePodClient.shared.pubAccounts(slug: slug)
                    if acc[net]?.connected == true {
                        accounts = acc
                        connecting = nil
                        return
                    }
                }
                connecting = nil
                error = "No vimos la conexión. Si ya diste el permiso, toca actualizar."
            } catch is CancellationError {
            } catch {
                connecting = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func disconnect(_ net: String) {
        Task {
            do {
                try await PrePodClient.shared.pubDisconnect(slug: slug, network: net)
                accounts = try await PrePodClient.shared.pubAccounts(slug: slug)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func act(_ p: PrePodClient.PubPost, _ action: String) {
        Task {
            do { try await PrePodClient.shared.pubPostAction(slug: slug, id: p.id, action: action); await loadPosts() }
            catch { self.error = error.localizedDescription }
        }
    }
}
