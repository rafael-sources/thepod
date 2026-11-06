import SwiftUI

/// pubPod desde la app: publica un reel en las redes conectadas del podcast (ahora o programado).
struct PublishReelSheet: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel
    @Environment(\.dismiss) private var dismiss

    private struct Net: Identifiable { let id: String; let name: String; let symbol: String }
    private let nets = [Net(id: "instagram", name: "Instagram", symbol: "camera"),
                        Net(id: "youtube", name: "YouTube Shorts", symbol: "play.rectangle"),
                        Net(id: "tiktok", name: "TikTok", symbol: "music.note")]

    @State private var accounts: [String: PrePodClient.PubAccount]?
    @State private var available: [String: Bool] = [:]
    @State private var connecting: String?
    @State private var watcher: Task<Void, Never>?
    @State private var loadError: String?
    @State private var pick: [String: Bool] = [:]
    @State private var captions: [String: String] = [:]
    @State private var later = false
    @State private var when = Date().addingTimeInterval(3600)
    @State private var sent = false
    @State private var failure: String?

    private var slug: String? { session.project.episode.prepodSlug }
    private var connected: [Net] { nets.filter { accounts?[$0.id]?.connected == true } }
    private var chosen: [Net] { connected.filter { pick[$0.id] == true } }
    private var working: Bool { sent && session.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Publicar en redes", systemImage: "paperplane.fill").font(.title3.bold())
                Spacer()
                Text(reel.title).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Divider()
            Group {
                if !PrePodClient.isConfigured {
                    Text("Conecta la app con thePod en Ajustes (⌘,) para publicar.")
                        .foregroundStyle(Theme.secondary)
                } else if slug == nil {
                    Text("Primero vincula este episodio con su podcast en Entregar → Publicar. Se hace una sola vez.")
                        .foregroundStyle(Theme.secondary)
                } else if let posts = session.reelPosts, sent, !session.isBusy {
                    result(posts)
                } else if working {
                    progress
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if accounts == nil {
                    ProgressView().controlSize(.small)
                } else {
                    form
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            Divider()
            HStack {
                if let base = URL(string: PrePodClient.baseURL) {
                    Link("Ver todo en prePod → Redes", destination: base).font(.caption)
                }
                Spacer()
                if sent && session.reelPosts != nil && !session.isBusy {
                    Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancelar") { if working { session.cancelJob() }; dismiss() }
                    Button(later ? String(localized: "Programar") : String(localized: "Publicar")) { send() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty || session.isBusy || slug == nil)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear(perform: load)
        .onDisappear { watcher?.cancel() }
        .onChange(of: session.isBusy) { _, busy in
            // Si falló, el error queda aquí en la ventana y no detrás de ella
            if sent, !busy, session.reelPosts == nil, let msg = session.errorMessage {
                failure = msg
                session.errorMessage = nil
                sent = false
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connected.isEmpty {
                Text("Conecta tus redes una sola vez: se abre el navegador para que des el permiso y vuelves aquí.")
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(nets) { n in
                if accounts?[n.id]?.connected == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: pickBinding(n.id)) {
                            HStack(spacing: 6) {
                                Image(systemName: n.symbol)
                                Text(n.name).bold()
                                if let u = accounts?[n.id]?.username {
                                    Text(n.id == "instagram" ? "@\(u)" : u).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        if pick[n.id] == true {
                            TextEditor(text: captionBinding(n.id))
                                .font(.callout)
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: n.symbol).foregroundStyle(Theme.secondary)
                        Text(n.name).foregroundStyle(Theme.secondary)
                        Spacer()
                        if available[n.id] == false {
                            Text("muy pronto").font(.caption).foregroundStyle(Theme.secondary)
                        } else if connecting == n.id {
                            ProgressView().controlSize(.small)
                            Text("Termina en el navegador…").font(.caption).foregroundStyle(Theme.secondary)
                        } else {
                            Button("Conectar") { connect(n.id) }.controlSize(.small)
                        }
                    }
                    if connecting == n.id && n.id == "instagram" {
                        Text("Usa una cuenta profesional de Instagram (creador o empresa).")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            if pick["tiktok"] == true {
                Text("TikTok: el reel llega a tu bandeja y lo terminas de publicar desde el teléfono, pegando el texto.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Text("Facebook: muy pronto.").font(.caption).foregroundStyle(Theme.secondary)
            Picker("", selection: $later) {
                Text("Publicar ahora").tag(false)
                Text("Programar").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            if later {
                DatePicker("Fecha y hora", selection: $when, in: Date()...)
            }
            Text("Se exporta el reel tal como lo ves ahora, vertical y con subtítulos.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.job?.detail.isEmpty == false ? session.job!.detail : (session.job?.title ?? String(localized: "Preparando…")))
            if let f = session.job?.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
        }
    }

    private func result(_ posts: [PrePodClient.PubPost]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(later ? String(localized: "Quedó programado") : String(localized: "Enviado"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(Theme.good).font(.headline)
            ForEach(posts) { p in
                HStack {
                    Text(nets.first { $0.id == p.platform }?.name ?? p.platform).bold()
                    Text(later ? String(localized: "para el \(when.formatted(date: .abbreviated, time: .shortened))")
                         : p.platform == "tiktok" ? String(localized: "llegará a tu bandeja de TikTok en unos minutos") : String(localized: "en cola, sale en uno o dos minutos"))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Text("Puedes cerrar esta ventana: thePod lo publica aunque cierres la app. El enlace a cada publicación aparece en prePod → Redes.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private func pickBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { pick[key] ?? false }, set: { pick[key] = $0 })
    }
    private func captionBinding(_ key: String) -> Binding<String> {
        Binding(get: { captions[key] ?? "" }, set: { captions[key] = $0 })
    }

    private func load() {
        guard PrePodClient.isConfigured, let slug else { return }
        session.reelPosts = nil
        let suggested = reel.hook?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? reel.title
        Task {
            do {
                available = await PrePodClient.shared.pubNetworks()
                let acc = try await PrePodClient.shared.pubAccounts(slug: slug)
                accounts = acc
                for n in nets {
                    pick[n.id] = acc[n.id]?.connected == true
                    captions[n.id] = suggested
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    /// Abre la página de la red en el navegador y espera a que la conexión aparezca (hasta 5 minutos).
    private func connect(_ net: String) {
        guard let slug else { return }
        failure = nil
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
                        pick[net] = true
                        connecting = nil
                        return
                    }
                }
                connecting = nil
                failure = String(localized: "No vimos la conexión. Si ya diste el permiso, cierra y vuelve a abrir esta ventana.")
            } catch is CancellationError {
            } catch {
                connecting = nil
                failure = error.localizedDescription
            }
        }
    }

    private func send() {
        failure = nil
        if later && when < Date() { failure = String(localized: "Esa fecha ya pasó."); return }
        let targets = chosen.map { (platform: $0.id, caption: captions[$0.id] ?? "") }
        sent = true
        session.publishReel(reel, targets: targets, at: later ? when : nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
