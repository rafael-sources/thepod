import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Efectos de sonido

struct SoundsStep: View {
    @ObservedObject var session: ProjectSession
    @State private var previewPlayer: AVAudioPlayer?
    @State private var filter = ""

    private var library: [String] {
        session.project.sfxLibrary.filter { filter.isEmpty || name($0).localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(title: "Efectos y música",
                           subtitle: "Los efectos que ya están en postPod suenan en su momento exacto. Aquí los revisas, agregas música de intro o cierre y la mueves donde quieras.")
                HStack {
                    Text("En tu episodio").font(.headline)
                    Spacer()
                    Button { session.importSounds(placeAt: session.playheadTimeline) } label: { Label("Agregar música aquí…", systemImage: "music.note.list") }
                        .help("Elige un mp3/wav/m4a: se pone donde está el video y luego lo mueves con los botones")
                }
                if session.project.audioLane.isEmpty {
                    Card {
                        Label("Este episodio no tiene efectos puestos en postPod", systemImage: "speaker.slash")
                        Text("Los sonidos que se tocan en vivo en prodPod, o que pones en la línea de audio de postPod, llegan aquí solos en su momento. Si los agregas en la web, usa “Traer de nuevo”.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("\(session.project.audioLane.count) \(session.project.audioLane.count == 1 ? "sonido" : "sonidos"). Toca la hora para oírlo; “Editar” abre volumen, fades y posición bajo el video.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(session.project.audioLane) { clip in
                                let sel = session.selectedTrack == .sound(clip.id)
                                HStack {
                                    Button(EditEngine.clock(clip.tlStart)) { session.seek(timeline: max(0, clip.tlStart - 2)); session.player.play() }
                                        .buttonStyle(.link).monospacedDigit()
                                    Text(session.project.mediaItem(clip.mediaId).map { (($0.originalName as NSString).deletingPathExtension) } ?? "Sonido").lineLimit(1)
                                    Spacer()
                                    if clip.volume == 0 { Image(systemName: "speaker.slash.fill").foregroundStyle(Theme.secondary) }
                                    Text("\(Int(clip.volume * 100)) %").font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
                                    Button(sel ? "Editando…" : "Editar") { session.selectedTrack = sel ? nil : .sound(clip.id) }
                                        .controlSize(.small)
                                        .help("Volumen, fades y posición en el panel bajo el video")
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
                                .contentShape(Rectangle())
                                .onTapGesture { session.selectedTrack = .sound(clip.id) }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }

                if !session.project.sfxLibrary.isEmpty {
                    DisclosureGroup("Agregar otro efecto") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pon el video donde lo quieres, elige un sonido y toca “Poner aquí”.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                            TextField("Buscar sonido…", text: $filter).textFieldStyle(.roundedBorder)
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                    ForEach(library, id: \.self) { rel in
                                        VStack(spacing: 8) {
                                            Text(name(rel)).font(.callout.bold()).lineLimit(1)
                                            HStack(spacing: 6) {
                                                Button { preview(rel) } label: { Image(systemName: "play.fill") }
                                                    .help("Escuchar")
                                                Button("Poner aquí") {
                                                    let t = session.playheadTimeline
                                                    Task { await session.addSound(rel, at: t) }
                                                }
                                                .buttonStyle(.borderedProminent)
                                            }
                                            .controlSize(.small)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                                    }
                                }
                            }
                            .frame(maxHeight: 260)
                        }
                        .padding(.top, 6)
                    }
                    .font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 28).padding(.vertical, 28)
            .frame(minWidth: 460, maxWidth: 560)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { session.setPreview(format: .landscape) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                for p in providers {
                    guard let url = try? await p.loadFileURL(),
                          ["mp3", "wav", "m4a", "aac"].contains(url.pathExtension.lowercased()) else { continue }
                    let dest = ProjectStore.folder(for: session.project.id).appendingPathComponent("sfx", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    let to = dest.appendingPathComponent(url.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: url, to: to) }
                    await MainActor.run {
                        let rel = "sfx/\(url.lastPathComponent)"
                        if !session.project.sfxLibrary.contains(rel) { session.project.sfxLibrary.insert(rel, at: 0) }
                    }
                }
            }
            return true
        }
    }

    private func name(_ rel: String) -> String {
        if let n = session.project.sfxNames[rel] { return n }
        return ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func preview(_ rel: String) {
        previewPlayer?.stop()
        previewPlayer = try? AVAudioPlayer(contentsOf: ProjectStore.url(rel, in: session.project.id))
        previewPlayer?.play()
    }
}

// MARK: - Publicar

struct PublishStep: View {
    @ObservedObject var session: ProjectSession
    @State private var podcasts: [PrePodClient.PodcastRef] = []
    @State private var episodes: [PrePodClient.EpisodeRef] = []
    @State private var pickSlug = ""
    @State private var pickEpisode = 0
    @State private var ytTitle = ""
    @State private var ytDescription = ""
    @State private var privacy = "unlisted"
    @State private var loadError: String?

    var linked: Bool { session.project.episode.prepodSlug != nil && session.project.episode.prepodEpisodeId != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StepHeader(title: "Publicar", subtitle: "Usa lo que ya tienes configurado en prePod: el feed para Spotify y Apple Podcasts, y tu canal de YouTube.")
                if !PrePodClient.isConfigured {
                    Card {
                        Label("Conecta la app con prePod", systemImage: "person.badge.key").font(.headline)
                        Text("Abre Ajustes (⌘,) y escribe la dirección de prePod, tu usuario y tu contraseña.")
                            .foregroundStyle(Theme.secondary)
                        SettingsLink { Text("Abrir Ajustes") }.buttonStyle(.borderedProminent)
                    }
                } else if !linked {
                    linkCard
                } else {
                    statusCard
                    audioCard
                    youtubeCard
                }
                if let n = session.publishNote ?? loadError {
                    Label(n, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear {
            session.loadPublishStatus()
            if ytTitle.isEmpty { ytTitle = Exporter.episodeTitle(session.project) }
            if ytDescription.isEmpty {
                let keep = EditEngine.keepRanges(duration: session.project.duration, cuts: session.project.cuts)
                ytDescription = Exporter.notes(project: session.project, keep: keep)
            }
            if !linked && PrePodClient.isConfigured { loadPodcasts() }
        }
    }

    // Episode not linked (came straight from prodPod or loose files): pick it from prePod.
    private var linkCard: some View {
        Card {
            Label("¿A qué episodio de prePod corresponde?", systemImage: "link").font(.headline)
            Text("Este paquete no dice de qué episodio de prePod viene. Elígelo una vez y queda guardado.")
                .font(.caption).foregroundStyle(Theme.secondary)
            Picker("Podcast", selection: $pickSlug) {
                Text("Elige…").tag("")
                ForEach(podcasts) { Text($0.name).tag($0.slug) }
            }
            .onChange(of: pickSlug) { _, slug in loadEpisodes(slug) }
            Picker("Episodio", selection: $pickEpisode) {
                Text("Elige…").tag(0)
                ForEach(episodes) { Text($0.label).tag($0.id) }
            }
            .disabled(episodes.isEmpty)
            Button("Vincular") {
                session.project.episode.prepodSlug = pickSlug
                session.project.episode.prepodEpisodeId = pickEpisode
                session.loadPublishStatus()
            }
            .buttonStyle(.borderedProminent)
            .disabled(pickSlug.isEmpty || pickEpisode == 0)
        }
    }

    private var statusCard: some View {
        Card {
            HStack {
                Text("Estado en prePod").font(.headline)
                Spacer()
                Button { session.loadPublishStatus() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            if let s = session.publishStatus {
                if let ep = s.episode {
                    Text("\(ep.number.map { "Ep \($0) · " } ?? "")\(ep.title ?? "") — \(ep.status ?? "")").foregroundStyle(Theme.secondary)
                }
                ForEach(s.distribution, id: \.platform) { p in
                    HStack {
                        Image(systemName: p.status == "connected" ? "checkmark.circle.fill" : p.status == "pending" ? "clock" : "circle")
                            .foregroundStyle(p.status == "connected" ? Theme.good : Theme.secondary)
                        Text(platformName(p.platform)).bold()
                        Text(statusName(p.status)).foregroundStyle(Theme.secondary)
                        Spacer()
                        if let u = p.external_url, let url = URL(string: u) { Link("Abrir", destination: url) }
                    }
                }
                if !s.hosting_configured {
                    Label("Tu podcast todavía no está configurado para publicar en prePod. Hazlo allí una vez y vuelve.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var audioCard: some View {
        Card {
            Label("Spotify y Apple Podcasts", systemImage: "waveform").font(.headline)
            Text("Publica el episodio en tu podcast. Spotify y Apple Podcasts lo muestran solos en unos minutos u horas.")
                .font(.caption).foregroundStyle(Theme.secondary)
            if let u = session.project.episode.publishedAudioURL ?? session.publishStatus?.episode?.media_url {
                Label("Publicado: \(u)", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Theme.good).lineLimit(1)
            }
            HStack {
                Button { session.publishAudio() } label: { Label("Publicar audio", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || session.publishStatus?.hosting_configured == false)
                if let f = session.latestExport(suffix: "audio", ext: "mp3") {
                    Text("Usará \(f.lastPathComponent)").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                } else {
                    Text("Primero exportaremos el MP3").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private var youtubeCard: some View {
        Card {
            Label("YouTube", systemImage: "play.rectangle.fill").font(.headline)
            if let yt = session.publishStatus?.youtube, !yt.connected {
                Text("Tu canal no está conectado en prePod. Conéctalo allí una vez (Distribución → YouTube) y vuelve.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let yt = session.publishStatus?.youtube {
                Text("Canal: \(yt.channel_name)").font(.caption).foregroundStyle(Theme.secondary)
            }
            TextField("Título", text: $ytTitle).textFieldStyle(.roundedBorder)
            TextEditor(text: $ytDescription)
                .font(.callout)
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
            Picker("Visibilidad", selection: $privacy) {
                Text("Oculto (con link)").tag("unlisted")
                Text("Público").tag("public")
                Text("Privado").tag("private")
            }
            .pickerStyle(.segmented)
            if let u = session.project.episode.publishedYouTubeURL, let url = URL(string: u) {
                Link("Ver en YouTube: \(u)", destination: url).font(.caption)
            }
            HStack {
                Button { session.publishYouTube(title: ytTitle, description: ytDescription, privacy: privacy) } label: {
                    Label("Subir a YouTube", systemImage: "icloud.and.arrow.up.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isBusy || ytTitle.isEmpty || session.publishStatus?.youtube.connected == false)
                if let f = session.latestExport(suffix: "youtube", ext: "mp4") {
                    Text("Usará \(f.lastPathComponent)").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                } else {
                    Text("Primero exportaremos el video 16:9").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func platformName(_ p: String) -> String {
        ["spotify": "Spotify", "apple": "Apple Podcasts", "youtube": "YouTube"][p] ?? p.capitalized
    }
    private func statusName(_ s: String) -> String {
        ["connected": "conectado", "pending": "en revisión", "not_configured": "sin configurar"][s] ?? s
    }

    private func loadPodcasts() {
        Task {
            do { podcasts = try await PrePodClient.shared.podcasts(); loadError = nil }
            catch { loadError = error.localizedDescription }
        }
    }
    private func loadEpisodes(_ slug: String) {
        episodes = []
        pickEpisode = 0
        guard !slug.isEmpty else { return }
        Task {
            do { episodes = try await PrePodClient.shared.episodes(slug: slug); loadError = nil }
            catch { loadError = error.localizedDescription }
        }
    }
}

// MARK: - Ajustes: prePod

struct PrePodSettingsSection: View {
    @State private var url = PrePodClient.baseURL
    @State private var postURL = PostPodWebClient.baseURL
    @State private var user = PrePodClient.username
    @State private var password = Keychain.get("prepod-password") ?? ""
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        Section("Tu cuenta de prePod / postPod") {
            TextField("Dirección de prePod", text: $url)
            TextField("Dirección de postPod", text: $postURL)
            TextField("Usuario", text: $user)
            SecureField("Contraseña", text: $password)
            HStack {
                Button("Guardar y probar") {
                    PrePodClient.baseURL = url
                    PostPodWebClient.baseURL = postURL
                    PrePodClient.username = user
                    Keychain.set(password, for: "prepod-password")
                    Task {
                        await PrePodClient.shared.resetSession()
                        await PostPodWebClient.shared.resetSession()
                        do {
                            let list = try await PrePodClient.shared.podcasts()
                            let web = try await PostPodWebClient.shared.projects()
                            ok = true
                            result = "Conectado: \(list.count) podcast\(list.count == 1 ? "" : "s") · \(web.count) proyecto\(web.count == 1 ? "" : "s") en postPod"
                        } catch {
                            ok = false
                            result = error.localizedDescription
                        }
                    }
                }
                if let result { Text(result).font(.caption).foregroundStyle(ok ? Theme.good : .orange) }
            }
            Text("La contraseña queda guardada en esta Mac, solo para tu usuario.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
