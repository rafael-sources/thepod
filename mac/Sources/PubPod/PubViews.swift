import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// pubPod: el blanco de las estrellas.
    static let pubPod = Color.white
}

// MARK: - Las 8 estrellas

/// Una estrella = un destino. `platform` es el destino en el servidor; Spotify y Apple comparten el feed.
struct PubStar: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: String        // instagram, instagram_image, youtube, tiktok, feed, facebook
    let account: String         // la conexión que necesita (de prePod → Redes)
    let forEpisode: Bool        // episodio completo (true) o reel (false)

    static let all = [
        PubStar(id: "spotify", name: "Spotify", platform: "feed", account: "feed", forEpisode: true),
        PubStar(id: "apple", name: "Apple Podcasts", platform: "feed", account: "feed", forEpisode: true),
        PubStar(id: "youtube", name: "YouTube", platform: "youtube", account: "youtube", forEpisode: true),
        PubStar(id: "instagram", name: "Instagram", platform: "instagram_image", account: "instagram", forEpisode: true),
        PubStar(id: "shorts", name: "Shorts", platform: "youtube", account: "youtube", forEpisode: false),
        PubStar(id: "reels", name: "Reels", platform: "instagram", account: "instagram", forEpisode: false),
        PubStar(id: "tiktok", name: "TikTok", platform: "tiktok", account: "tiktok", forEpisode: false),
        PubStar(id: "facebook", name: "Facebook", platform: "facebook", account: "facebook", forEpisode: false),
    ]

    /// La estrella de una publicación ya hecha (para la lista).
    static func of(platform: String, kind: String?) -> PubStar? {
        switch platform {
        case "feed": return all[0]
        case "youtube": return kind == "episode" ? all[2] : all[4]
        case "instagram_image": return all[3]
        case "instagram": return all[5]
        default: return all.first { $0.platform == platform }
        }
    }
}

struct StarShape: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(24, 2.5), (29.8, 17.4), (45.5, 18.1), (33.2, 28), (37.5, 43.5),
                                         (24, 34.7), (10.5, 43.5), (14.8, 28), (2.5, 18.1), (18.2, 17.4)]
        var p = Path()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: r.minX + q.0 / 48 * r.width, y: r.minY + q.1 / 48 * r.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Ícono propio de cada red (trazos simples, no los logos de las marcas).
struct PubGlyph: View {
    let id: String
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rr: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: rr * s)
            }
            var p = Path()
            switch id {
            case "spotify":
                p.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s))
                p.move(to: P(7.5, 10)); p.addQuadCurve(to: P(17, 10.8), control: P(12, 8.6))
                p.move(to: P(8, 13.2)); p.addQuadCurve(to: P(15.5, 13.9), control: P(11.8, 12.2))
                p.move(to: P(8.6, 16.1)); p.addQuadCurve(to: P(14.3, 16.6), control: P(11.5, 15.4))
            case "apple":
                p.addEllipse(in: CGRect(x: 9.4 * s, y: 7.4 * s, width: 5.2 * s, height: 5.2 * s))
                p.move(to: P(12, 13.4)); p.addLine(to: P(12, 21))
                p.addArc(center: P(12, 10.6), radius: 6.2 * s, startAngle: .degrees(140), endAngle: .degrees(40), clockwise: false)
            case "youtube":
                p.addPath(R(2.5, 5.5, 19, 13, 3.5))
                p.move(to: P(10.2, 9.4)); p.addLine(to: P(10.2, 14.6)); p.addLine(to: P(14.6, 12)); p.closeSubpath()
            case "shorts":
                p.addPath(R(6.5, 2.5, 11, 19, 3))
                p.move(to: P(10.6, 9.6)); p.addLine(to: P(10.6, 14.4)); p.addLine(to: P(14.4, 12)); p.closeSubpath()
            case "instagram":
                p.addPath(R(3.5, 3.5, 17, 17, 5))
                p.addEllipse(in: CGRect(x: 8.2 * s, y: 8.2 * s, width: 7.6 * s, height: 7.6 * s))
                p.addEllipse(in: CGRect(x: 16.6 * s, y: 6.2 * s, width: 1.2 * s, height: 1.2 * s))
            case "reels":
                p.addPath(R(3.5, 3.5, 17, 17, 4.5))
                p.move(to: P(3.5, 8.8)); p.addLine(to: P(20.5, 8.8))
                p.move(to: P(8.6, 3.5)); p.addLine(to: P(11, 8.8))
                p.move(to: P(14, 3.5)); p.addLine(to: P(16.4, 8.8))
                p.move(to: P(10.6, 12.4)); p.addLine(to: P(10.6, 16.8)); p.addLine(to: P(14.2, 14.6)); p.closeSubpath()
            case "tiktok":
                p.move(to: P(13.8, 3.5)); p.addLine(to: P(13.8, 14.5))
                p.addArc(center: P(10.2, 14.5), radius: 3.6 * s, startAngle: .degrees(0), endAngle: .degrees(270), clockwise: false)
                p.move(to: P(13.8, 3.5)); p.addQuadCurve(to: P(18.6, 7.7), control: P(14.6, 7.3))
            default: // facebook
                p.addPath(R(3.5, 3.5, 17, 17, 4.5))
                p.move(to: P(15, 8)); p.addLine(to: P(13.4, 8)); p.addQuadCurve(to: P(11.2, 10.2), control: P(11.2, 8))
                p.addLine(to: P(11.2, 20.5))
                p.move(to: P(8.8, 13)); p.addLine(to: P(14.4, 13))
            }
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.9 * s, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct StarButton: View {
    let star: PubStar
    let online: Bool
    let eligible: Bool
    let on: Bool
    let pulsing: Bool
    let done: Bool
    let toggle: () -> Void
    let connect: () -> Void
    let open: () -> Void
    @State private var beat = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: toggle) {
                ZStack {
                    if on {
                        StarShape().fill(Color.pubPod)
                    } else {
                        StarShape().stroke(strokeColor, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round, dash: online ? [] : [3, 3]))
                    }
                    PubGlyph(id: star.id)
                        .frame(width: 17, height: 17)
                        .foregroundStyle(on ? Color(white: 0.07) : inkColor)
                        .offset(y: 3)
                }
                .frame(width: 64, height: 64)
                .shadow(color: .white.opacity(on ? (done ? 0.85 : 0.5) : 0), radius: on ? (done ? 18 : 11) : 0)
                .scaleEffect(pulsing && beat ? 1.12 : (done ? 1.06 : 1))
                .animation(pulsing ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true) : .spring(response: 0.35, dampingFraction: 0.6), value: beat)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: on)
                .animation(.easeOut(duration: 0.6), value: done)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!(online && eligible))
            .accessibilityLabel(star.name + (on ? String(localized: ", elegida") : ""))
            .contextMenu { Button("Ver detalles…", action: open) }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in open() })
            Button(action: open) {
                Text(star.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(labelColor).lineLimit(1)
            }
            .buttonStyle(.plain).help("Ver esta red")
            if !online {
                Button("Conectar", action: connect).buttonStyle(.plain).font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 112, height: 116, alignment: .top)
        .opacity(online && !eligible ? 0.55 : 1)
        .onChange(of: pulsing) { _, v in beat = v }
        .onAppear { beat = pulsing }
    }
    private var strokeColor: Color { !online ? Color(white: 0.36) : eligible ? .white : Color(white: 0.3) }
    private var inkColor: Color { !online ? Color(white: 0.43) : eligible ? .white : Color(white: 0.38) }
    private var labelColor: Color { !online ? Color(white: 0.55) : eligible ? .white : Color(white: 0.5) }
}

// MARK: - pubPod

struct PubHomeView: View {
    @EnvironmentObject var app: AppModel
    /// Solo para las capturas de prueba: abrir con el primer reel elegido.
    static var snapshotReel = false
    static var snapshotPanel: String?

    enum Choice: Hashable { case episode, reel(UUID), file(URL) }
    enum Phase { case choose, sending, done }

    @State private var projectId: String?
    @State private var choice: Choice = .episode
    @State private var accounts: [String: PrePodClient.PubAccount] = [:]
    @State private var error: String?
    @State private var title = ""
    @State private var picked: Set<String> = []        // ids de estrella
    @State private var captions: [String: String] = [:] // por destino (platform)
    @State private var tab: String?
    @State private var later = false
    @State private var whenDate = Date().addingTimeInterval(3600)
    @State private var phase: Phase = .choose
    @State private var progress = 0.0
    @State private var postsVersion = 0
    @State private var panel: PubStar?                  // panel de una estrella (al tocar su nombre o mantener)
    @State private var signatures: [String: String] = [:]
    @State private var posts: [PrePodClient.PubPost] = []

    private var project: Project? {
        guard let projectId else { return nil }
        if let s = app.session, s.project.id == projectId { return s.project }
        return app.projects.first { $0.id == projectId }
    }
    private var slug: String? { project?.episode.prepodSlug }
    private var session: ProjectSession? { app.session.flatMap { $0.project.id == projectId ? $0 : nil } }
    private var isEpisode: Bool { if case .episode = choice { return true }; return false }

    private func online(_ s: PubStar) -> Bool { accounts[s.account]?.connected == true }
    private func eligible(_ s: PubStar) -> Bool { s.forEpisode == isEpisode }
    private func isOn(_ s: PubStar) -> Bool { picked.contains(s.id) && online(s) && eligible(s) }
    /// Destinos elegidos, sin repetir (Spotify y Apple son un solo envío al feed).
    private var targets: [PubStar] {
        var seen = Set<String>()
        return PubStar.all.filter { isOn($0) && seen.insert($0.platform).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                    SectionSwitcher()
                    Spacer()
                    SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
                }
                if !PrePodClient.isConfigured {
                    Card {
                        Label("Conecta la app con thePod en Ajustes.", systemImage: "person.badge.key")
                        SettingsLink { Text("Abrir Ajustes") }
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    episodesColumn.frame(width: 260)
                    VStack(alignment: .leading, spacing: 20) {
                        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        if let project, project.episode.prepodSlug == nil {
                            unlinked(project)
                        } else if let project {
                            constellation(project)
                                .overlay(alignment: .top) { if let st = panel { starPanel(st) } }
                                .zIndex(1)
                            chooser(project)
                            composer
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let slug {
                        PubPostsList(slug: slug, onLoaded: { posts = $0 }).id("\(slug)-\(postsVersion)").frame(width: 300)
                    }
                }
            }
            .padding(28)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .tint(.pubPod)
        .onAppear {
            app.reload()
            if projectId == nil { projectId = app.session?.project.id ?? app.projects.first?.id }
            if Self.snapshotReel, let r = project?.reels.first { choice = .reel(r.id) }
            reset(); loadAccounts()
            if let id = Self.snapshotPanel { panel = PubStar.all.first { $0.id == id } }
        }
        .onChange(of: projectId) { _, _ in
            choice = .episode
            if Self.snapshotReel, let r = project?.reels.first { choice = .reel(r.id) }
            reset(); loadAccounts()
        }
        .onChange(of: session?.isBusy ?? false) { _, busy in
            guard !busy, phase == .sending, let s = session else { return }
            if s.reelPosts != nil { phase = .done; postsVersion += 1 }
            else { error = s.errorMessage ?? String(localized: "No se pudo publicar."); s.errorMessage = nil; phase = .choose }
        }
    }

    // MARK: Episodios

    private var episodesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EPISODIOS").font(.system(size: 12, weight: .bold)).kerning(1.4).foregroundStyle(Theme.secondary)
            if app.projects.isEmpty { Text("Todavía no hay episodios en postPod.").foregroundStyle(Theme.secondary) }
            ForEach(app.projects) { p in
                Button { select(p) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.system(size: 15, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(p.reels.count) \(p.reels.count == 1 ? "reel" : "reels") · \(EditEngine.clock(p.duration))")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(projectId == p.id ? Theme.panelStrong : Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(projectId == p.id ? Color.pubPod : Theme.stroke))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func select(_ p: Project) {
        if phase == .sending { return }
        if let s = app.session, s.project.id != p.id, s.isBusy {
            error = String(localized: "Espera a que termine «\(s.job?.title ?? "lo que se está haciendo")».")
            return
        }
        projectId = p.id
    }

    private func unlinked(_ p: Project) -> some View {
        Card {
            Label("Este episodio todavía no está vinculado a su podcast", systemImage: "link").font(.headline)
            Text("Vincúlalo una vez en postPod → Publicar.").foregroundStyle(Theme.secondary)
            Button("Ir a vincularlo") {
                if app.session?.project.id != p.id { app.open(p) }
                app.session?.step = .publish
                app.section = .post
            }
        }
    }

    // MARK: Las estrellas

    private func constellation(_ p: Project) -> some View {
        GeometryReader { g in
            let n = PubStar.all.count
            ZStack(alignment: .topLeading) {
                ForEach(Array(PubStar.all.enumerated()), id: \.element.id) { i, s in
                    // Arco de la bandera: separación pareja a lo ancho y las puntas más abajo
                    let u = Double(i) / Double(n - 1) * 2 - 1            // -1 … 1
                    let margin = 64.0
                    let x = margin + (g.size.width - 2 * margin) * (u + 1) / 2
                    let y = 40 + 120 * (1 - sqrt(max(0, 1 - u * u * 0.82)))
                    StarButton(star: s, online: online(s), eligible: eligible(s), on: isOn(s),
                               pulsing: phase == .sending && isOn(s), done: phase == .done && isOn(s),
                               toggle: { toggle(s) }, connect: { app.section = .pre },
                               open: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { panel = panel?.id == s.id ? nil : s } })
                        .position(x: x, y: y + 58 - 32)     // el centro de la estrella cae en (x, y)
                }
                VStack(spacing: 10) {
                    centerThumb(p)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(white: 0.22)))
                        .overlay(alignment: isEpisode ? .bottomTrailing : .bottom) {
                            Text(currentDuration(p)).font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.07, green: 0.07, blue: 0.09)))
                                .padding(8)
                        }
                        .frame(width: isEpisode ? 220 : 74, height: isEpisode ? 124 : 132)
                    Text(currentTitle(p)).font(.system(size: 16, weight: .bold)).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 320)
                }
                .position(x: g.size.width / 2, y: 210)
            }
        }
        .frame(height: 320)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.105)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(white: 0.16)))
    }

    @ViewBuilder
    private func centerThumb(_ p: Project) -> some View {
        switch choice {
        case .episode: PubThumb(project: p, size: CGSize(width: 220, height: 124), radius: 12)
        case .reel(let id): PubThumb(project: p, reel: p.reels.first { $0.id == id }, size: CGSize(width: 74, height: 132), radius: 12)
        case .file: RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.15)).frame(width: 220, height: 124)
        }
    }

    private func toggle(_ s: PubStar) {
        guard phase == .choose, online(s), eligible(s) else { return }
        // Spotify y Apple Podcasts salen del mismo feed: se encienden y se apagan juntas
        let group = PubStar.all.filter { $0.platform == s.platform && $0.forEpisode == s.forEpisode }.map(\.id)
        if picked.contains(s.id) { picked.subtract(group) } else { picked.formUnion(group) }
    }

    private func currentTitle(_ p: Project) -> String {
        switch choice {
        case .episode: return Exporter.episodeTitle(p)
        case .reel(let id): return p.reels.first { $0.id == id }?.title ?? "Reel"
        case .file(let u): return u.lastPathComponent
        }
    }
    private func currentDuration(_ p: Project) -> String {
        switch choice {
        case .episode: return EditEngine.clock(p.duration)
        case .reel(let id): return EditEngine.clock(p.reels.first { $0.id == id }?.length ?? 0)
        case .file: return "video"
        }
    }

    // MARK: Panel de una estrella

    private func starPanel(_ s: PubStar) -> some View {
        let acc = accounts[s.account]
        let mine = posts.filter { PubStar.of(platform: $0.platform, kind: $0.kind)?.id == s.id || ($0.platform == "feed" && s.platform == "feed") }
        let ownAccount = s.platform != "feed"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    StarShape().fill(online(s) ? Color.white : .clear)
                    if !online(s) { StarShape().stroke(Color(white: 0.4), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3])) }
                    PubGlyph(id: s.id).frame(width: 12, height: 12).foregroundStyle(online(s) ? Color(white: 0.07) : Color(white: 0.5)).offset(y: 2)
                }
                .frame(width: 30, height: 30)
                Text(s.name).font(.system(size: 20, weight: .heavy))
                Spacer()
                if let u = profileURL(s) { Link("Ver perfil ↗", destination: u).font(.system(size: 13, weight: .semibold)) }
                Button { withAnimation { panel = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                Circle().fill(Color(white: 0.17)).frame(width: 36, height: 36)
                    .overlay(Text(String((acc?.username ?? s.name).prefix(1)).uppercased()).font(.system(size: 14, weight: .heavy)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(online(s) ? (s.account == "instagram" ? "@\(acc?.username ?? "")" : (acc?.username ?? "Conectado")) : String(localized: "Sin conectar"))
                        .font(.system(size: 15, weight: .bold))
                    Text(accountNote(s)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if ownAccount {
                    Button(online(s) ? "Cambiar" : "Conectar") { app.section = .pre }.controlSize(.small)
                } else if !online(s) {
                    Button("Configurar") { app.section = .pre }.controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.07, green: 0.07, blue: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(white: 0.16)))
            if s.platform != "feed" || true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SIEMPRE AL FINAL").font(.system(size: 11, weight: .bold)).kerning(1.2).foregroundStyle(Theme.secondary)
                    TextEditor(text: Binding(get: { signatures[s.platform] ?? "" }, set: { signatures[s.platform] = $0 }))
                        .font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.07, green: 0.07, blue: 0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(white: 0.2)))
                    Text(s.platform == "feed" ? "Se agrega a las notas de cada episodio." : "Hashtags o firma que van en cada publicación de \(s.name).")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if !mine.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LO ÚLTIMO").font(.system(size: 11, weight: .bold)).kerning(1.2).foregroundStyle(Theme.secondary)
                    ForEach(mine.prefix(3)) { p in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                                Text(PubPostsList.when(p)).font(.system(size: 12)).foregroundStyle(p.status == "scheduled" ? Color(red: 0.957, green: 0.780, blue: 0.439) : Theme.secondary)
                            }
                            Spacer()
                            if let u = p.result_url.flatMap(URL.init), p.platform != "feed" { Link("Ver", destination: u).font(.caption) }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(isOn(s) ? "Quitar de esta publicación" : "Incluir en esta publicación") { toggle(s); withAnimation { panel = nil } }
                    .buttonStyle(.borderedProminent).disabled(!(online(s) && eligible(s)) || phase != .choose)
                    .foregroundStyle(.black)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 0.2)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .padding(.top, 60)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .onDisappear { saveSignatures() }
    }

    private func accountNote(_ s: PubStar) -> String {
        switch s.id {
        case "spotify", "apple": return String(localized: "Lee el feed del podcast")
        case "youtube": return String(localized: "Tu canal · también publica los Shorts")
        case "shorts": return String(localized: "Tu canal · también publica el episodio")
        case "instagram": return String(localized: "Cuenta profesional · también publica los Reels")
        case "reels": return String(localized: "Cuenta profesional · también publica la portada")
        case "tiktok": return String(localized: "Los reels llegan a tu bandeja")
        default: return ""
        }
    }

    private func profileURL(_ s: PubStar) -> URL? {
        guard let u = accounts[s.account]?.username, online(s) else { return nil }
        switch s.account {
        case "instagram": return URL(string: "https://www.instagram.com/\(u)/")
        case "tiktok": return URL(string: "https://www.tiktok.com/")
        case "youtube": return URL(string: "https://studio.youtube.com/")
        default: return nil
        }
    }

    private func saveSignatures() {
        guard let slug else { return }
        let sigs = signatures
        Task { try? await PrePodClient.shared.setPubSignatures(slug: slug, sigs) }
    }

    // MARK: Qué publicas

    private func chooser(_ p: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUÉ PUBLICAS").font(.system(size: 12, weight: .bold)).kerning(1.4).foregroundStyle(Theme.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    tile(.episode, String(localized: "Episodio completo"), "16:9 · \(EditEngine.clock(p.duration))", wide: true) {
                        PubThumb(project: p, size: CGSize(width: 180, height: 101))
                    }
                    ForEach(p.reels) { r in
                        tile(.reel(r.id), r.title.isEmpty ? "Reel" : r.title, String(localized: "Reel · \(EditEngine.clock(r.length))"), wide: false) {
                            PubThumb(project: p, reel: r, size: CGSize(width: 57, height: 101))
                        }
                    }
                    Button { chooseFile() } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                            Text({ if case .file(let u) = choice { return u.lastPathComponent }; return String(localized: "Desde la compu") }())
                                .font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .foregroundStyle({ if case .file = choice { return Color.white }; return Theme.secondary }())
                        .frame(width: 150, height: 172)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder({ if case .file = choice { return Color.pubPod }; return Color(white: 0.24) }(),
                                                                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    }
                    .buttonStyle(.plain)
                    .disabled(phase == .sending)
                }
            }
        }
    }

    private func tile<T: View>(_ c: Choice, _ name: String, _ meta: String, wide: Bool, @ViewBuilder thumb: () -> T) -> some View {
        Button { pick(c) } label: {
            VStack(alignment: .leading, spacing: 0) {
                thumb()
                Text(name).font(.system(size: 14, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading).padding(.top, 8)
                Text(meta).font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.top, 2)
            }
            .frame(width: wide ? 180 : 102, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(choice == c ? Theme.panelStrong : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(choice == c ? Color.pubPod : Theme.stroke))
        }
        .buttonStyle(.plain)
        .disabled(phase == .sending)
    }

    private func pick(_ c: Choice) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { choice = c }
        reset()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let u = panel.url else { return }
        pick(.file(u))
    }

    /// Vuelve a elegir: se encienden las estrellas conectadas que corresponden y los textos sugeridos.
    private func reset() {
        phase = .choose
        error = nil
        tab = nil
        picked = Set(PubStar.all.filter { online($0) && eligible($0) }.map(\.id))
        guard let p = project else { return }
        switch choice {
        case .episode:
            title = Exporter.episodeTitle(p)
            let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts)
            let notes = Exporter.notes(project: p, keep: keep, introDuration: p.intro.map { max(1, $0.seconds) } ?? 0)
            captions = ["feed": notes, "youtube": notes, "instagram_image": title]
        case .reel(let id):
            let r = p.reels.first { $0.id == id }
            title = r?.title ?? ""
            let text = (r?.hook?.isEmpty == false ? r?.hook : nil) ?? title
            captions = ["instagram": text, "youtube": text, "tiktok": text]
        case .file(let u):
            title = u.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            captions = [:]
        }
    }

    // MARK: Texto y momento

    private var composer: some View {
        let ts = targets
        let current = ts.first { $0.platform == tab } ?? ts.first
        let working = phase == .sending
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(ts) { s in
                    let label = s.platform == "feed" ? "Spotify y Apple Podcasts" : s.name
                    let sel = current?.platform == s.platform
                    Button { tab = s.platform } label: {
                        HStack(spacing: 6) {
                            StarShape().fill(sel ? Color(white: 0.07) : .white).frame(width: 12, height: 12)
                            Text(label).font(.system(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 14).frame(height: 36)
                        .foregroundStyle(sel ? Color(white: 0.07) : .white)
                        .background(Capsule().fill(sel ? Color.white : .clear))
                        .overlay(Capsule().strokeBorder(sel ? Color.white : Color(white: 0.26)))
                    }
                    .buttonStyle(.plain)
                }
                if ts.isEmpty { Text("Toca una estrella.").foregroundStyle(Theme.secondary) }
            }
            if let c = current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hint(c)).font(.caption).foregroundStyle(Theme.secondary)
                    TextEditor(text: Binding(get: { captions[c.platform] ?? "" }, set: { captions[c.platform] = $0 }))
                        .font(.system(size: 15))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: c.platform == "feed" || (c.platform == "youtube" && isEpisode) ? 130 : 80)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.07, green: 0.07, blue: 0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(white: 0.2)))
                        .disabled(working)
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $later) {
                    Text("Ahora").tag(false)
                    Text("Programar").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220).disabled(working || phase == .done)
                if later { DatePicker("", selection: $whenDate, in: Date()...).labelsHidden().disabled(working || phase == .done) }
                Spacer()
                if working, let s = session, let j = s.job {
                    Text(j.detail.isEmpty ? j.title : j.detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                } else if working {
                    Text(String(localized: "Subiendo \(Int(progress * 100)) %")).font(.caption).foregroundStyle(Theme.secondary)
                }
                mainButton(ts)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.105)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(white: 0.16)))
    }

    private func hint(_ s: PubStar) -> String {
        switch s.platform {
        case "feed": return String(localized: "Notas del episodio (Spotify y Apple Podcasts leen las mismas)")
        case "youtube": return isEpisode ? "Descripción" : String(localized: "Texto del Short")
        case "instagram_image": return String(localized: "Texto de la portada")
        case "tiktok": return String(localized: "Texto para pegar en TikTok (el video llega a tu bandeja)")
        default: return String(localized: "Texto, con tus hashtags")
        }
    }

    @ViewBuilder
    private func mainButton(_ ts: [PubStar]) -> some View {
        switch phase {
        case .done:
            Button("Publicar otra cosa") { reset() }
                .buttonStyle(.bordered).controlSize(.large)
        case .sending:
            Button(later ? "Programando…" : "Publicando…") {}
                .buttonStyle(.bordered).controlSize(.large).disabled(true)
        case .choose:
            Button(action: { send(ts) }) {
                Text(actionTitle).font(.system(size: 16, weight: .heavy)).foregroundStyle(Color(white: 0.07))
                    .padding(.horizontal, 22).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ts.isEmpty || title.isEmpty ? Color(white: 0.4) : .white))
            }
            .buttonStyle(.plain)
            .disabled(ts.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var actionTitle: String {
        if case .file = choice { return later ? String(localized: "Subir y programar") : String(localized: "Subir y publicar") }
        return later ? String(localized: "Exportar y programar") : String(localized: "Exportar y publicar")
    }

    private func send(_ ts: [PubStar]) {
        guard let p = project, let slug = p.episode.prepodSlug, !ts.isEmpty else { return }
        if later && whenDate < Date() { error = String(localized: "Esa fecha ya pasó."); return }
        let tg = ts.map { (platform: $0.platform, caption: captions[$0.platform] ?? "") }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        let at = later ? whenDate : nil
        error = nil
        switch choice {
        case .file(let url):
            phase = .sending
            progress = 0
            Task {
                do {
                    let upload = try await PrePodClient.shared.upload(file: url) { f in Task { @MainActor in progress = f } }
                    _ = try await PrePodClient.shared.createReelPosts(slug: slug, episodeId: p.episode.prepodEpisodeId,
                                                                      uploadId: upload, title: cleanTitle, targets: tg, at: at)
                    phase = .done
                    postsVersion += 1
                } catch { self.error = error.localizedDescription; phase = .choose }
            }
        case .episode, .reel:
            if app.session?.project.id != p.id { app.open(p) }
            guard let s = app.session else { return }
            if s.isBusy { error = String(localized: "Espera a que termine «\(s.job?.title ?? "lo que se está haciendo")»."); return }
            phase = .sending
            if case .reel(let id) = choice {
                guard var reel = s.project.reels.first(where: { $0.id == id }) else { phase = .choose; return }
                reel.title = cleanTitle
                s.publishReel(reel, targets: tg, at: at)
            } else {
                s.publishEpisode(title: cleanTitle, targets: tg, at: at)
            }
        }
    }

    private func loadAccounts() {
        guard PrePodClient.isConfigured, let slug else { return }
        Task {
            do {
                accounts = try await PrePodClient.shared.pubAccounts(slug: slug)
                if phase == .choose { picked = Set(PubStar.all.filter { online($0) && eligible($0) }.map(\.id)) }
                signatures = (try? await PrePodClient.shared.pubSignatures(slug: slug)) ?? [:]
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Publicaciones de un podcast

struct PubPostsList: View {
    let slug: String
    var onLoaded: (([PrePodClient.PubPost]) -> Void)? = nil
    @State private var posts: [PrePodClient.PubPost] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PUBLICACIONES").font(.system(size: 12, weight: .bold)).kerning(1.4).foregroundStyle(Theme.secondary)
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Actualizar")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if loaded && posts.isEmpty { Text("Todavía no hay publicaciones.").foregroundStyle(Theme.secondary) }
            ForEach(posts) { p in row(p).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.easeOut(duration: 0.4), value: posts.map(\.id))
        .task { await load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let soon = Date().addingTimeInterval(60)
                if posts.contains(where: { $0.status == "publishing" || ($0.status == "scheduled" && (date($0) ?? .distantFuture) <= soon) }) {
                    await load()
                }
            }
        }
    }

    private func row(_ p: PrePodClient.PubPost) -> some View {
        let star = PubStar.of(platform: p.platform, kind: p.kind)
        let filled = p.status == "published" || p.status == "inbox"
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                if filled { StarShape().fill(Color.white) } else {
                    StarShape().stroke(p.status == "error" ? Color.red : Color.white, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }
            .frame(width: 20, height: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                Text("\(p.platform == "feed" ? "Spotify y Apple Podcasts" : (star?.name ?? p.platform)) · \(when(p))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Text(statusText(p)).font(.system(size: 12, weight: .semibold)).foregroundStyle(statusColor(p))
                    if let s = p.result_url, let u = URL(string: s), p.platform != "feed" { Link("Ver", destination: u).font(.caption) }
                    if p.status == "scheduled" { Button("Cancelar") { act(p, "cancel") }.buttonStyle(.borderless).font(.caption) }
                    if p.status == "error" { Button("Reintentar") { act(p, "retry") }.buttonStyle(.borderless).font(.caption) }
                    if p.status == "inbox", let c = p.caption, !c.isEmpty {
                        Button("Copiar el texto") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c, forType: .string) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                if p.status == "private" {
                    Text("Ábrelo en YouTube y cámbialo a «Público».").font(.caption).foregroundStyle(Theme.secondary)
                }
                if let e = p.error, !e.isEmpty { Text(e).font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.105)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(white: 0.16)))
    }

    private func statusText(_ p: PrePodClient.PubPost) -> String {
        if p.status == "scheduled", let d = date(p), d <= Date() { return String(localized: "En cola") }
        return ["scheduled": "Programado", "publishing": "Publicando…", "published": "Publicado",
                "private": String(localized: "Subido en privado"), "inbox": String(localized: "En tu bandeja de TikTok"),
                "error": String(localized: "No se publicó"), "cancelled": "Cancelado"][p.status] ?? p.status
    }
    private func statusColor(_ p: PrePodClient.PubPost) -> Color {
        switch p.status {
        case "published", "inbox": return Theme.good
        case "error": return .red
        case "cancelled": return Theme.secondary
        default: return Color(red: 0.957, green: 0.780, blue: 0.439)
        }
    }
    private func date(_ p: PrePodClient.PubPost) -> Date? { Self.date(p) }
    private func when(_ p: PrePodClient.PubPost) -> String { Self.when(p) }
    static func date(_ p: PrePodClient.PubPost) -> Date? { p.scheduled_at.flatMap { ISO8601DateFormatter().date(from: $0) } }
    static func when(_ p: PrePodClient.PubPost) -> String { date(p)?.formatted(date: .abbreviated, time: .shortened) ?? "" }

    private func load() async {
        do { posts = try await PrePodClient.shared.pubPosts(slug: slug); error = nil; onLoaded?(posts) }
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
