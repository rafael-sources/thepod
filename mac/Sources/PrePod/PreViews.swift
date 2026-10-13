import SwiftUI
import UniformTypeIdentifiers

// MARK: - Estado de la sección pre

@MainActor
final class PreModel: ObservableObject {
    @Published var podcasts: [PrePodcast] = []
    @Published var slug: String = UserDefaults.standard.string(forKey: "prePodcast") ?? "" {
        didSet { UserDefaults.standard.set(slug, forKey: "prePodcast") }
    }
    @Published var episodes: [PreEpisode] = []
    @Published var loading = false
    @Published var error: String?
    @Published var open: PreEpisode?
    @Published var showArchived = false
    @Published var configuring = false
    @Published var logo: NSImage?

    var podcast: PrePodcast? { podcasts.first { $0.slug == slug } }
    /// Color del podcast (branding) o el azul de prePod.
    var accent: Color { Color.podcast(podcast?.colorPrimary) }

    /// El próximo episodio por grabar: el más cercano desde hoy; si no hay, el atrasado más reciente.
    var nextUp: PreEpisode? {
        let pending = episodes.filter { [.idea, .planning, .scripted].contains($0.statusValue) && $0.scheduled != nil }
        let today = Calendar.current.startOfDay(for: Date())
        if let n = pending.filter({ $0.scheduled! >= today }).min(by: { $0.scheduled! < $1.scheduled! }) { return n }
        return pending.max(by: { $0.scheduled! < $1.scheduled! })
    }

    func loadLogo() {
        let s = slug
        logo = nil
        guard !s.isEmpty else { return }
        Task {
            guard let cfg = try? await api.podcastConfig(s), let u = cfg.logoUrl, !u.isEmpty,
                  let d = try? await api.media(u), let img = NSImage(data: d), s == slug else { return }
            logo = img
        }
    }
    private let api = PrePodClient.shared

    func load() {
        guard PrePodClient.isConfigured else { error = "Conecta tu cuenta en Ajustes para ver tus podcasts."; return }
        loading = true
        Task {
            defer { loading = false }
            do {
                podcasts = try await api.prePodcasts()
                if podcast == nil { slug = podcasts.first?.slug ?? "" }
                try await loadEpisodes()
                loadLogo()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func loadEpisodes() async throws {
        guard !slug.isEmpty else { episodes = []; return }
        episodes = try await api.preEpisodes(slug)
    }

    func select(_ s: String) {
        slug = s
        open = nil
        loadLogo()
        Task { do { try await loadEpisodes() } catch { self.error = error.localizedDescription } }
    }

    /// templateId: nil = la plantilla por defecto del podcast; 0 = sin plantilla.
    func create(title: String, templateId: Int? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                let e = templateId == nil ? try await api.createEpisode(slug, title: t)
                                          : try await api.createEpisode(slug, title: t, templateId: templateId == 0 ? nil : templateId)
                episodes.append(e)
                open = e
            } catch { self.error = error.localizedDescription }
        }
    }

    func move(_ id: Int, to status: EpisodeStatus) {
        guard let i = episodes.firstIndex(where: { $0.id == id }), episodes[i].status != status.rawValue else { return }
        let before = episodes[i]
        episodes[i].status = status.rawValue                     // se ve al instante; si falla, se revierte
        Task {
            do {
                let e = try await api.updateEpisode(slug, id, ["status": status.rawValue])
                if let j = episodes.firstIndex(where: { $0.id == id }) { episodes[j] = e }
            } catch {
                if let j = episodes.firstIndex(where: { $0.id == id }) { episodes[j] = before }
                self.error = error.localizedDescription
            }
        }
    }

    func save(_ id: Int, _ fields: [String: Any]) async {
        do {
            let e = try await api.updateEpisode(slug, id, fields)
            if let i = episodes.firstIndex(where: { $0.id == id }) { episodes[i] = e }
            if open?.id == id { open = e }
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ id: Int) {
        Task {
            do {
                try await api.deleteEpisode(slug, id)
                episodes.removeAll { $0.id == id }
                if open?.id == id { open = nil }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Guarda con un pequeño retraso mientras se escribe (un pendiente por campo).
@MainActor
final class Debouncer {
    private var tasks: [String: Task<Void, Never>] = [:]
    func run(_ key: String, delay: Double = 0.8, _ work: @escaping @MainActor () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}

extension Color {
    static let prePod = Color(red: 0.353, green: 0.545, blue: 1.0)
    static let prodPod = Color(red: 1.0, green: 0.30, blue: 0.30)     // luz roja de "al aire"
}

// MARK: - Selector pre · post

struct SectionSwitcher: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 4) {
            chip(.pre, "pre", .prePod)
            chip(.prod, "prod", .prodPod)
            chip(.post, "post", Theme.accent)
            chip(.pub, "pub", .pubPod)
            chip(.ama, "ama", .amaPod)
        }
        .padding(3)
        .background(Capsule().fill(Theme.panel))
    }
    private func chip(_ s: AppSection, _ label: String, _ color: Color) -> some View {
        Button { app.section = s } label: {
            HStack(spacing: 5) {
                if s == .prod, app.studio?.phase == .inRoom {
                    Circle().fill(app.section == s ? Color.black : Color.prodPod).frame(width: 7, height: 7)
                }
                if s == .ama, app.ama?.phase == .live {
                    Circle().fill(app.section == s ? Color.black : Color.amaPod).frame(width: 7, height: 7)
                }
                Text(label)
            }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .foregroundStyle(app.section == s ? Color.black : color)
                .background(Capsule().fill(app.section == s ? color : .clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inicio de pre: tablero de episodios

struct PreHomeView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model: PreModel
    @State private var newTitle = ""
    @State private var creating = false
    @State private var templates: [ShowTemplate] = []
    @State private var templateId = -1          // -1 = la de por defecto, 0 = sin plantilla
    @AppStorage("preVistaCalendario") private var showCalendar = false
    @State private var dropTarget: EpisodeStatus?

    @MainActor init(model: PreModel? = nil) { _model = StateObject(wrappedValue: model ?? PreModel()) }

    var body: some View {
        Group {
            if let e = model.open {
                PreEpisodeView(model: model, episode: e)
                    .id(e.id)
            } else if model.configuring, !model.slug.isEmpty {
                PodcastSettingsView(slug: model.slug) {
                    model.configuring = false
                    model.load()
                }
                .id(model.slug)
            } else {
                board
            }
        }
        .tint(model.accent)
        .onAppear { if model.podcasts.isEmpty { model.load() } }
        .alert("Algo salió mal", isPresented: Binding(get: { model.error != nil && !model.podcasts.isEmpty },
                                                      set: { if !$0 { model.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                SectionSwitcher()
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).help("Actualizar")
                SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
            }

            if model.podcasts.isEmpty {
                Card {
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        SettingsLink { Text("Abrir Ajustes") }
                    } else {
                        ProgressView("Cargando tus podcasts…")
                    }
                }
            } else {
                podcastBanner
                if let next = model.nextUp {
                    NextUpCard(model: model, episode: next).id(next.id)
                }
                HStack(spacing: 12) {
                    Picker("", selection: $showCalendar) {
                        Label("Tablero", systemImage: "rectangle.split.3x1").tag(false)
                        Label("Calendario", systemImage: "calendar").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    Spacer()
                    if showCalendar {
                        Button {
                            Task {
                                do {
                                    if let url = try await PrePodClient.shared.saveDownload("/api/podcasts/\(model.slug)/calendar.ics",
                                                                                            suggestedName: "\(model.slug)-grabaciones.ics") {
                                        NSWorkspace.shared.open(url)      // lo abre Calendario y ofrece agregarlo
                                    }
                                } catch { model.error = error.localizedDescription }
                            }
                        } label: { Label("Agregar a mi calendario", systemImage: "calendar.badge.plus") }
                        .help("Baja las grabaciones como archivo de calendario y lo abre en Calendario")
                    }
                    if !showCalendar {
                        Toggle("Ver archivados", isOn: $model.showArchived).toggleStyle(.checkbox)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if showCalendar { ScrollView { PreCalendarView(model: model).padding(.bottom, 8) } } else { columns }
            }
        }
        .padding(28)
    }

    // Logo, nombre (menú para cambiar de podcast) y acciones principales
    private var podcastBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(model.accent.gradient)
                if let img = model.logo {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Text(String(model.podcast?.name.prefix(1) ?? "?"))
                        .font(.system(size: 30, weight: .black, design: .rounded)).foregroundStyle(.white)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Menu {
                    ForEach(model.podcasts) { p in
                        Button { model.select(p.slug) } label: {
                            if p.slug == model.slug { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.podcast?.name ?? "Elige un podcast").font(.system(size: 26, weight: .bold, design: .rounded))
                        if model.podcasts.count > 1 {
                            Image(systemName: "chevron.down").font(.callout.bold()).foregroundStyle(Theme.secondary)
                        }
                    }
                    .foregroundStyle(.white)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("Cambiar de podcast")
                Text(summary).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { model.configuring = true } label: { Label("Configurar podcast", systemImage: "slider.horizontal.3") }
                .buttonStyle(.bordered).controlSize(.large)
            Button { openCreate() } label: { Label("Nuevo episodio", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .popover(isPresented: $creating, arrowEdge: .bottom) { createPopover }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [model.accent.opacity(0.22), Theme.panel], startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(model.accent.opacity(0.35)))
    }

    private var summary: String {
        let active = model.episodes.filter { ![.published, .archived].contains($0.statusValue) }.count
        let published = model.episodes.filter { $0.statusValue == .published }.count
        var parts = ["\(active) en preparación", "\(published) publicados"]
        if let t = model.podcast?.tagline, !t.isEmpty, t.count <= 90 { parts.insert(t, at: 0) }
        return parts.joined(separator: " · ")
    }

    private var createPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nuevo episodio").font(.title3.bold())
            TextField("¿De qué va a tratar?", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(createNow)
            if !templates.isEmpty {
                Picker("Plantilla", selection: $templateId) {
                    ForEach(templates) { t in Text(t.name + (t.isDefault ? " (por defecto)" : "")).tag(t.id) }
                    Text("Sin plantilla").tag(0)
                }
                .frame(width: 320)
                Text("La plantilla trae el rundown y el guion base, para no empezar de cero.")
                    .font(.caption).foregroundStyle(Theme.secondary).frame(width: 320, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancelar") { creating = false }
                Button("Crear", action: createNow).buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
    }

    private func openCreate() {
        creating = true
        Task {
            templates = (try? await PrePodClient.shared.templates(model.slug)) ?? []
            templateId = templates.first(where: \.isDefault)?.id ?? 0
        }
    }

    private func createNow() {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.create(title: newTitle, templateId: templates.isEmpty ? nil : templateId)
        newTitle = ""
        creating = false
    }

    private var columns: some View {
        let statuses = EpisodeStatus.allCases.filter { model.showArchived || $0 != .archived }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(statuses) { st in column(st) }
            }
            .padding(.bottom, 6)
        }
    }

    private func column(_ st: EpisodeStatus) -> some View {
        let items = model.episodes.filter { $0.statusValue == st }
            .sorted { ($0.scheduled ?? .distantFuture, $0.id) < ($1.scheduled ?? .distantFuture, $1.id) }
        let targeted = dropTarget == st
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Image(systemName: st.symbol).foregroundStyle(st.color)
                    Text(st.title).font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(st.color.opacity(0.2)))
                        .foregroundStyle(st.color)
                }
                Text(st.hint).font(.caption).foregroundStyle(Theme.secondary)
            }
            ScrollView {
                VStack(spacing: 9) {
                    ForEach(items) { e in
                        EpisodeCardView(episode: e)
                            .onTapGesture { model.open = e }
                            .draggable(String(e.id))
                            .contextMenu {
                                Button("Abrir") { model.open = e }
                                Menu("Mover a") {
                                    ForEach(EpisodeStatus.allCases) { s in Button(s.title) { model.move(e.id, to: s) } }
                                }
                                Divider()
                                Button("Eliminar episodio", role: .destructive) { model.delete(e.id) }
                            }
                    }
                    if items.isEmpty {
                        Text("Arrastra un episodio aquí")
                            .font(.caption).foregroundStyle(Theme.secondary.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(12)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(targeted ? st.color.opacity(0.14) : Theme.panel)
        )
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14).fill(st.color).frame(height: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? st.color : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(Int.init) { model.move(id, to: st) }
            return true
        } isTargeted: { on in
            if on { dropTarget = st } else if dropTarget == st { dropTarget = nil }
        }
    }
}

struct EpisodeCardView: View {
    let episode: PreEpisode
    @State private var hover = false
    var body: some View {
        let st = episode.statusValue
        HStack(spacing: 0) {
            Rectangle().fill(st.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 7) {
                if let n = episode.episodeNumber {
                    Text("EP \(n)").font(.caption2.weight(.heavy)).foregroundStyle(st.color)
                }
                Text(episode.title).font(.callout.weight(.semibold)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let w = episode.whenText {
                    HStack(spacing: 6) {
                        Label(w, systemImage: "calendar").font(.caption).foregroundStyle(Theme.secondary)
                        if let r = episode.relativeWhen, st != .published, st != .archived {
                            Text(r).font(.caption2.bold())
                                .foregroundStyle(episode.isLate ? Color.red : st.color)
                        }
                    }
                }
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Color(white: 1, opacity: 0.14) : Theme.panelStrong))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(episode.isLate ? Color.red.opacity(0.5) : Theme.stroke))
        .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 8, y: 3)
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .help(episode.isLate ? "La fecha de grabación ya pasó" : "Abrir")
    }
}

/// El próximo episodio a grabar, con lo que ya está listo y lo que falta.
struct NextUpCard: View {
    @ObservedObject var model: PreModel
    let episode: PreEpisode
    @State private var sections: Int?
    @State private var blocks: Int?
    @State private var minutes = 0
    @State private var guests: [PreGuest] = []

    var body: some View {
        let st = episode.statusValue
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Chip(text: episode.isLate ? "Atrasado" : "Próxima grabación",
                         symbol: episode.isLate ? "exclamationmark.triangle.fill" : "mic.fill",
                         color: episode.isLate ? .red : model.accent, filled: true)
                    if let r = episode.relativeWhen { Text(r.capitalizedFirst).font(.headline).foregroundStyle(episode.isLate ? .red : .white) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let n = episode.episodeNumber {
                        Text("EP \(n)").font(.title3.weight(.heavy)).foregroundStyle(model.accent)
                    }
                    Text(episode.title).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let w = episode.whenText { Label(w, systemImage: "calendar").foregroundStyle(Theme.secondary) }
                    Chip(text: st.title, symbol: st.symbol, color: st.color)
                }
                .font(.callout)
            }
            Spacer()
            HStack(spacing: 10) {
                check("Guion", sections.map { $0 == 0 ? "vacío" : plural($0, "sección", "secciones") }, ok: (sections ?? 0) > 0, symbol: "text.page")
                check("Rundown", blocks.map { $0 == 0 ? "vacío" : plural($0, "bloque", "bloques") + (minutes > 0 ? " · \(minutes) min" : "") }, ok: (blocks ?? 0) > 0, symbol: "list.bullet.rectangle")
                check("Invitados", guestsText, ok: !guests.isEmpty && confirmed == guests.count, symbol: "person.2")
            }
            Button { model.open = episode } label: {
                Label("Abrir", systemImage: "arrow.right").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(episode.isLate ? Color.red.opacity(0.5) : model.accent.opacity(0.5), lineWidth: 1.2))
        .task { await load() }
    }

    private var confirmed: Int { guests.filter { $0.rsvpStatus == "yes" }.count }
    private var guestsText: String? {
        guests.isEmpty ? (sections == nil ? nil : "nadie aún") : "\(confirmed) de \(guests.count) confirmados"
    }

    private func check(_ title: String, _ detail: String?, ok: Bool, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: detail == nil ? symbol : (ok ? "checkmark.circle.fill" : "circle.dashed"))
                    .foregroundStyle(detail == nil ? Theme.secondary : (ok ? Theme.good : .orange))
                Text(title).font(.callout.weight(.semibold))
            }
            Text(detail ?? "…").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(width: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelStrong))
    }

    private func load() async {
        let api = PrePodClient.shared
        async let s = try? api.script(model.slug, episode.id)
        async let b = try? api.blocks(model.slug, episode.id)
        async let g = try? api.guests(model.slug, episode.id)
        let (ss, bb, gg) = await (s, b, g)
        sections = ss?.count ?? 0
        blocks = bb?.count ?? 0
        minutes = Int((bb ?? []).compactMap(\.durationEstimate).reduce(0, +).rounded())
        guests = gg ?? []
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Episodio

struct PreEpisodeView: View {
    @ObservedObject var model: PreModel
    @State var episode: PreEpisode
    @AppStorage("prePestana") private var tab = 0
    @State private var date = Date()
    @State private var hasDate = false
    @State private var saver = Debouncer()
    @State private var counts: [Int: String] = [:]
    @State private var sending = false
    @EnvironmentObject private var app: AppModel
    @State private var done: Set<Int> = []

    private struct Page { let title: String; let symbol: String; let help: String }
    private let pages = [
        Page(title: "Guion", symbol: "text.page", help: "Lo que se va a decir, por partes. Escribe libre: se guarda solo."),
        Page(title: "Rundown", symbol: "list.bullet.rectangle", help: "El orden del episodio, bloque por bloque, con sus minutos."),
        Page(title: "Invitados", symbol: "person.2", help: "Quién participa. Invítalos y mándales el correo de preparación."),
        Page(title: "Ideas", symbol: "lightbulb", help: "Temas y preguntas propuestos por el equipo. Vota las mejores."),
        Page(title: "Publicación", symbol: "paperplane", help: "Descripción, notas y links que salen al publicar."),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(Color.black.opacity(0.25))
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                header
                PreHeader(symbol: pages[tab].symbol, title: pages[tab].title, subtitle: pages[tab].help, color: model.accent)
                Group {
                    switch tab {
                    case 0: ScriptTab(slug: model.slug, episodeId: episode.id)
                    case 1: RundownTab(slug: model.slug, episodeId: episode.id)
                    case 2: GuestsTab(slug: model.slug, episodeId: episode.id)
                    case 3: IdeasTab(slug: model.slug, episodeId: episode.id)
                    default: PublicationTab(model: model, episode: $episode, saver: saver)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { loadDate(); if !(0..<pages.count).contains(tab) { tab = 0 } }
        .onChange(of: model.open) { _, o in
            // Al guardar, prePod devuelve el episodio: tomar su fecha y estado sin tocar lo que se está escribiendo
            guard let o, o.id == episode.id else { return }
            episode.scheduledAt = o.scheduledAt
            episode.scheduledDate = o.scheduledDate
            episode.status = o.status
        }
        .task(id: tab) { await loadCounts() }
    }

    private var sidebar: some View {
        let st = episode.statusValue
        return VStack(alignment: .leading, spacing: 6) {
            Button { model.open = nil } label: { Label("Episodios", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                .padding(.top, 28).padding(.bottom, 14)
            HStack(spacing: 8) {
                if let n = episode.episodeNumber { Text("EP \(n)").font(.headline.weight(.heavy)).foregroundStyle(model.accent) }
                Chip(text: st.title, symbol: st.symbol, color: st.color)
            }
            Text(episode.title.isEmpty ? "Sin título" : episode.title).font(.headline).lineLimit(3)
            if let w = episode.whenText {
                HStack(spacing: 6) {
                    Label(w, systemImage: "calendar")
                    if let r = episode.relativeWhen { Text("· " + r).foregroundStyle(episode.isLate ? .red : Theme.secondary) }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer().frame(height: 14)
            ForEach(pages.indices, id: \.self) { i in
                Button { tab = i } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(tab == i ? model.accent : Theme.panelStrong).frame(width: 28, height: 28)
                            if done.contains(i) && tab != i {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.good)
                            } else {
                                Image(systemName: pages[i].symbol).font(.caption.bold())
                                    .foregroundStyle(tab == i ? .black : .white)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pages[i].title).font(.body.weight(tab == i ? .semibold : .regular))
                            if let c = counts[i] { Text(c).font(.caption2).foregroundStyle(Theme.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(tab == i ? Theme.panelStrong : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Título del episodio", text: $episode.title)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .onChange(of: episode.title) { _, v in saver.run("title") { await model.save(episode.id, ["title": v]) } }
            HStack(spacing: 12) {
                Menu {
                    ForEach(EpisodeStatus.allCases) { s in
                        Button { setStatus(s) } label: { Label(s.title, systemImage: s.symbol) }
                    }
                } label: {
                    Chip(text: episode.statusValue.title, symbol: episode.statusValue.symbol, color: episode.statusValue.color, filled: true)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .help("Cambiar el estado")
                Divider().frame(height: 18)
                Image(systemName: "calendar").foregroundStyle(Theme.secondary)
                if hasDate {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        .onChange(of: date) { _, d in saveDate(d) }
                    Button { hasDate = false; saveDate(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Quitar la fecha")
                } else {
                    Button("Poner fecha de grabación") { hasDate = true; saveDate(date) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button { goRecord() } label: {
                    Label(sending ? "Preparando la sala…" : "Ir a grabar", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent).tint(.prodPod).controlSize(.large)
                .disabled(sending)
                .help("Abre la sala de grabación de este episodio en prod")
            }
        }
    }

    /// Crea (o encuentra) la sala de prodPod del episodio y la abre en prod.
    private func goRecord() {
        sending = true
        Task {
            defer { sending = false }
            do {
                let sid = try await PrePodClient.shared.sendToProdPod(slug: model.slug, episodeId: episode.id)
                app.prodRequest = sid
                app.section = .prod
            } catch { model.error = error.localizedDescription }
        }
    }

    private func setStatus(_ s: EpisodeStatus) {
        episode.status = s.rawValue
        Task { await model.save(episode.id, ["status": s.rawValue]) }
    }

    /// Resumen corto debajo de cada pestaña del lado izquierdo.
    private func loadCounts() async {
        let api = PrePodClient.shared
        async let s = try? api.script(model.slug, episode.id)
        async let b = try? api.blocks(model.slug, episode.id)
        async let g = try? api.guests(model.slug, episode.id)
        let (ss, bb, gg) = await (s, b, g)
        var c: [Int: String] = [:]
        var d: Set<Int> = []
        if let ss { c[0] = ss.isEmpty ? "Vacío" : plural(ss.count, "sección", "secciones"); if ss.contains(where: { !$0.content.isEmpty }) { d.insert(0) } }
        if let bb {
            let m = Int(bb.compactMap(\.durationEstimate).reduce(0, +).rounded())
            c[1] = bb.isEmpty ? "Vacío" : plural(bb.count, "bloque", "bloques") + (m > 0 ? " · \(m) min" : "")
            if !bb.isEmpty { d.insert(1) }
        }
        if let gg {
            let ok = gg.filter { $0.rsvpStatus == "yes" }.count
            c[2] = gg.isEmpty ? "Nadie todavía" : "\(ok) de \(gg.count) confirmados"
            if !gg.isEmpty && ok == gg.count { d.insert(2) }
        }
        if !(episode.description ?? "").isEmpty { d.insert(4) }
        counts = c
        done = d
    }

    private static let isoLocal: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f
    }()

    private func loadDate() {
        if let raw = episode.scheduledAt, let d = Self.isoLocal.date(from: String(raw.prefix(16))) { date = d; hasDate = true }
        else if let raw = episode.scheduledDate, raw.count >= 10 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(raw.prefix(10))) { date = d; hasDate = true }
        }
    }

    private func saveDate(_ d: Date?) {
        let at: Any = d.map { Self.isoLocal.string(from: $0) } ?? NSNull()
        let day: Any = d.map { String(Self.isoLocal.string(from: $0).prefix(10)) } ?? NSNull()
        saver.run("date") { await model.save(episode.id, ["scheduled_at": at, "scheduled_date": day]) }
    }
}

struct DescriptionTab: View {
    @ObservedObject var model: PreModel
    @Binding var episode: PreEpisode
    let saver: Debouncer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("De qué trata el episodio (sale en la descripción al publicar).").font(.caption).foregroundStyle(Theme.secondary)
            TextEditor(text: Binding(get: { episode.description ?? "" }, set: { episode.description = $0 }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                .frame(minHeight: 180)
                .onChange(of: episode.description) { _, v in saver.run("desc") { await model.save(episode.id, ["description": v ?? ""]) } }
            if let s = episode.aiSummary, !s.isEmpty {
                Text("Resumen de postPod").font(.headline).padding(.top, 8)
                Text(s).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Guion

struct ScriptTab: View {
    let slug: String
    let episodeId: Int
    @State private var sections: [ScriptSection] = []
    @State private var error: String?
    @State private var saver = Debouncer()
    private let api = PrePodClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plural(sections.count, "sección", "secciones") + (totalMinutes > 0 ? " · ~\(totalMinutes) min" : "")).font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button { add() } label: { Label("Agregar sección", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($sections) { $s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(s.position + 1)").font(.caption.bold().monospacedDigit())
                                    .foregroundStyle(Theme.secondary).frame(width: 18)
                                if !s.speaker.isEmpty { Avatar(name: s.speaker, size: 24) }
                                TextField("Quién habla", text: $s.speaker).frame(maxWidth: 220)
                                    .onChange(of: s.speaker) { _, v in save(s.id, ["speaker": v]) }
                                TextField("dura", value: Binding(get: { s.estimatedDuration.map { $0 / 60 } },
                                                                set: { s.estimatedDuration = $0.map { $0 * 60 } }), format: .number)
                                    .frame(width: 50)
                                    .onChange(of: s.estimatedDuration) { _, v in save(s.id, ["estimated_duration": v ?? NSNull()]) }
                                Text("min").font(.caption).foregroundStyle(Theme.secondary)
                                    .help("Cuánto dura esta sección (no es el teleprompter)")
                                Spacer()
                                Button { move(s, -1) } label: { Image(systemName: "arrow.up") }.disabled(s.position == 0)
                                Button { move(s, 1) } label: { Image(systemName: "arrow.down") }.disabled(s.position >= sections.count - 1)
                                Button(role: .destructive) { remove(s) } label: { Image(systemName: "trash") }
                            }
                            .buttonStyle(.borderless)
                            TextEditor(text: $s.content)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .frame(maxWidth: .infinity, minHeight: 70)
                                .onChange(of: s.content) { _, v in save(s.id, ["content": v]) }
                            teleprompterRow($s)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
                    }
                    if sections.isEmpty {
                        EmptyHint(symbol: "text.page", title: "El guion está vacío",
                                  text: "Toca “Agregar sección” y escribe qué se dice en cada parte. No hace falta que sea perfecto.")
                    }
                }
            }
        }
        .task { await load() }
    }

    private var totalMinutes: Int { Int((sections.compactMap(\.estimatedDuration).reduce(0, +) / 60).rounded()) }

    // MARK: Teleprompter

    /// Quién puede leer un teleprompter: conductores del podcast (por usuario) e invitados del episodio (por nombre).
    struct TPPerson: Identifiable, Hashable { let key: String; let label: String; let isHost: Bool; var id: String { key } }
    @State private var tpPeople: [TPPerson] = []

    @ViewBuilder private func teleprompterRow(_ s: Binding<ScriptSection>) -> some View {
        let on = s.wrappedValue.tpEnabled ?? false
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { on }, set: { v in toggleTP(s, v) })) {
                Label("Teleprompter", systemImage: "text.viewfinder").font(.callout)
            }
            .toggleStyle(.switch).controlSize(.small)
            if on {
                HStack(spacing: 10) {
                    Text("lo lee").font(.caption).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { s.wrappedValue.tpSpeaker ?? "" },
                                                  set: { v in s.wrappedValue.tpSpeaker = v; save(s.wrappedValue.id, ["tp_speaker": v]) })) {
                        Text("— elegir —").tag("")
                        if tpPeople.contains(where: \.isHost) {
                            Section("Conductores") { ForEach(tpPeople.filter(\.isHost)) { p in Text(p.label).tag(p.key) } }
                        }
                        if tpPeople.contains(where: { !$0.isHost }) {
                            Section("Invitados") { ForEach(tpPeople.filter { !$0.isHost }) { p in Text(p.label).tag(p.key) } }
                        }
                    }
                    .labelsHidden().frame(maxWidth: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder((s.wrappedValue.tpSpeaker ?? "").isEmpty ? Color.orange : .clear))
                }
                HStack(spacing: 10) {
                    let chained = (s.wrappedValue.tpAfterPrev ?? false) && tpHasPrev(s.wrappedValue)
                    if tpHasPrev(s.wrappedValue) {
                        Toggle("después del anterior", isOn: Binding(get: { s.wrappedValue.tpAfterPrev ?? false },
                                                                    set: { v in s.wrappedValue.tpAfterPrev = v; save(s.wrappedValue.id, ["tp_after_prev": v]) }))
                            .toggleStyle(.checkbox).controlSize(.small)
                    }
                    if chained {
                        Text("separación").font(.caption).foregroundStyle(Theme.secondary)
                        TextField("seg", value: Binding(get: { s.wrappedValue.tpGapSeconds ?? 0.5 },
                                                        set: { g in s.wrappedValue.tpGapSeconds = max(0, g); save(s.wrappedValue.id, ["tp_gap_seconds": max(0, g)]) }),
                                  format: .number)
                            .frame(width: 44)
                        Text("seg → empieza en \(clockTP(tpStart(s.wrappedValue)))").font(.caption).foregroundStyle(Theme.secondary)
                    } else {
                        Text("aparece a los").font(.caption).foregroundStyle(Theme.secondary)
                        let secs = s.wrappedValue.tpOffsetSeconds ?? 0
                        TextField("min", value: Binding(get: { Int(secs) / 60 },
                                                        set: { m in setTPOffset(s, min: max(0, m), sec: Int(secs) % 60) }), format: .number)
                            .frame(width: 44)
                        Text("min").font(.caption).foregroundStyle(Theme.secondary)
                        TextField("seg", value: Binding(get: { Int(secs) % 60 },
                                                        set: { x in setTPOffset(s, min: Int(secs) / 60, sec: min(59, max(0, x))) }), format: .number)
                            .frame(width: 44)
                        Text("seg").font(.caption).foregroundStyle(Theme.secondary)
                        Button("sugerir") { setTPOffset(s, total: tpSuggested(for: s.wrappedValue)) }
                            .buttonStyle(.borderless).font(.caption)
                            .help("Sumar lo que duran las secciones anteriores")
                    }
                    Text("corre ~\(Int(tpRunSeconds(s.wrappedValue).rounded())) s").font(.caption).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 10) {
                    Text("velocidad").font(.caption).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { s.wrappedValue.tpSpeed ?? "normal" },
                                                  set: { v in s.wrappedValue.tpSpeed = v; save(s.wrappedValue.id, ["tp_speed": v]) })) {
                        Text("lenta").tag("slow"); Text("normal").tag("normal"); Text("rápida").tag("fast")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                    Text("ocupa").font(.caption).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { s.wrappedValue.tpSize ?? "half" },
                                                  set: { v in s.wrappedValue.tpSize = v; save(s.wrappedValue.id, ["tp_size": v]) })) {
                        Text("¼ pantalla").tag("quarter"); Text("½ pantalla").tag("half"); Text("toda").tag("full")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                }
                Text("Todos ven el aviso 3 s antes; el texto le sale solo a quien lo lee. Si no eliges a nadie, le sale a todos.")
                    .font(.caption2).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.top, 4)
    }

    /// Cuánto tarda en correr (misma fórmula que prodPod): palabras / velocidad + 2,5 s.
    private func tpRunSeconds(_ sec: ScriptSection) -> Double {
        let wpm: [String: Double] = ["slow": 95, "normal": 135, "fast": 180]
        let words = max(8, sec.content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
        return Double(words) / (wpm[sec.tpSpeed ?? "normal"] ?? 135) * 60 + 2.5
    }
    private func tpHasPrev(_ sec: ScriptSection) -> Bool {
        for x in sections { if x.id == sec.id { return false }; if x.tpEnabled ?? false { return true } }
        return false
    }
    /// Inicio real, resolviendo los encadenados en orden (igual que el endpoint de prePod).
    private func tpStart(_ sec: ScriptSection) -> Double? {
        var prevEnd: Double? = nil
        for x in sections where x.tpEnabled ?? false {
            var off = x.tpOffsetSeconds
            if (x.tpAfterPrev ?? false), let pe = prevEnd { off = pe + (x.tpGapSeconds ?? 0.5) }
            if x.id == sec.id { return off }
            if let o = off { prevEnd = o + tpRunSeconds(x) }
        }
        return sec.tpOffsetSeconds
    }
    private func clockTP(_ t: Double?) -> String {
        guard let t else { return "—" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t.rounded()) % 60)
    }
    private func tpSuggested(for sec: ScriptSection) -> Int {
        var acc = 0.0
        for x in sections { if x.id == sec.id { break }; acc += x.estimatedDuration ?? 0 }
        return Int(acc)
    }
    private func toggleTP(_ s: Binding<ScriptSection>, _ v: Bool) {
        s.wrappedValue.tpEnabled = v
        var fields: [String: Any] = ["tp_enabled": v]
        if v && s.wrappedValue.tpOffsetSeconds == nil {
            let t = tpSuggested(for: s.wrappedValue)
            s.wrappedValue.tpOffsetSeconds = Double(t); fields["tp_offset_seconds"] = t
        }
        if v && (s.wrappedValue.tpSpeaker ?? "").isEmpty {
            let sp = s.wrappedValue.speaker.trimmingCharacters(in: .whitespaces).lowercased()
            let hit = tpPeople.first { $0.key.lowercased() == sp || $0.label.lowercased().hasPrefix(sp) && !sp.isEmpty } ?? tpPeople.first
            if let hit { s.wrappedValue.tpSpeaker = hit.key; fields["tp_speaker"] = hit.key }
        }
        save(s.wrappedValue.id, fields)
    }
    private func setTPOffset(_ s: Binding<ScriptSection>, min: Int, sec: Int) { setTPOffset(s, total: min * 60 + sec) }
    private func setTPOffset(_ s: Binding<ScriptSection>, total: Int) {
        s.wrappedValue.tpOffsetSeconds = Double(total)
        save(s.wrappedValue.id, ["tp_offset_seconds": total])
    }
    private func loadTPPeople() async {
        var out: [TPPerson] = []
        if let h = try? await api.hosts(slug) {
            for u in ([h.owner].compactMap { $0 } + h.extraHosts) {
                let found = (try? await api.searchUsers(u))?.first { $0.username == u }
                out.append(TPPerson(key: u, label: found?.displayName.map { "\($0) (@\(u))" } ?? "@\(u)", isHost: true))
            }
        }
        if let gs = try? await api.guests(slug, episodeId) {
            for g in gs where !g.name.isEmpty { out.append(TPPerson(key: g.name, label: g.name, isHost: false)) }
        }
        tpPeople = out
    }

    private func load() async {
        do { sections = try await api.script(slug, episodeId) } catch { self.error = error.localizedDescription }
        await loadTPPeople()
    }
    private func save(_ id: Int, _ fields: [String: Any]) {
        saver.run("\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateSection(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func add() {
        Task {
            do { sections.append(try await api.addSection(slug, episodeId)) } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ s: ScriptSection) {
        Task {
            do { try await api.deleteSection(slug, s.id); await load() } catch { self.error = error.localizedDescription }
        }
    }
    private func move(_ s: ScriptSection, _ delta: Int) {
        Task {
            do { try await api.updateSection(slug, s.id, ["position": s.position + delta]); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Rundown

struct RundownTab: View {
    let slug: String
    let episodeId: Int
    @State private var blocks: [RundownBlock] = []
    @State private var sponsors: [Sponsor2] = []
    @State private var error: String?
    @State private var saver = Debouncer()
    private let api = PrePodClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plural(blocks.count, "bloque", "bloques") + (totalMinutes > 0 ? " · ~\(totalMinutes) min" : "")).font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    ForEach(BlockKind.allCases) { k in Button { add(k) } label: { Label(k.title, systemImage: k.symbol) } }
                } label: { Label("Agregar bloque", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(.borderedProminent)
                .fixedSize()
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            if totalMinutes > 0 { proportionBar }
            if blocks.isEmpty {
                EmptyHint(symbol: "list.bullet.rectangle", title: "El rundown está vacío",
                          text: "Toca “Agregar bloque” y arma el orden: intro, segmentos, entrevista, sponsor, cierre.")
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array($blocks.enumerated()), id: \.element.id) { i, $b in
                        let kind = BlockKind(rawValue: b.kind) ?? .custom
                        HStack(spacing: 10) {
                            Text(clock(start(of: i))).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 44)
                            ZStack {
                                Circle().fill(kind.color.opacity(0.22))
                                Image(systemName: kind.symbol).font(.caption.bold()).foregroundStyle(kind.color)
                            }
                            .frame(width: 28, height: 28)
                            Picker("", selection: Binding(get: { kind }, set: { k in
                                b.kind = k.rawValue; save(b.id, ["kind": k.rawValue])
                            })) { ForEach(BlockKind.allCases) { Text($0.title).tag($0) } }
                                .labelsHidden().frame(width: 120)
                            TextField("Título", text: $b.title)
                                .onChange(of: b.title) { _, v in save(b.id, ["title": v]) }
                            TextField("min", value: $b.durationEstimate, format: .number)   // en prePod los bloques van en minutos
                                .frame(width: 50)
                                .onChange(of: b.durationEstimate) { _, v in save(b.id, ["duration_estimate": v ?? NSNull()]) }
                            Text("min").font(.caption).foregroundStyle(Theme.secondary)
                            if b.kind == "sponsor" {
                                Picker("", selection: Binding(get: { b.sponsorId ?? 0 }, set: { v in
                                    b.sponsorId = v == 0 ? nil : v
                                    Task { do { try await api.setBlockSponsor(slug, b.id, sponsorId: v == 0 ? nil : v) } catch { self.error = error.localizedDescription } }
                                })) {
                                    Text("¿Qué sponsor?").tag(0)
                                    ForEach(sponsors) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden().frame(width: 160)
                            }
                            Button { reorder(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                            Button { reorder(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == blocks.count - 1)
                            Button(role: .destructive) { remove(b) } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                        .overlay(alignment: .leading) {
                            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(kind.color).frame(width: 4)
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var totalMinutes: Int { Int(blocks.compactMap(\.durationEstimate).reduce(0, +).rounded()) }

    /// El episodio de un vistazo: cada bloque ocupa lo que dura.
    private var proportionBar: some View {
        let total = max(1, blocks.compactMap(\.durationEstimate).reduce(0, +))
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(blocks) { b in
                        let k = BlockKind(rawValue: b.kind) ?? .custom
                        let w = max(4, geo.size.width * (b.durationEstimate ?? 0) / total - 2)
                        RoundedRectangle(cornerRadius: 4).fill(k.color.gradient)
                            .frame(width: (b.durationEstimate ?? 0) > 0 ? w : 0)
                            .overlay {
                                if w > 60 { Text(b.title).font(.caption2.bold()).foregroundStyle(.black.opacity(0.75)).lineLimit(1).padding(.horizontal, 4) }
                            }
                            .help("\(b.title) · \(Int(b.durationEstimate ?? 0)) min")
                    }
                }
            }
            .frame(height: 26)
            HStack {
                Text("0:00"); Spacer(); Text("\(totalMinutes) min")
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
    private func start(of i: Int) -> Double { blocks.prefix(i).compactMap(\.durationEstimate).reduce(0, +) * 60 }
    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func load() async {
        do {
            blocks = try await api.blocks(slug, episodeId)
            sponsors = (try? await api.sponsors(slug)) ?? []
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ id: Int, _ fields: [String: Any]) {
        saver.run("\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateBlock(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func add(_ k: BlockKind) {
        Task {
            do { blocks.append(try await api.addBlock(slug, episodeId, kind: k, title: k.title)) } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ b: RundownBlock) {
        Task {
            do { try await api.deleteBlock(slug, b.id); blocks.removeAll { $0.id == b.id } } catch { self.error = error.localizedDescription }
        }
    }
    private func reorder(_ i: Int, _ delta: Int) {
        var ids = blocks.map(\.id)
        ids.swapAt(i, i + delta)
        Task {
            do { blocks = try await api.reorderBlocks(slug, episodeId, order: ids) } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Invitados

struct GuestsTab: View {
    let slug: String
    let episodeId: Int
    @State private var guests: [PreGuest] = []
    @State private var error: String?
    @State private var note: String?
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var newRole = "guest"
    @State private var saver = Debouncer()
    private let api = PrePodClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                if !guests.isEmpty {
                    let ok = guests.filter { $0.rsvpStatus == "yes" }.count
                    Chip(text: "\(ok) de \(guests.count) confirmados", symbol: "checkmark.circle.fill",
                         color: ok == guests.count ? Theme.good : .orange)
                }
                if let note { Text(note).foregroundStyle(Theme.secondary).font(.caption) }
                Spacer()
                Button { sendPrep() } label: { Label("Enviar correo de preparación", systemImage: "envelope") }
                    .help("Fecha, rundown, link a la sala y recomendaciones, a todos los que tienen correo")
                    .disabled(!guests.contains { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($guests) { $g in
                        HStack(spacing: 10) {
                            Avatar(name: g.name, size: 34)
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: RSVP.symbol(g.rsvpStatus)).font(.system(size: 12))
                                        .foregroundStyle(RSVP.color(g.rsvpStatus))
                                        .background(Circle().fill(Theme.background).padding(-1))
                                }
                            TextField("Nombre", text: $g.name).frame(width: 180)
                                .onChange(of: g.name) { _, v in save(g.id, ["name": v]) }
                            Picker("", selection: $g.role) {
                                Text("Conductor").tag("host"); Text("Co-conductor").tag("co-host"); Text("Invitado").tag("guest")
                            }
                            .labelsHidden().frame(width: 130)
                            .onChange(of: g.role) { _, v in save(g.id, ["role": v]) }
                            TextField("Correo", text: $g.email).frame(width: 200)
                                .onChange(of: g.email) { _, v in save(g.id, ["email": v]) }
                            Picker("", selection: $g.rsvpStatus) {
                                Text("Sin responder").tag("pending"); Text("Confirmado").tag("yes")
                                Text("Tal vez").tag("maybe"); Text("No viene").tag("no")
                            }
                            .labelsHidden().frame(width: 130)
                            .tint(RSVP.color(g.rsvpStatus))
                            .onChange(of: g.rsvpStatus) { _, v in save(g.id, ["rsvp_status": v]) }
                            Button("Invitar") { invite(g) }
                                .disabled(g.email.trimmingCharacters(in: .whitespaces).isEmpty)
                                .help("Envía la invitación con el link para confirmar")
                            Spacer()
                            Button(role: .destructive) { remove(g) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }
                    if guests.isEmpty {
                        EmptyHint(symbol: "person.2", title: "Todavía no hay nadie",
                                  text: "Agrega a los conductores e invitados abajo. Con su correo puedes invitarlos y mandarles la preparación.")
                    }
                }
            }
            Card {
                Label("Agregar a alguien", systemImage: "person.badge.plus").font(.headline)
                HStack {
                    TextField("Nombre", text: $newName).frame(width: 180)
                    Picker("", selection: $newRole) {
                        Text("Invitado").tag("guest"); Text("Co-conductor").tag("co-host"); Text("Conductor").tag("host")
                    }
                    .labelsHidden().frame(width: 130)
                    TextField("Correo (opcional)", text: $newEmail).frame(width: 220)
                    Button("Agregar", action: add).buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { guests = try await api.guests(slug, episodeId) } catch { self.error = error.localizedDescription }
    }
    private func save(_ id: Int, _ fields: [String: Any]) {
        saver.run("\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateGuest(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func add() {
        let name = newName, email = newEmail, role = newRole
        newName = ""; newEmail = ""
        Task {
            do { guests.append(try await api.addGuest(slug, episodeId, name: name, email: email, role: role)) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ g: PreGuest) {
        Task {
            do { try await api.deleteGuest(slug, g.id); guests.removeAll { $0.id == g.id } } catch { self.error = error.localizedDescription }
        }
    }
    private func sendPrep() {
        Task {
            do {
                let (sent, total, extra) = try await api.sendPreRecording(slug, episodeId)
                note = "Correo de preparación: \(sent) de \(total) enviados. \(extra)"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func invite(_ g: PreGuest) {
        Task {
            do { let (_, msg) = try await api.sendRSVP(slug, g.id); note = "\(g.name): \(msg)" }
            catch { self.error = error.localizedDescription }
        }
    }
}
