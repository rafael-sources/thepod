import SwiftUI

private let api = PrePodClient.shared

// MARK: - Ideas del episodio

struct IdeasTab: View {
    let slug: String
    let episodeId: Int
    @State private var ideas: [EpisodeIdea] = []
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Escribe una idea, una pregunta o un tema…", text: $text).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Agregar", action: add).buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ideas) { idea in
                        HStack(alignment: .top, spacing: 12) {
                            Button { vote(idea) } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: idea.votedByMe ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    Text("\(idea.votes)").font(.caption.monospacedDigit())
                                }
                                .frame(width: 36)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(idea.votedByMe ? Color.prePod : Theme.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(idea.content).strikethrough(idea.status == "rejected")
                                Text(idea.author).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Picker("", selection: Binding(get: { idea.status }, set: { setStatus(idea, $0) })) {
                                Text("Propuesta").tag("proposed"); Text("Aceptada").tag("accepted"); Text("Descartada").tag("rejected")
                            }
                            .labelsHidden().frame(width: 130)
                            Button(role: .destructive) { remove(idea) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                        .overlay(alignment: .leading) {
                            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                                .fill(ideaColor(idea.status)).frame(width: 4)
                        }
                        .opacity(idea.status == "rejected" ? 0.6 : 1)
                    }
                    if ideas.isEmpty {
                        EmptyHint(symbol: "lightbulb", title: String(localized: "Todavía no hay ideas"),
                                  text: String(localized: "Cualquiera del equipo puede proponer. Las más votadas suben arriba."))
                    }
                }
            }
        }
        .task { await load() }
    }

    private func ideaColor(_ s: String) -> Color {
        s == "accepted" ? Theme.good : (s == "rejected" ? Color(white: 0.45) : EpisodeStatus.idea.color)
    }
    private func load() async { do { ideas = try await api.ideas(slug, episodeId).sorted { $0.votes > $1.votes } } catch { self.error = error.localizedDescription } }
    private func run(_ op: @escaping () async throws -> Void) {
        Task { do { try await op(); await load(); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func add() {
        let t = text.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        text = ""
        run { _ = try await api.addIdea(slug, episodeId, String(t.prefix(500))) }
    }
    private func vote(_ i: EpisodeIdea) { run { try await api.vote(slug, i.id, on: !i.votedByMe) } }
    private func setStatus(_ i: EpisodeIdea, _ s: String) { run { try await api.setIdeaStatus(slug, i.id, s) } }
    private func remove(_ i: EpisodeIdea) { run { try await api.deleteIdea(slug, i.id) } }
}

// MARK: - Publicación del episodio: descripción, links y notas

struct PublicationTab: View {
    @ObservedObject var model: PreModel
    @Binding var episode: PreEpisode
    let saver: Debouncer
    @State private var links: [String: String] = [:]
    @State private var notes = ""
    @State private var syncing = false
    @State private var error: String?

    private let platforms: [(String, String)] = [("youtube", "YouTube"), ("spotify", "Spotify"),
                                                 ("apple_podcasts", String(localized: "Apple Podcasts")), ("website", String(localized: "Página web"))]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Card {
                    Label("Descripción", systemImage: "text.alignleft").font(.headline)
                    Text("De qué trata el episodio. Sale al publicar y en tu página.").font(.caption).foregroundStyle(Theme.secondary)
                    TextEditor(text: Binding(get: { episode.description ?? "" }, set: { episode.description = $0 }))
                        .scrollContentBackground(.hidden).padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                        .frame(minHeight: 110)
                        .onChange(of: episode.description) { _, v in saver.run("desc") { await model.save(episode.id, ["description": v ?? ""]) } }
                }
                Card {
                    Label("Dónde escucharlo", systemImage: "link").font(.headline)
                    Text("Pega el link de cada plataforma cuando el episodio ya esté publicado.").font(.caption).foregroundStyle(Theme.secondary)
                    ForEach(platforms, id: \.0) { key, title in
                        HStack(spacing: 10) {
                            Image(systemName: icon(key)).foregroundStyle(color(key)).frame(width: 20)
                            Text(title).frame(width: 120, alignment: .leading)
                            TextField("https://…", text: Binding(get: { links[key] ?? "" }, set: { links[key] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { saveLink(key) }
                            Button("Guardar") { saveLink(key) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        HStack {
                            Label("Resumen de postPod", systemImage: "sparkles").font(.headline)
                            Spacer()
                            Button { sync() } label: { Label(syncing ? "Actualizando…" : "Traer de postPod", systemImage: "arrow.triangle.2.circlepath") }
                                .disabled(syncing)
                        }
                        if let s = episode.aiSummary, !s.isEmpty {
                            Text(s).textSelection(.enabled).foregroundStyle(Theme.secondary)
                        } else {
                            Text("Aparece cuando el episodio se edita en postPod.").font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        HStack {
                            Label("Notas del episodio", systemImage: "doc.plaintext").font(.headline)
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(notes, forType: .string) } label: {
                                Label("Copiar", systemImage: "doc.on.doc")
                            }
                            .disabled(notes.isEmpty)
                        }
                        Text("Capítulos, invitados y links, listos para pegar en YouTube o Spotify.").font(.caption).foregroundStyle(Theme.secondary)
                        Text(notes.isEmpty ? "—" : notes)
                            .font(.callout).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    }
                }
            }
        }
        .task { await load() }
    }

    private func icon(_ k: String) -> String {
        ["youtube": "play.rectangle.fill", "spotify": "dot.radiowaves.left.and.right", "apple_podcasts": "headphones", "website": "globe"][k] ?? "link"
    }
    private func color(_ k: String) -> Color {
        ["youtube": Color.red, "spotify": Color.green, "apple_podcasts": Color.purple][k] ?? Color.prePod
    }
    private func load() async {
        do {
            let ls = try await api.links(model.slug, episode.id)
            links = Dictionary(ls.map { ($0.platform.lowercased(), $0.url) }, uniquingKeysWith: { a, _ in a })
            notes = (try? await api.showNotes(model.slug, episode.id).text) ?? ""
        } catch { self.error = error.localizedDescription }
    }
    private func saveLink(_ key: String) {
        let url = (links[key] ?? "").trimmingCharacters(in: .whitespaces)
        Task {
            do {
                if url.isEmpty { try await api.deleteLink(model.slug, episode.id, platform: key) }
                else { try await api.setLink(model.slug, episode.id, platform: key, url: url) }
                notes = (try? await api.showNotes(model.slug, episode.id).text) ?? notes
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func sync() {
        syncing = true
        Task {
            defer { syncing = false }
            do {
                try await api.syncNotes(model.slug, episode.id)
                if let e = try await api.preEpisodes(model.slug).first(where: { $0.id == episode.id }) { episode.aiSummary = e.aiSummary }
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Calendario

struct PreCalendarView: View {
    @ObservedObject var model: PreModel
    @State private var dropDay: Date?
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "es"); c.firstWeekday = 2; return c }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Text(title).font(.title3.bold()).frame(minWidth: 180)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                Button("Hoy") { month = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date() }
                Spacer()
            }
            .buttonStyle(.bordered)
            let days = gridDays
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(["lun", "mar", "mié", "jue", "vie", "sáb", "dom"], id: \.self) {
                    Text($0).font(.caption.bold()).foregroundStyle(Theme.secondary)
                }
                ForEach(days, id: \.self) { d in
                    let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
                    let eps = episodes(on: d)
                    let today = cal.isDateInToday(d)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(cal.component(.day, from: d))")
                            .font(.caption.bold())
                            .padding(.horizontal, today ? 6 : 0).padding(.vertical, today ? 1 : 0)
                            .background(Capsule().fill(today ? model.accent : .clear))
                            .foregroundStyle(today ? Color.black : (inMonth ? .primary : Theme.secondary.opacity(0.5)))
                        ForEach(eps) { e in
                            let st = e.statusValue
                            HStack(spacing: 4) {
                                Image(systemName: st.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(st.color)
                                Text(e.episodeNumber.map { "Ep \($0) · \(e.title)" } ?? e.title)
                                    .font(.caption2).lineLimit(2)
                            }
                            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(st.color.opacity(0.22)))
                            .contentShape(Rectangle())
                            .onTapGesture { model.open = e }
                            .draggable(String(e.id))
                            .help(st.title)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(dropDay == d ? model.accent.opacity(0.25) : (inMonth ? Theme.panel : Color.clear)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(today ? model.accent.opacity(0.6) : .clear))
                    .dropDestination(for: String.self) { ids, _ in
                        for id in ids.compactMap(Int.init) { schedule(id, on: d) }
                        return true
                    } isTargeted: { on in
                        if on { dropDay = d } else if dropDay == d { dropDay = nil }
                    }
                }
            }
            let undated = model.episodes.filter { day(of: $0) == nil && $0.statusValue != .published && $0.statusValue != .archived }
            if !undated.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sin fecha").font(.headline)
                    Text("Arrastra uno a un día para ponerle fecha de grabación.").font(.caption).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 6)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(undated) { e in
                            EpisodeCardView(episode: e).frame(width: 200)
                                .onTapGesture { model.open = e }
                                .draggable(String(e.id))
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.dateFormat = "LLLL yyyy"
        return f.string(from: month).capitalized
    }
    /// Pone la fecha de grabación; si ya tenía hora, la conserva.
    private func schedule(_ id: Int, on d: Date) {
        guard let e = model.episodes.first(where: { $0.id == id }) else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: d)
        var fields: [String: Any] = ["scheduled_date": day]
        if let at = e.scheduledAt, at.count >= 16 { fields["scheduled_at"] = day + String(at.dropFirst(10).prefix(6)) }
        Task { await model.save(id, fields) }
    }
    private func shift(_ n: Int) { month = cal.date(byAdding: .month, value: n, to: month) ?? month }
    private var gridDays: [Date] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = month
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: first)!
        let total = Int(ceil(Double(lead + range.count) / 7.0)) * 7
        return (0..<total).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
    private func day(of e: PreEpisode) -> Date? {
        guard let raw = e.scheduledAt ?? e.scheduledDate, raw.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }
    private func episodes(on d: Date) -> [PreEpisode] {
        model.episodes.filter { e in day(of: e).map { cal.isDate($0, inSameDayAs: d) } ?? false }
    }
}

// MARK: - Plantillas (en Configurar podcast)

struct TemplatesTab: View {
    let slug: String
    @State private var templates: [ShowTemplate] = []
    @State private var selected: Int?
    @State private var detail: TemplateDetail?
    @State private var newName = ""
    @State private var error: String?
    @State private var saver = Debouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Una plantilla es el rundown y el guion con que nace cada episodio nuevo. La marcada por defecto se usa sola.")
                .font(.caption).foregroundStyle(Theme.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(templates) { t in
                        Button { select(t.id) } label: {
                            HStack {
                                Text(t.name).lineLimit(1)
                                if t.isDefault { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.prePod) }
                                Spacer()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected == t.id ? Theme.panelStrong : Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        TextField("Nueva plantilla", text: $newName).onSubmit(add)
                        Button { add() } label: { Image(systemName: "plus") }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .frame(width: 220)
                if let d = detail { editor(d) } else { Text("Elige una plantilla").foregroundStyle(Theme.secondary) }
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func editor(_ d: TemplateDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nombre", text: Binding(get: { detail?.name ?? "" }, set: { v in detail?.name = v; if !v.isEmpty { save("name-\(d.id)") { try await api.updateTemplate(slug, d.id, ["name": v]) } } }))
                    .font(.headline)
                Toggle("Por defecto", isOn: Binding(get: { detail?.isDefault ?? false }, set: { v in
                    detail?.isDefault = v; run { try await api.updateTemplate(slug, d.id, ["is_default": v]) } }))
                    .toggleStyle(.checkbox)
                Button("Eliminar", role: .destructive) { run { try await api.deleteTemplate(slug, d.id); selected = nil; detail = nil } }
            }
            HStack {
                Text("Rundown").font(.headline)
                Spacer()
                Menu { ForEach(BlockKind.allCases) { k in Button(k.title) { run { _ = try await api.addTemplateBlock(slug, d.id, kind: k) } } } }
                    label: { Label("Bloque", systemImage: "plus") }.fixedSize()
            }
            ForEach(Array((detail?.blocks ?? []).enumerated()), id: \.element.id) { i, b in
                HStack {
                    Picker("", selection: Binding(get: { BlockKind(rawValue: b.kind) ?? .custom }, set: { k in
                        detail?.blocks[i].kind = k.rawValue; save("bk\(b.id)") { try await api.updateTemplateBlock(slug, b.id, ["kind": k.rawValue]) } })) {
                        ForEach(BlockKind.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 120)
                    TextField("Título", text: Binding(get: { detail?.blocks[safe: i]?.title ?? "" }, set: { v in
                        detail?.blocks[i].title = v; save("bt\(b.id)") { try await api.updateTemplateBlock(slug, b.id, ["title": v]) } }))
                    TextField("min", value: Binding(get: { detail?.blocks[safe: i]?.durationEstimate }, set: { v in
                        detail?.blocks[i].durationEstimate = v; save("bd\(b.id)") { try await api.updateTemplateBlock(slug, b.id, ["duration_estimate": v ?? NSNull()]) } }),
                              format: .number).frame(width: 50)
                    Text("min").font(.caption).foregroundStyle(Theme.secondary)
                    Button { moveBlock(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                    Button { moveBlock(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == (detail?.blocks.count ?? 0) - 1)
                    Button(role: .destructive) { run { try await api.deleteTemplateBlock(slug, b.id) } } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("Guion base").font(.headline)
                Spacer()
                Button { run { _ = try await api.addTemplateSection(slug, d.id) } } label: { Label("Sección", systemImage: "plus") }
            }
            ForEach(Array((detail?.sections ?? []).enumerated()), id: \.element.id) { i, sec in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Quién habla", text: Binding(get: { detail?.sections[safe: i]?.speaker ?? "" }, set: { v in
                            detail?.sections[i].speaker = v; save("ss\(sec.id)") { try await api.updateTemplateSection(slug, sec.id, ["speaker": v]) } }))
                            .frame(maxWidth: 220)
                        Spacer()
                        Button(role: .destructive) { run { try await api.deleteTemplateSection(slug, sec.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    TextEditor(text: Binding(get: { detail?.sections[safe: i]?.content ?? "" }, set: { v in
                        detail?.sections[i].content = v; save("sc\(sec.id)") { try await api.updateTemplateSection(slug, sec.id, ["content": v]) } }))
                        .scrollContentBackground(.hidden).frame(minHeight: 50)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            }
        }
    }

    private func load() async {
        do {
            templates = try await api.templates(slug)
            if selected == nil { selected = templates.first(where: \.isDefault)?.id ?? templates.first?.id }
            if let s = selected { detail = try await api.template(slug, s) }
        } catch { self.error = error.localizedDescription }
    }
    private func select(_ id: Int) { selected = id; Task { detail = try? await api.template(slug, id) } }
    private func run(_ op: @escaping () async throws -> Void) {
        Task { do { try await op(); await load(); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func save(_ key: String, _ op: @escaping () async throws -> Void) {
        saver.run(key) { do { try await op() } catch { self.error = error.localizedDescription } }
    }
    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        newName = ""
        Task {
            do { let t = try await api.addTemplate(slug, name: n); selected = t.id; await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func moveBlock(_ i: Int, _ delta: Int) {
        guard let d = detail else { return }
        var ids = d.blocks.map(\.id); ids.swapAt(i, i + delta)
        Task {
            do { detail?.blocks = try await api.reorderTemplateBlocks(slug, d.id, ids) } catch { self.error = error.localizedDescription }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Página del podcast (landing) y equipo

struct LandingTab: View {
    let slug: String
    @State private var cfg: LandingConfig?
    @State private var team: [TeamMember] = []
    @State private var photos: [Int: NSImage] = [:]
    @State private var newMember = ""
    @State private var error: String?
    @State private var saver = Debouncer()

    private let socials: [(String, String, WritableKeyPath<LandingConfig, String?>)] = [
        ("YouTube", "social_youtube", \.socialYoutube), ("Spotify", "social_spotify", \.socialSpotify),
        (String(localized: "Apple Podcasts"), "social_apple_podcasts", \.socialApplePodcasts), ("Instagram", "social_instagram", \.socialInstagram),
        ("TikTok", "social_tiktok", \.socialTiktok), (String(localized: "X / Twitter"), "social_twitter", \.socialTwitter),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Aquí van los datos básicos de tu página. El diseño completo (secciones, colores, orden) se edita en la web.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    let base = PrePodClient.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    if let u = URL(string: base + "/") { NSWorkspace.shared.open(u) }
                } label: { Label("Abrir el editor completo", systemImage: "safari") }
                .controlSize(.small)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if cfg != nil {
                HStack {
                    Text("La página pública de tu podcast, con tus episodios y tu equipo.").font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    if let u = URL(string: PrePodClient.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/landing/\(slug)") {
                        Link("Ver mi página", destination: u)
                    }
                }
                Picker("Diseño", selection: Binding(get: { cfg?.template ?? "minimal" }, set: { v in cfg?.template = v; put("template", v) })) {
                    Text("Minimalista").tag("minimal"); Text("Llamativo").tag("bold"); Text("Clásico").tag("classic")
                }
                .pickerStyle(.segmented).frame(maxWidth: 380)
                HStack(spacing: 20) {
                    Toggle("Mostrar episodios", isOn: Binding(get: { cfg?.showEpisodes ?? true }, set: { v in cfg?.showEpisodes = v; put("show_episodes", v) }))
                    Toggle("Mostrar equipo", isOn: Binding(get: { cfg?.showTeam ?? false }, set: { v in cfg?.showTeam = v; put("show_team", v) }))
                }
                .toggleStyle(.checkbox)
                HStack {
                    TextField("Nombre del responsable", text: text(\.ownerName, "owner_name"))
                    TextField("Correo del responsable", text: text(\.ownerEmail, "owner_email"))
                }
                Text("Spotify y Apple Podcasts piden un responsable con correo.").font(.caption2).foregroundStyle(Theme.secondary)
                Text("Redes").font(.headline)
                ForEach(socials, id: \.1) { title, key, kp in
                    HStack { Text(title).frame(width: 120, alignment: .leading); TextField("Link", text: text(kp, key)) }
                }
                Text("Equipo").font(.headline).padding(.top, 6)
                ForEach($team) { $m in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Theme.panelStrong)
                            if let img = photos[m.id] { Image(nsImage: img).resizable().scaledToFill().clipShape(Circle()) }
                            else { Image(systemName: "person.fill").foregroundStyle(Theme.secondary) }
                        }
                        .frame(width: 44, height: 44)
                        .onTapGesture { choosePhoto(m.id) }
                        .help("Cambiar foto")
                        TextField("Nombre", text: $m.name).frame(width: 180)
                            .onChange(of: m.name) { _, v in if !v.isEmpty { saveMember(m.id, ["name": v]) } }
                        TextField("Rol", text: Binding(get: { m.role ?? "" }, set: { m.role = $0 })).frame(width: 140)
                            .onChange(of: m.role) { _, v in saveMember(m.id, ["role": v ?? ""]) }
                        TextField("Instagram", text: Binding(get: { m.socialInstagram ?? "" }, set: { m.socialInstagram = $0 }))
                            .onChange(of: m.socialInstagram) { _, v in saveMember(m.id, ["social_instagram": v ?? ""]) }
                        Button(role: .destructive) { removeMember(m.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Nombre de un integrante", text: $newMember).frame(width: 260).onSubmit(addMember)
                    Button("Agregar", action: addMember).disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Quien esté en el equipo se agrega solo como conductor en cada episodio nuevo.").font(.caption2).foregroundStyle(Theme.secondary)
            } else { ProgressView() }
        }
        .task { await load() }
    }

    private func text(_ kp: WritableKeyPath<LandingConfig, String?>, _ key: String) -> Binding<String> {
        Binding(get: { cfg?[keyPath: kp] ?? "" }, set: { v in cfg?[keyPath: kp] = v; put(key, v) })
    }
    private func put(_ key: String, _ value: Any) {
        saver.run(key) { do { try await api.updateLanding(slug, [key: value]); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func load() async {
        do {
            cfg = try await api.landing(slug)
            team = try await api.team(slug)
            for m in team { if let u = m.imageUrl, let d = try? await api.media(u), let img = NSImage(data: d) { photos[m.id] = img } }
        } catch { self.error = error.localizedDescription }
    }
    private func saveMember(_ id: Int, _ fields: [String: Any]) {
        saver.run("m\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateTeamMember(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func addMember() {
        let n = newMember.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        newMember = ""
        Task { do { team.append(try await api.addTeamMember(slug, name: n)) } catch { self.error = error.localizedDescription } }
    }
    private func removeMember(_ id: Int) {
        Task { do { try await api.deleteTeamMember(slug, id); team.removeAll { $0.id == id } } catch { self.error = error.localizedDescription } }
    }
    private func choosePhoto(_ id: Int) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .webP]
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            do { try await api.uploadTeamImage(slug, id, file: url); if let img = NSImage(contentsOf: url) { photos[id] = img } }
            catch { self.error = error.localizedDescription }
        }
    }
}
