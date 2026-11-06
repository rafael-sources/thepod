import SwiftUI

/// prePod → Configurar podcast → Redes: ONLY connect the podcast's accounts.
/// Each account lights up its stars in pubPod (shown alongside). Publishing is done in pubPod.
struct RedesTab: View {
    let slug: String
    @EnvironmentObject var app: AppModel

    private struct Row: Identifiable {
        let id: String; let name: String; let note: String; let stars: [String]; let connectable: Bool
    }
    private let rows = [
        Row(id: "feed", name: String(localized: "Feed del podcast"), note: String(localized: "Spotify y Apple Podcasts lo leen solos"), stars: ["spotify", "apple"], connectable: false),
        Row(id: "youtube", name: "YouTube", note: String(localized: "Tu canal: los episodios y los Shorts"), stars: ["youtube", "shorts"], connectable: true),
        Row(id: "instagram", name: "Instagram", note: String(localized: "Cuenta profesional: la portada y los Reels"), stars: ["instagram", "reels"], connectable: true),
        Row(id: "tiktok", name: "TikTok", note: String(localized: "Los reels llegan a tu bandeja y los publicas desde el teléfono"), stars: ["tiktok"], connectable: true),
        Row(id: "facebook", name: "Facebook", note: "", stars: ["facebook"], connectable: true),
    ]

    @State private var accounts: [String: PrePodClient.PubAccount] = [:]
    @State private var available: [String: Bool] = [:]
    @State private var loaded = false
    @State private var connecting: String?
    @State private var error: String?
    @State private var watcher: Task<Void, Never>?

    private enum RowState { case on, off, soon, feedOff }
    private func state(_ r: Row) -> RowState {
        if accounts[r.id]?.connected == true { return .on }
        if r.id == "feed" { return .feedOff }
        return available[r.id] == true ? .off : .soon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conecta aquí las cuentas del podcast, una sola vez. Cada cuenta enciende sus estrellas en pubPod.")
                .foregroundStyle(Theme.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !loaded { ProgressView() }
            ForEach(rows) { r in rowView(r) }
            HStack {
                Text("Para publicar reels y episodios, abre pubPod.").foregroundStyle(Theme.secondary)
                Button { app.section = .pub } label: { Label("Ir a pubPod", systemImage: "star.fill") }.buttonStyle(.bordered)
            }
            .padding(.top, 6)
        }
        .task { await load() }
        .onDisappear { watcher?.cancel() }
    }

    private func rowView(_ r: Row) -> some View {
        let st = state(r)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.headline)
                if !r.note.isEmpty { Text(r.note).font(.caption).foregroundStyle(Theme.secondary) }
            }
            .frame(width: 190, alignment: .leading)
            HStack(spacing: 14) {
                ForEach(r.stars, id: \.self) { id in
                    let s = PubStar.all.first { $0.id == id }
                    HStack(spacing: 6) {
                        ZStack {
                            if st == .on { StarShape().fill(Color.white) }
                            else { StarShape().stroke(st == .soon ? Color(white: 0.36) : Color(white: 0.6), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round, dash: st == .soon ? [3, 3] : [])) }
                        }
                        .frame(width: 16, height: 16)
                        Text(s?.name ?? id).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(st == .on ? .white : st == .soon ? Color(white: 0.36) : Theme.secondary)
                    }
                }
            }
            Spacer()
            switch st {
            case .on:
                Text(who(r)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.good)
                if r.connectable { Button("Desconectar") { disconnect(r.id) }.controlSize(.small) }
            case .off:
                if connecting == r.id {
                    ProgressView().controlSize(.small)
                    Text("Termina en el navegador…").font(.caption).foregroundStyle(Theme.secondary)
                    Button("Cancelar") { watcher?.cancel(); connecting = nil }.buttonStyle(.borderless)
                } else {
                    Button("Conectar") { connect(r.id) }.buttonStyle(.borderedProminent).disabled(connecting != nil)
                }
            case .feedOff:
                Text("Configúralo en Distribución").font(.caption).foregroundStyle(Theme.secondary)
            case .soon:
                Text("muy pronto").font(.caption).foregroundStyle(Color(white: 0.45))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.stroke))
        .opacity(st == .soon ? 0.6 : 1)
    }

    private func who(_ r: Row) -> String {
        let a = accounts[r.id]
        if r.id == "feed" { return String(localized: "Listo") }
        if r.id == "instagram", let u = a?.username, !u.isEmpty { return "@\(u)" }
        return a?.username ?? String(localized: "Conectado")
    }

    private func load() async {
        available = await PrePodClient.shared.pubNetworks()
        do { accounts = try await PrePodClient.shared.pubAccounts(slug: slug); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    /// Opens the network's page in the browser and waits for the connection to appear (up to 5 minutes).
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
                    if acc[net]?.connected == true { accounts = acc; connecting = nil; return }
                }
                connecting = nil
                error = String(localized: "No vimos la conexión. Si ya diste el permiso, vuelve a entrar a Redes.")
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
