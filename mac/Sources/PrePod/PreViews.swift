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

    var podcast: PrePodcast? { podcasts.first { $0.slug == slug } }
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
        Task { do { try await loadEpisodes() } catch { self.error = error.localizedDescription } }
    }

    func create(title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                let e = try await api.createEpisode(slug, title: t)
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

extension Color { static let prePod = Color(red: 0.353, green: 0.545, blue: 1.0) }

// MARK: - Selector pre · post

struct SectionSwitcher: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 4) {
            chip(.pre, "pre", .prePod)
            chip(.post, "post", Theme.accent)
        }
        .padding(3)
        .background(Capsule().fill(Theme.panel))
    }
    private func chip(_ s: AppSection, _ label: String, _ color: Color) -> some View {
        Button { app.section = s } label: {
            Text(label)
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
    @StateObject private var model = PreModel()
    @State private var newTitle = ""
    @State private var creating = false

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
        .tint(.prePod)
        .onAppear { if model.podcasts.isEmpty { model.load() } }
        .alert("Algo salió mal", isPresented: Binding(get: { model.error != nil && !model.podcasts.isEmpty },
                                                      set: { if !$0 { model.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                SectionSwitcher()
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.load() } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
            }
            Text("Preproducción: planea tus episodios, el guion, el rundown y los invitados. Todo queda guardado en prePod.")
                .foregroundStyle(Theme.secondary)

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
                HStack(spacing: 12) {
                    Picker("Podcast", selection: Binding(get: { model.slug }, set: { model.select($0) })) {
                        ForEach(model.podcasts) { Text($0.name).tag($0.slug) }
                    }
                    .frame(maxWidth: 340)
                    Button { model.configuring = true } label: { Label("Configurar podcast", systemImage: "slider.horizontal.3") }
                    Toggle("Mostrar archivados", isOn: $model.showArchived).toggleStyle(.checkbox)
                    Spacer()
                    Button { creating = true } label: { Label("Nuevo episodio", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .popover(isPresented: $creating) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nuevo episodio").font(.headline)
                                TextField("Título", text: $newTitle).frame(width: 300)
                                    .onSubmit(createNow)
                                HStack { Spacer(); Button("Crear", action: createNow).buttonStyle(.borderedProminent) }
                            }
                            .padding(16)
                        }
                }
                columns
            }
        }
        .padding(28)
    }

    private func createNow() {
        model.create(title: newTitle)
        newTitle = ""
        creating = false
    }

    private var columns: some View {
        let statuses = EpisodeStatus.allCases.filter { model.showArchived || $0 != .archived }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(statuses) { st in
                    let items = model.episodes.filter { $0.statusValue == st }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(st.title, systemImage: st.symbol).font(.callout.bold())
                            Spacer()
                            Text("\(items.count)").font(.caption).foregroundStyle(Theme.secondary)
                        }
                        ScrollView {
                            VStack(spacing: 8) {
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
                                    Text("Arrastra aquí").font(.caption).foregroundStyle(Theme.secondary.opacity(0.6))
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(width: 230)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    .dropDestination(for: String.self) { ids, _ in
                        for id in ids.compactMap(Int.init) { model.move(id, to: st) }
                        return true
                    }
                }
            }
        }
    }
}

struct EpisodeCardView: View {
    let episode: PreEpisode
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = episode.episodeNumber {
                Text("EP \(n)").font(.caption2.bold()).foregroundStyle(Color.prePod)
            }
            Text(episode.title).font(.callout.weight(.semibold)).lineLimit(3)
            if let w = episode.whenText {
                Label(w, systemImage: "calendar").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelStrong))
        .contentShape(Rectangle())
    }
}

// MARK: - Episodio

struct PreEpisodeView: View {
    @ObservedObject var model: PreModel
    @State var episode: PreEpisode
    @State private var tab = 0
    @State private var date = Date()
    @State private var hasDate = false
    @State private var saver = Debouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.open = nil } label: { Label("Episodios", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let n = episode.episodeNumber { Text("EP \(n)").font(.title3.bold()).foregroundStyle(Color.prePod) }
                TextField("Título", text: $episode.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .onChange(of: episode.title) { _, v in saver.run("title") { await model.save(episode.id, ["title": v]) } }
            }
            HStack(spacing: 18) {
                Picker("Estado", selection: Binding(get: { episode.statusValue }, set: { s in
                    episode.status = s.rawValue
                    Task { await model.save(episode.id, ["status": s.rawValue]) }
                })) {
                    ForEach(EpisodeStatus.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .frame(width: 230)
                Toggle("Fecha de grabación", isOn: $hasDate).toggleStyle(.checkbox)
                    .onChange(of: hasDate) { _, on in saveDate(on ? date : nil) }
                if hasDate {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        .onChange(of: date) { _, d in saveDate(d) }
                }
                Spacer()
            }
            Picker("", selection: $tab) {
                Text("Guion").tag(0)
                Text("Rundown").tag(1)
                Text("Invitados").tag(2)
                Text("Descripción").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            Group {
                switch tab {
                case 0: ScriptTab(slug: model.slug, episodeId: episode.id)
                case 1: RundownTab(slug: model.slug, episodeId: episode.id)
                case 2: GuestsTab(slug: model.slug, episodeId: episode.id)
                default: DescriptionTab(model: model, episode: $episode, saver: saver)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .onAppear(perform: loadDate)
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
                Text("\(sections.count) secciones · ~\(totalMinutes) min").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button { add() } label: { Label("Agregar sección", systemImage: "plus") }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($sections) { $s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Quién habla", text: $s.speaker).frame(maxWidth: 220)
                                    .onChange(of: s.speaker) { _, v in save(s.id, ["speaker": v]) }
                                TextField("min", value: Binding(get: { s.estimatedDuration.map { $0 / 60 } },
                                                                set: { s.estimatedDuration = $0.map { $0 * 60 } }), format: .number)
                                    .frame(width: 50)
                                    .onChange(of: s.estimatedDuration) { _, v in save(s.id, ["estimated_duration": v ?? NSNull()]) }
                                Text("min").font(.caption).foregroundStyle(Theme.secondary)
                                Spacer()
                                Button { move(s, -1) } label: { Image(systemName: "arrow.up") }.disabled(s.position == 0)
                                Button { move(s, 1) } label: { Image(systemName: "arrow.down") }.disabled(s.position >= sections.count - 1)
                                Button(role: .destructive) { remove(s) } label: { Image(systemName: "trash") }
                            }
                            .buttonStyle(.borderless)
                            TextEditor(text: $s.content)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 70)
                                .onChange(of: s.content) { _, v in save(s.id, ["content": v]) }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    }
                }
            }
        }
        .task { await load() }
    }

    private var totalMinutes: Int { Int((sections.compactMap(\.estimatedDuration).reduce(0, +) / 60).rounded()) }

    private func load() async {
        do { sections = try await api.script(slug, episodeId) } catch { self.error = error.localizedDescription }
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
    @State private var error: String?
    @State private var saver = Debouncer()
    private let api = PrePodClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(blocks.count) bloques · ~\(totalMinutes) min").font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    ForEach(BlockKind.allCases) { k in Button(k.title) { add(k) } }
                } label: { Label("Agregar bloque", systemImage: "plus") }
                .fixedSize()
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array($blocks.enumerated()), id: \.element.id) { i, $b in
                        HStack(spacing: 10) {
                            Text(clock(start(of: i))).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 44)
                            Picker("", selection: Binding(get: { BlockKind(rawValue: b.kind) ?? .custom }, set: { k in
                                b.kind = k.rawValue; save(b.id, ["kind": k.rawValue])
                            })) { ForEach(BlockKind.allCases) { Text($0.title).tag($0) } }
                                .labelsHidden().frame(width: 120)
                            TextField("Título", text: $b.title)
                                .onChange(of: b.title) { _, v in save(b.id, ["title": v]) }
                            TextField("min", value: Binding(get: { b.durationEstimate.map { $0 / 60 } },
                                                            set: { b.durationEstimate = $0.map { $0 * 60 } }), format: .number)
                                .frame(width: 50)
                                .onChange(of: b.durationEstimate) { _, v in save(b.id, ["duration_estimate": v ?? NSNull()]) }
                            Text("min").font(.caption).foregroundStyle(Theme.secondary)
                            Button { reorder(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                            Button { reorder(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == blocks.count - 1)
                            Button(role: .destructive) { remove(b) } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(b.kind == "sponsor" ? Color.purple.opacity(0.18) : Theme.panel))
                    }
                }
            }
        }
        .task { await load() }
    }

    private var totalMinutes: Int { Int((blocks.compactMap(\.durationEstimate).reduce(0, +) / 60).rounded()) }
    private func start(of i: Int) -> Double { blocks.prefix(i).compactMap(\.durationEstimate).reduce(0, +) }
    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func load() async {
        do { blocks = try await api.blocks(slug, episodeId) } catch { self.error = error.localizedDescription }
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
            if let note { Text(note).foregroundStyle(Theme.secondary).font(.caption) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($guests) { $g in
                        HStack(spacing: 10) {
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
                            .onChange(of: g.rsvpStatus) { _, v in save(g.id, ["rsvp_status": v]) }
                            Button("Invitar") { invite(g) }
                                .disabled(g.email.trimmingCharacters(in: .whitespaces).isEmpty)
                                .help("Envía la invitación con el link para confirmar")
                            Spacer()
                            Button(role: .destructive) { remove(g) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                    }
                }
            }
            Card {
                Text("Agregar a alguien").font(.headline)
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
    private func invite(_ g: PreGuest) {
        Task {
            do { let (_, msg) = try await api.sendRSVP(slug, g.id); note = "\(g.name): \(msg)" }
            catch { self.error = error.localizedDescription }
        }
    }
}
