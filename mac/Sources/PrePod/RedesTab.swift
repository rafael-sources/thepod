import SwiftUI

/// prePod → Configurar podcast → Redes: SOLO conectar Instagram, YouTube y TikTok.
/// Publicar (reels y episodio, al momento o programado) se hace en pubPod.
struct RedesTab: View {
    let slug: String
    @EnvironmentObject var app: AppModel

    private struct Net: Identifiable { let id: String; let name: String; let symbol: String; let note: String }
    private let nets = [
        Net(id: "instagram", name: "Instagram", symbol: "camera",
            note: "Necesitas una cuenta profesional de Instagram (creador o empresa)."),
        Net(id: "youtube", name: "YouTube", symbol: "play.rectangle",
            note: "Para tus Shorts y el episodio completo. Es el mismo canal de Distribución."),
        Net(id: "tiktok", name: "TikTok", symbol: "music.note",
            note: "El reel llega a tu bandeja de TikTok y lo terminas de publicar desde el teléfono."),
    ]

    @State private var accounts: [String: PrePodClient.PubAccount] = [:]
    @State private var available: [String: Bool] = [:]
    @State private var loaded = false
    @State private var connecting: String?
    @State private var error: String?
    @State private var watcher: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Conecta aquí las redes del podcast, una sola vez. Para publicar, ve a pubPod.")
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
            Button { app.section = .pub } label: { Label("Ir a pubPod para publicar", systemImage: "star.fill") }
                .buttonStyle(.bordered)
        }
        .task { await load() }
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

    // MARK: Acciones

    private func load() async {
        available = await PrePodClient.shared.pubNetworks()
        do {
            accounts = try await PrePodClient.shared.pubAccounts(slug: slug)
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
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
}
