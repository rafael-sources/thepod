import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// "Configurar podcast": lo mismo que la configuración del podcast en prePod web.
struct PodcastSettingsView: View {
    let slug: String
    let onClose: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onClose) { Label("Episodios", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            Text("Configurar podcast").font(.system(size: 28, weight: .bold, design: .rounded))
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Branding").tag(1)
                Text("Equipo").tag(2)
                Text("Sponsors").tag(3)
                Text("Soundboard").tag(4)
                Text("Plantillas").tag(6)
                Text("Página").tag(7)
                Text("Distribución").tag(5)
                Text("Redes").tag(8)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 860)
            ScrollView {
                Group {
                    switch tab {
                    case 0: GeneralTab(slug: slug)
                    case 1: BrandingTab(slug: slug)
                    case 2: TeamTab(slug: slug)
                    case 3: SponsorsTab(slug: slug)
                    case 4: SoundboardTab(slug: slug)
                    case 6: TemplatesTab(slug: slug)
                    case 7: LandingTab(slug: slug)
                    case 8: RedesTab(slug: slug)
                    default: DistributionTab(slug: slug)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.bottom, 30)
            }
        }
        .padding(28)
    }
}

private let api = PrePodClient.shared

private struct ErrorLine: View {
    let text: String?
    var body: some View { if let text { Text(text).font(.caption).foregroundStyle(.orange) } }
}

private func pickFile(_ types: [UTType], _ done: @escaping (URL) -> Void) {
    let p = NSOpenPanel()
    p.allowedContentTypes = types
    p.allowsMultipleSelection = false
    if p.runModal() == .OK, let u = p.url { done(u) }
}

// MARK: General

private struct GeneralTab: View {
    let slug: String
    @State private var exporting = false
    @State private var cfg: PodcastConfig?
    @State private var error: String?
    @State private var saver = Debouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ErrorLine(text: error)
            if let _ = cfg {
                field(String(localized: "Nombre"), text: binding(\.name, key: "name"))
                field(String(localized: "Frase corta"), text: binding(\.tagline, key: "tagline"))
                Text("Descripción").font(.headline)
                Text("Sale en tu página y en Spotify / Apple Podcasts.").font(.caption).foregroundStyle(Theme.secondary)
                TextEditor(text: binding(\.description, key: "description"))
                    .scrollContentBackground(.hidden).padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    .frame(minHeight: 160)
                Divider().padding(.vertical, 6)
                Text("Copia del podcast").font(.headline)
                Text("Un .zip con todo el podcast (datos, episodios, guiones, branding y sonidos) para guardarlo o pasarlo a otra cuenta.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Button {
                    Task {
                        do {
                            exporting = true
                            if let url = try await api.saveDownload("/api/podcasts/\(slug)/export-bundle", suggestedName: "\(slug).zip") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } catch { self.error = error.localizedDescription }
                        exporting = false
                    }
                } label: { Label(exporting ? String(localized: "Preparando…") : String(localized: "Exportar podcast (.zip)"), systemImage: "archivebox") }
                .disabled(exporting)
            } else { ProgressView() }
        }
        .task { do { cfg = try await api.podcastConfig(slug) } catch { self.error = error.localizedDescription } }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(maxWidth: 520)
        }
    }

    private func binding(_ kp: WritableKeyPath<PodcastConfig, String>, key: String) -> Binding<String> {
        Binding(get: { cfg?[keyPath: kp] ?? "" }, set: { v in cfg?[keyPath: kp] = v; save(key, v) })
    }
    private func binding(_ kp: WritableKeyPath<PodcastConfig, String?>, key: String) -> Binding<String> {
        Binding(get: { cfg?[keyPath: kp] ?? "" }, set: { v in cfg?[keyPath: kp] = v; save(key, v) })
    }
    private func save(_ key: String, _ value: String) {
        if key == "name", value.trimmingCharacters(in: .whitespaces).isEmpty { return }
        saver.run(key) {
            do { _ = try await api.updatePodcast(slug, [key: value]); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Branding

private struct BrandingTab: View {
    let slug: String
    @State private var cfg: PodcastConfig?
    @State private var fonts: [String] = []
    @State private var images: [String: NSImage] = [:]
    @State private var busy: String?
    @State private var error: String?
    @State private var saver = Debouncer()

    private let colorFields: [(String, String, WritableKeyPath<PodcastConfig, String?>)] = [
        (String(localized: "Principal"), "color_primary", \.colorPrimary),
        (String(localized: "Secundario"), "color_secondary", \.colorSecondary),
        (String(localized: "Acento"), "color_accent", \.colorAccent),
        (String(localized: "Fondo"), "color_bg", \.colorBg),
        (String(localized: "Texto"), "color_text", \.colorText),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ErrorLine(text: error)
            if cfg != nil {
                Text("Imágenes").font(.headline)
                HStack(alignment: .top, spacing: 18) {
                    imageSlot(String(localized: "Logo"), kind: "logo", hint: String(localized: "Cuadrado, hasta 500 px"))
                    imageSlot(String(localized: "Portada"), kind: "cover", hint: String(localized: "La del podcast en las plataformas"))
                    imageSlot(String(localized: "Fondo"), kind: "background", hint: String(localized: "Para videos y tu página"))
                }
                Text("Colores").font(.headline)
                HStack(spacing: 18) {
                    ForEach(colorFields, id: \.1) { title, key, kp in
                        VStack(spacing: 6) {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: cfg?[keyPath: kp] ?? "#888888") },
                                set: { c in cfg?[keyPath: kp] = c.hex; save(key, c.hex) }), supportsOpacity: false)
                                .labelsHidden()
                            Text(title).font(.caption)
                        }
                    }
                }
                Text("Tipografías").font(.headline)
                HStack(spacing: 20) {
                    fontPicker(String(localized: "Títulos"), key: "font_heading", kp: \.fontHeading)
                    fontPicker(String(localized: "Texto"), key: "font_body", kp: \.fontBody)
                }
                preview
            } else { ProgressView() }
        }
        .task { await load() }
    }

    private var preview: some View {
        let bg = Color(hex: cfg?.colorBg ?? cfg?.colorSecondary ?? "#1e2a54")
        return VStack(alignment: .leading, spacing: 6) {
            Text(cfg?.name ?? "").font(.custom(cfg?.fontHeading ?? "", size: 26)).foregroundStyle(Color(hex: cfg?.colorPrimary ?? "#5a8bff"))
            Text(cfg?.tagline ?? String(localized: "Así se ve tu marca")).font(.custom(cfg?.fontBody ?? "", size: 14)).foregroundStyle(Color(hex: cfg?.colorText ?? "#ffffff"))
            Capsule().fill(Color(hex: cfg?.colorAccent ?? "#f4c770")).frame(width: 80, height: 6)
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(bg))
    }

    private func fontPicker(_ title: String, key: String, kp: WritableKeyPath<PodcastConfig, String?>) -> some View {
        Picker(title, selection: Binding(get: { cfg?[keyPath: kp] ?? "" }, set: { v in cfg?[keyPath: kp] = v; save(key, v) })) {
            ForEach(fonts, id: \.self) { Text($0).tag($0) }
            if let cur = cfg?[keyPath: kp], !fonts.contains(cur) { Text(cur).tag(cur) }
        }
        .frame(width: 280)
    }

    private func imageSlot(_ title: String, kind: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.panel)
                if let img = images[kind] {
                    Image(nsImage: img).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(Theme.secondary)
                }
                if busy == kind { ProgressView() }
            }
            .frame(width: 160, height: 120)
            Text(title).font(.callout.bold())
            Text(hint).font(.caption2).foregroundStyle(Theme.secondary).frame(width: 160, alignment: .leading)
            HStack {
                Button("Cambiar…") { pickFile([.png, .jpeg, .webP]) { upload(kind, $0) } }
                if images[kind] != nil {
                    Button("Quitar", role: .destructive) { remove(kind) }
                }
            }
            .controlSize(.small)
        }
    }

    private func load() async {
        do {
            cfg = try await api.podcastConfig(slug)
            fonts = (try? await api.fonts()) ?? []
            await loadImages()
        } catch { self.error = error.localizedDescription }
    }
    private func loadImages() async {
        var out: [String: NSImage] = [:]
        for (kind, url) in [("logo", cfg?.logoUrl), ("cover", cfg?.coverUrl), ("background", cfg?.backgroundUrl)] {
            if let url, let data = try? await api.media(url), let img = NSImage(data: data) { out[kind] = img }
        }
        images = out
    }
    private func upload(_ kind: String, _ file: URL) {
        busy = kind
        Task {
            defer { busy = nil }
            do { try await api.uploadBranding(slug, kind: kind, file: file); cfg = try await api.podcastConfig(slug); await loadImages(); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ kind: String) {
        Task {
            do { try await api.deleteBranding(slug, kind: kind); images[kind] = nil } catch { self.error = error.localizedDescription }
        }
    }
    private func save(_ key: String, _ value: String) {
        saver.run(key, delay: 0.5) {
            do { _ = try await api.updatePodcast(slug, [key: value]); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Equipo

private struct TeamTab: View {
    let slug: String
    @State private var hosts: PodcastHosts?
    @State private var query = ""
    @State private var results: [SuiteUser] = []
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ErrorLine(text: error)
            if let note { Text(note).font(.caption).foregroundStyle(Theme.good) }
            if let h = hosts {
                Card {
                    Text("Conductores").font(.headline)
                    Text("Pueden ver y editar todo el podcast en thePod.").font(.caption).foregroundStyle(Theme.secondary)
                    if let o = h.owner { row(o, badge: String(localized: "Dueño"), removable: false) {} }
                    ForEach(h.extraHosts, id: \.self) { u in
                        row(u, badge: h.invitations?[u]?.status == "pendiente" ? String(localized: "Invitación pendiente") : nil, removable: true) {
                            change { try await api.setHosts(slug, h.extraHosts.filter { $0 != u }) }
                        }
                    }
                }
                Card {
                    Text("Directores").font(.headline)
                    Text("Manejan la sala en vivo de prodPod.").font(.caption).foregroundStyle(Theme.secondary)
                    ForEach(h.directors ?? [], id: \.self) { u in
                        row(u, badge: nil, removable: true) { change { try await api.removeDirector(slug, u) } }
                    }
                    if (h.directors ?? []).isEmpty { Text("Nadie todavía").font(.caption).foregroundStyle(Theme.secondary) }
                }
                Card {
                    Text("Agregar a alguien de thePod").font(.headline)
                    TextField("Busca por nombre o usuario", text: $query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        .onChange(of: query) { _, q in search(q) }
                    ForEach(results) { u in
                        HStack {
                            Text(u.label)
                            Spacer()
                            Button("Invitar como conductor") {
                                change { try await api.inviteHost(slug, u.username) }
                                note = String(localized: "Invitación enviada a \(u.username)")
                            }
                            Button("Agregar como director") { change { try await api.addDirector(slug, u.username) } }
                        }
                        .controlSize(.small)
                    }
                }
            } else { ProgressView() }
        }
        .task { await load() }
    }

    private func row(_ user: String, badge: String?, removable: Bool, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "person.crop.circle").foregroundStyle(Theme.secondary)
            Text(user)
            if let badge { Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.panelStrong)) }
            Spacer()
            if removable { Button("Quitar", role: .destructive, action: remove).controlSize(.small) }
        }
    }
    private func load() async {
        do { hosts = try await api.hosts(slug) } catch { self.error = error.localizedDescription }
    }
    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); await load(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
    private func search(_ q: String) {
        guard q.count >= 2 else { results = []; return }
        Task { results = (try? await api.searchUsers(q)) ?? [] }
    }
}

// MARK: Sponsors

private struct SponsorsTab: View {
    let slug: String
    @State private var reportFor: Sponsor2?
    @State private var items: [Sponsor2] = []
    @State private var logos: [Int: NSImage] = [:]
    @State private var newName = ""
    @State private var error: String?
    @State private var saver = Debouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ErrorLine(text: error)
            HStack {
                TextField("Nombre del nuevo sponsor", text: $newName).textFieldStyle(.roundedBorder).frame(width: 280)
                    .onSubmit(add)
                Button("Agregar", action: add).buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach($items) { $s in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.9))
                            if let img = logos[s.id] { Image(nsImage: img).resizable().scaledToFit().padding(6) }
                            else { Text("Logo").font(.caption).foregroundStyle(.black.opacity(0.5)) }
                        }
                        .frame(width: 90, height: 60)
                        Button("Logo…") { pickFile([.png, .jpeg, .webP, .svg]) { uploadLogo(s.id, $0) } }.controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Nombre", text: $s.name).font(.headline)
                                .onChange(of: s.name) { _, v in if !v.isEmpty { save(s.id, ["name": v]) } }
                            Toggle("Activo", isOn: $s.isActive).toggleStyle(.switch).controlSize(.small)
                                .onChange(of: s.isActive) { _, v in save(s.id, ["is_active": v]) }
                        }
                        TextField("Qué se dice al aire", text: $s.copy, axis: .vertical).lineLimit(2...5)
                            .onChange(of: s.copy) { _, v in save(s.id, ["copy": v]) }
                        HStack {
                            TextField("Link", text: $s.url).onChange(of: s.url) { _, v in save(s.id, ["url": v]) }
                            if let n = s.episodeCount { Text("\(n) episodios").font(.caption).foregroundStyle(Theme.secondary) }
                            Button("Reporte") { reportFor = s }.controlSize(.small).help("En qué episodios aparece y cuánto tiempo al aire")
                            Button(role: .destructive) { remove(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }
            if items.isEmpty { Text("Todavía no hay sponsors.").foregroundStyle(Theme.secondary) }
        }
        .task { await load() }
        .sheet(item: $reportFor) { s in SponsorReportSheet(slug: slug, sponsor: s) { reportFor = nil } }
    }

    private func load() async {
        do {
            items = try await api.sponsors(slug)
            for s in items { if let u = s.logoUrl, !u.isEmpty, let d = try? await api.media(u), let img = NSImage(data: d) { logos[s.id] = img } }
        } catch { self.error = error.localizedDescription }
    }
    private func add() {
        let n = newName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        newName = ""
        Task { do { items.append(try await api.addSponsor(slug, name: n)) } catch { self.error = error.localizedDescription } }
    }
    private func save(_ id: Int, _ fields: [String: Any]) {
        saver.run("\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateSponsor(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ id: Int) {
        Task { do { try await api.deleteSponsor(slug, id); items.removeAll { $0.id == id } } catch { self.error = error.localizedDescription } }
    }
    private func uploadLogo(_ id: Int, _ file: URL) {
        Task {
            do {
                _ = try await api.uploadSponsorLogo(slug, id, file: file)
                if let img = NSImage(contentsOf: file) { logos[id] = img }
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Soundboard

private struct SoundboardTab: View {
    let slug: String
    @State private var items: [SoundItem] = []
    @State private var library: [LibrarySound] = []
    @State private var picked: Set<String> = []
    @State private var showLibrary = false
    @State private var player: AVAudioPlayer?
    @State private var error: String?
    @State private var saver = Debouncer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ErrorLine(text: error)
            Text("Los sonidos que tocas en vivo en prodPod. Los mismos llegan a Efectos en post.").font(.caption).foregroundStyle(Theme.secondary)
            HStack {
                Button { pickFile([.audio]) { add($0) } } label: { Label("Subir sonido…", systemImage: "square.and.arrow.up") }
                Button { openLibrary() } label: { Label("Elegir de la biblioteca", systemImage: "books.vertical") }
            }
            ForEach($items) { $s in
                HStack(spacing: 10) {
                    Button { play(s) } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless)
                    TextField("Nombre", text: $s.name).frame(width: 240)
                        .onChange(of: s.name) { _, v in if !v.isEmpty { save(s.id, ["name": v]) } }
                    Text("Tecla").font(.caption).foregroundStyle(Theme.secondary)
                    TextField("", text: Binding(get: { s.shortcutKey ?? "" }, set: { s.shortcutKey = String($0.suffix(1)) }))
                        .frame(width: 34)
                        .onChange(of: s.shortcutKey) { _, v in save(s.id, ["shortcut_key": v ?? ""]) }
                    ColorPicker("", selection: Binding(get: { Color(hex: s.color ?? "#5a8bff") }, set: { c in s.color = c.hex; save(s.id, ["color": c.hex]) }),
                                supportsOpacity: false).labelsHidden()
                    Spacer()
                    Button(role: .destructive) { remove(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            }
            if items.isEmpty { Text("El soundboard está vacío.").foregroundStyle(Theme.secondary) }
        }
        .task { await load() }
        .sheet(isPresented: $showLibrary) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Biblioteca de sonidos").font(.title3.bold())
                List(library, selection: $picked) { s in Text(s.name).tag(s.filename) }
                    .frame(width: 420, height: 380)
                HStack {
                    Text("\(picked.count) elegidos").font(.caption)
                    Spacer()
                    Button("Cancelar") { showLibrary = false }
                    Button("Agregar al soundboard") { importPicked() }.buttonStyle(.borderedProminent).disabled(picked.isEmpty)
                }
            }
            .padding(18)
        }
    }

    private func load() async {
        do { items = try await api.sounds(slug) } catch { self.error = error.localizedDescription }
    }
    private func add(_ file: URL) {
        Task {
            do { items.append(try await api.addSound(slug, file: file, name: file.deletingPathExtension().lastPathComponent)) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func save(_ id: Int, _ fields: [String: Any]) {
        saver.run("\(id)-\(fields.keys.sorted().joined())") {
            do { try await api.updateSound(slug, id, fields) } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ id: Int) {
        Task { do { try await api.deleteSound(slug, id); items.removeAll { $0.id == id } } catch { self.error = error.localizedDescription } }
    }
    private func play(_ s: SoundItem) {
        guard let u = s.url else { return }
        Task {
            if let d = try? await api.media(u) { player = try? AVAudioPlayer(data: d); player?.play() }
        }
    }
    private func openLibrary() {
        Task {
            do { library = try await api.soundLibrary(); picked = []; showLibrary = true } catch { self.error = error.localizedDescription }
        }
    }
    private func importPicked() {
        let files = Array(picked); showLibrary = false
        Task { do { try await api.importSounds(slug, files); await load() } catch { self.error = error.localizedDescription } }
    }
}

// MARK: Distribución

private struct DistributionTab: View {
    let slug: String
    @State private var info: DistributionInfo?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ErrorLine(text: error)
            if let info {
                if let feed = info.feedUrl {
                    Card {
                        Text("Feed de tu podcast").font(.headline)
                        Text("Es la dirección que Spotify y Apple Podcasts leen para mostrar tus episodios.").font(.caption).foregroundStyle(Theme.secondary)
                        HStack {
                            Text(feed).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button("Copiar") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(feed, forType: .string) }
                        }
                    }
                }
                if let v = info.validation, !(v.issues.isEmpty && v.warnings.isEmpty) {
                    Card {
                        Text(v.valid ? String(localized: "Casi listo") : String(localized: "Falta para poder publicar")).font(.headline)
                        ForEach(v.issues, id: \.self) { Label($0, systemImage: "xmark.circle.fill").foregroundStyle(.orange) }
                        ForEach(v.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.secondary) }
                    }
                }
                ForEach(["spotify", "apple", "youtube"], id: \.self) { key in
                    if let p = info.platforms[key] { PlatformCard(slug: slug, platform: p) { Task { await load() } } }
                }
            } else { ProgressView() }
        }
        .task { await load() }
    }

    private func load() async {
        do { info = try await api.distribution(slug) } catch { self.error = error.localizedDescription }
    }
}

private struct PlatformCard: View {
    let slug: String
    @State var platform: DistributionInfo.Platform
    let reload: () -> Void
    @State private var error: String?

    var body: some View {
        Card {
            HStack {
                Text(platform.name ?? platform.platform.capitalized).font(.headline)
                Spacer()
                Picker("", selection: $platform.status) {
                    Text("Sin configurar").tag("not_configured")
                    Text("Enviado, esperando").tag("pending")
                    Text("Conectado").tag("connected")
                }
                .labelsHidden().frame(width: 200)
            }
            if let h = platform.help, !h.isEmpty { Text(h).font(.caption).foregroundStyle(Theme.secondary) }
            HStack {
                TextField("Link de tu podcast en \(platform.name ?? platform.platform)", text: Binding(get: { platform.externalUrl ?? "" },
                                                                                                  set: { platform.externalUrl = $0 }))
                Button("Guardar") { save() }
                if let s = platform.submitUrl, let u = URL(string: s) { Link("Ir a darlo de alta", destination: u) }
            }
            ErrorLine(text: error)
        }
    }

    private func save() {
        Task {
            do { try await api.setDistribution(slug, platform: platform.platform, status: platform.status, url: platform.externalUrl ?? ""); reload() }
            catch { self.error = error.localizedDescription }
        }
    }
}


/// Reporte para el sponsor: en qué episodios salió (o va a salir), cuántas menciones y minutos al aire.
/// Igual que en prePod web; se guarda como .csv para mandárselo.
private struct SponsorReportSheet: View {
    let slug: String
    let sponsor: Sponsor2
    let onClose: () -> Void
    @State private var report: [String: Any]?
    @State private var error: String?

    private var totals: [String: Any] { report?["totals"] as? [String: Any] ?? [:] }
    private var rows: [[String: Any]] { report?["episodes"] as? [[String: Any]] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reporte de \(sponsor.name)").font(.title2.bold())
            ErrorLine(text: error)
            if report == nil && error == nil { ProgressView() }
            if report != nil {
                HStack(spacing: 22) {
                    stat("\(totals["episodes"] as? Int ?? 0)", "episodios")
                    stat("\(totals["blocks"] as? Int ?? 0)", "menciones")
                    stat(String(format: "%.1f", (totals["duration_minutes_estimated"] as? Double) ?? 0), String(localized: "minutos al aire (aprox.)"))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                            HStack {
                                Text((r["episode_number"] as? Int).map { "#\($0)" } ?? "").frame(width: 40, alignment: .leading)
                                    .foregroundStyle(Theme.secondary)
                                Text(r["title"] as? String ?? "").lineLimit(1)
                                Spacer()
                                Text(r["scheduled_date"] as? String ?? "").font(.caption).foregroundStyle(Theme.secondary)
                                Text(statusName(r["status"] as? String)).font(.caption).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
                            }
                            .font(.callout)
                        }
                        if rows.isEmpty { Text("Todavía no aparece en ningún episodio.").foregroundStyle(Theme.secondary) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Button("Guardar .csv") {
                    Task {
                        do { _ = try await api.saveDownload("/api/podcasts/\(slug)/sponsors/\(sponsor.id)/report.csv",
                                                            suggestedName: "reporte-\(sponsor.name).csv") }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(report == nil)
                Spacer()
                Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .task { do { report = try await api.sponsorReport(slug, sponsor.id) } catch { self.error = error.localizedDescription } }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
        }
    }
    private func statusName(_ s: String?) -> String {
        ["idea": String(localized: "Idea"), "planned": String(localized: "Planificado"), "scheduled": String(localized: "Agendado"), "recorded": String(localized: "Grabado"),
         "editing": String(localized: "En edición"), "published": String(localized: "Publicado"), "archived": String(localized: "Archivado")][s ?? ""] ?? (s ?? "")
    }
}
