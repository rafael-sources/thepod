import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct JobState: Equatable {
    var title: String
    var detail: String = ""
    var fraction: Double? = nil      // nil = indeterminate
}

enum AppSection: String { case pre, prod, post, ama }

@MainActor
final class AppModel: ObservableObject {
    /// Sección de thePod que se está usando (pre · post); se recuerda entre aperturas.
    @Published var section: AppSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "seccion") ?? "") ?? .post {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "seccion") }
    }
    /// Sala de prodPod que se pidió abrir desde pre ("Ir a grabar").
    @Published var prodRequest: Int?
    /// La sala abierta en prod (sigue conectada aunque cambies a pre o post).
    @Published var studio: ProdStudio?
    /// Cuarto de control abierto (director).
    @Published var director: DirectorStudio?
    /// Evento de amaPod abierto (preguntas del público).
    @Published var ama: AmaStudio?
    @Published var projects: [Project] = []
    @Published var session: ProjectSession?
    @Published var importJob: JobState?
    @Published var errorMessage: String?
    /// true cuando terminó la entrada de thePod (o está apagada): recién ahí se consulta la cuenta.
    @Published var introDone = SelfTest.isRequested || !UserDefaults.standard.bool(forKey: "introAlAbrir", default: true)
    private var importTask: Task<Void, Never>?

    init() {
        reload()
        if !SelfTest.isRequested { Task { await ChunkUploader.shared.resumeAll() } }   // subidas de prod que quedaron a medias
    }

    func reload() { projects = ProjectStore.listProjects() }

    func open(_ project: Project) {
        session = ProjectSession(project: project, app: self)
    }

    func close() {
        session?.player.pause()
        session = nil
        reload()
    }

    func delete(_ project: Project) {
        try? ProjectStore.delete(slug: project.id)
        reload()
    }

    func importItems(_ urls: [URL]) {
        guard importJob == nil, !urls.isEmpty else { return }
        importJob = JobState(title: "Importando tu grabación", detail: "Preparando…", fraction: 0)
        importTask = Task {
            do {
                let project = try await runImport(urls)
                importJob = nil
                reload()
                open(project)
            } catch is CancellationError {
                importJob = nil
            } catch {
                importJob = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runImport(_ urls: [URL]) async throws -> Project {
        try await Importer.importItems(urls) { stage, fraction in
            Task { @MainActor in
                guard self.importJob != nil else { return }
                self.importJob = JobState(title: "Importando tu grabación", detail: stage, fraction: fraction)
            }
        }
    }

    // MARK: postPod web

    @Published var webProjects: [PostPodWebClient.WebProject] = []
    @Published var webState: WebState = .idle
    @Published var webDownloading: String?          // slug being downloaded

    enum WebState: Equatable { case idle, loading, loaded, notConfigured, failed(String) }

    func localProject(forWeb slug: String) -> Project? {
        projects.first { $0.postpodSlug == slug }
    }

    func loadWebProjects() {
        guard PrePodClient.isConfigured else { webState = .notConfigured; return }
        if webState == .loading { return }
        webState = .loading
        Task {
            do {
                webProjects = try await PostPodWebClient.shared.projects()
                webState = .loaded
            } catch {
                webState = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks postPod web to build the bundle, downloads it and imports it — the same as
    /// downloading the .zip by hand and dragging it here.
    func importFromWeb(_ web: PostPodWebClient.WebProject) {
        guard importJob == nil else { return }
        let title = "Trayendo «\(web.name)» de postPod"
        importJob = JobState(title: title, detail: "Conectando con postPod…", fraction: nil)
        webDownloading = web.slug
        importTask = Task {
            var zip: URL?
            defer {
                if let zip { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
                webDownloading = nil
            }
            do {
                let file = try await PostPodWebClient.shared.downloadBundle(slug: web.slug) { phase in
                    Task { @MainActor in
                        guard self.importJob != nil else { return }
                        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
                        switch phase {
                        case .preparing(let f):
                            self.importJob = JobState(title: title,
                                                      detail: "postPod está preparando el episodio" + (f.map { " · \(Int($0 * 100))%" } ?? "…"),
                                                      fraction: f)
                        case .downloading(let got, let total):
                            self.importJob = JobState(title: title,
                                                      detail: total > 0 ? "Descargando \(size(got)) de \(size(total))" : "Descargando \(size(got))",
                                                      fraction: total > 0 ? Double(got) / Double(total) : nil)
                        case .reconnecting:
                            self.importJob = JobState(title: title, detail: "Se cortó la conexión. Reanudando desde donde quedó…",
                                                      fraction: self.importJob?.fraction)
                        }
                    }
                }
                zip = file
                try Task.checkCancellation()
                importJob = JobState(title: "Importando tu grabación", detail: "Preparando…", fraction: 0)
                var project = try await runImport([file])
                project.postpodSlug = web.slug
                importJob = JobState(title: "Importando tu grabación", detail: "Buscando el fondo y el logo del podcast en prePod…", fraction: 1)
                _ = await Importer.fetchBrandingFromPrepod(&project)
                try? ProjectStore.save(project)
                importJob = nil
                reload()
                open(project)
            } catch is CancellationError {
                importJob = nil
            } catch let e as URLError where e.code == .cancelled {
                importJob = nil
            } catch {
                importJob = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importJob = nil
    }
}

enum Step: String, CaseIterable, Identifiable {
    case overview, fix, captions, look, sounds, brands, reels, export, publish
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Grabación"
        case .fix: return "Limpiar sonido"
        case .captions: return "Subtítulos"
        case .look: return "Aspecto"
        case .sounds: return "Música y efectos"
        case .brands: return "Patrocinios y marcas"
        case .reels: return "Reels"
        case .export: return "Exportar video"
        case .publish: return "Publicar"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "person.2.wave.2"
        case .fix: return "wand.and.stars"
        case .captions: return "captions.bubble"
        case .look: return "rectangle.3.group"
        case .sounds: return "music.note"
        case .brands: return "tag"
        case .reels: return "iphone.gen3"
        case .export: return "square.and.arrow.up"
        case .publish: return "paperplane"
        }
    }
    /// Bloques de la barra lateral: Preparar y Armar son de ida y vuelta; Entregar va en orden.
    enum Group: String, CaseIterable { case prepare = "PREPARAR", build = "ARMAR", deliver = "ENTREGAR" }
    var group: Group {
        switch self {
        case .overview, .fix, .captions: return .prepare
        case .look, .sounds, .brands: return .build
        case .reels, .export, .publish: return .deliver
        }
    }
    var number: Int { (Step.allCases.firstIndex(of: self) ?? 0) + 1 }
}

@MainActor
final class ProjectSession: ObservableObject {
    @Published var project: Project { didSet { if project != oldValue { dirty() } } }
    /// Pista elegida en el timeline (o en la lista de sonidos): se edita en el panel bajo el video.
    enum TrackSel: Equatable { case lane(Int), sound(Int) }
    @Published var selectedTrack: TrackSel?
    @Published var step: Step = .overview
    @Published var job: JobState?
    @Published var errorMessage: String?
    @Published var previewFormat: ExportFormat = .landscape
    @Published var previewWindow: EditEngine.Span?
    @Published var previewLayout: LayoutTemplate?
    @Published var lastExports: [URL] = []
    @Published var fixSummary: String?
    @Published var reelsNote: String?
    @Published private(set) var built: BuiltComposition?

    let player = AVPlayer()
    weak var app: AppModel?
    var energy: EnergyMap?
    private var jobTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(project: Project, app: AppModel) {
        self.project = project
        self.app = app
        self.energy = AudioAnalysis.loadEnergy(project.id)
        if project.fix.lastRun != nil { step = .captions }
        refreshExports()
        schedulePreview(immediate: true)
        // Proyectos traídos antes de que la app bajara el fondo de prePod: completarlos una sola vez.
        if project.backgroundFile == nil || project.logoFile == nil || project.sponsors.isEmpty || project.segments.isEmpty { fetchBranding() }
        // Sin el análisis de audio la vista previa no sabe quién habla (siempre saldría la primera persona en grande):
        // calcularlo al abrir si hay más de una persona.
        if energy == nil, project.lanes.count > 1 {
            run("Analizando quién habla") { [self] in
                try await ensureEnergy()
                schedulePreview(immediate: true)
            }
        }
    }

    /// Busca en prePod el fondo y el logo del podcast (si el proyecto no los tiene).
    func fetchBranding() {
        brandingStatus = "Buscando en prePod el fondo, el logo, los sponsors y el guion…"
        Task { [weak self] in
            guard let self else { return }
            var p = project
            let ok = await Importer.fetchBrandingFromPrepod(&p)
            if ok {
                project.backgroundFile = p.backgroundFile
                project.logoFile = p.logoFile
                project.episode.prepodSlug = p.episode.prepodSlug
                project.episode.prepodEpisodeId = p.episode.prepodEpisodeId
                if project.sponsors.isEmpty { project.sponsors = p.sponsors }
                if project.segments.isEmpty { project.segments = p.segments }
                if project.podcastName == nil { project.podcastName = p.podcastName }
                brandingStatus = nil
            } else {
                brandingStatus = project.backgroundFile == nil ? "No encontré el fondo en prePod. Puedes elegir una imagen aquí." : nil
            }
        }
    }
    @Published var brandingStatus: String?

    /// El usuario elige a mano la imagen de fondo (o el logo).
    func chooseBranding(kind: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = kind == "background" ? "Elige la imagen de fondo para el video" : "Elige el logo del podcast"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Importer.setBranding(&project, kind: kind, from: url); brandingStatus = nil }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Persistence & preview

    private func dirty() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? ProjectStore.save(project)
        }
        schedulePreview()
    }

    func schedulePreview(immediate: Bool = false) {
        previewTask?.cancel()
        previewTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            await rebuildPreview()
        }
    }

    func setPreview(format: ExportFormat, window: EditEngine.Span? = nil, layout: LayoutTemplate? = nil) {
        let changed = format != previewFormat || layout != previewLayout
            || window?.start != previewWindow?.start || window?.end != previewWindow?.end
        previewFormat = format
        previewWindow = window
        previewLayout = layout
        if changed { schedulePreview(immediate: true) }
    }

    private func rebuildPreview() async {
        let wasPlaying = player.rate > 0
        let current = player.currentTime().seconds - (built?.introDuration ?? 0)
        let oldKeep = built?.keep
        do {
            let b = try await CompositionBuilder.build(project: project, format: previewFormat == .audio ? .landscape : previewFormat,
                                                       window: previewWindow, energy: energy, layoutOverride: previewLayout)
            guard !Task.isCancelled else { return }
            built = b
            player.replaceCurrentItem(with: b.playerItem())
            var target = 0.0
            if let oldKeep, current.isFinite, current > 0 {
                let tl = EditEngine.toTimeline(current, keep: oldKeep)
                target = (EditEngine.toOutput(tl, keep: b.keep) ?? min(current, b.duration)) + b.introDuration
            }
            if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if wasPlaying { player.play() }
        } catch {
            built = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Corta a mano un trozo marcado en la línea de tiempo (tiempo del episodio). Se puede deshacer en la lista de cortes.
    func cutRange(_ start: Double, _ end: Double) {
        let a = max(0, min(start, end)), b = min(project.duration, max(start, end))
        guard b - a > 0.05 else { return }
        player.pause()
        project.cuts.append(Cut(start: a, end: b, kind: .manual, label: "Cortado a mano"))
    }

    /// Seek preview to a TIMELINE time.
    func seek(timeline t: Double, play: Bool = true) {
        guard let b = built else { return }
        let o = (EditEngine.toOutput(t, keep: b.keep)
            ?? b.keep.firstIndex { $0.start >= t }.map { i in EditEngine.outputDuration(Array(b.keep.prefix(i))) }
            ?? 0) + b.introDuration
        player.seek(to: CMTime(seconds: o, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if play { player.play() }
    }

    func refreshExports() {
        let folder = ProjectStore.exportsFolder(for: project.id)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        lastExports = files.filter { ["mp4", "mp3", "m4a", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    // MARK: Jobs

    var isBusy: Bool { job != nil }

    private func run(_ title: String, _ work: @escaping () async throws -> Void) {
        guard job == nil else { return }
        job = JobState(title: title)
        jobTask = Task {
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            job = nil
        }
    }

    func cancelJob() { jobTask?.cancel() }

    private func report(_ title: String, _ detail: String = "", _ fraction: Double? = nil) {
        job = JobState(title: title, detail: detail, fraction: fraction)
    }

    private nonisolated func reportAsync(_ title: String, _ detail: String, _ fraction: Double?) {
        Task { @MainActor in self.job = JobState(title: title, detail: detail, fraction: fraction) }
    }

    // MARK: Steps

    /// The one-button fix: better audio → transcript → remove silences & filler sounds.
    func fixEverything() {
        run("Arreglando tu episodio") { [self] in try await performFix() }
    }

    func performFix() async throws {
            let settings = project.fix
            if settings.enhanceAudio { try await enhanceAudio() }
            try await transcribeMissing()
            if energy == nil || settings.removeSilences { try await ensureEnergy() }

            var p = project
            p.cuts.removeAll { $0.kind == .silence || $0.kind == .filler }
            var silences: [Cut] = []
            var fillers: [Cut] = []
            if settings.removeSilences {
                if !p.words.isEmpty {
                    silences = EditEngine.silenceCuts(words: p.words, duration: p.duration, minGap: settings.minSilence, pad: settings.keepPad)
                    if let energy {
                        silences = EditEngine.protectSpeech(silences, energy: energy.combined, hop: EnergyMap.hop, pad: settings.keepPad)
                    }
                } else if let energy {
                    silences = EditEngine.silenceCuts(energy: energy.combined, hop: EnergyMap.hop, minGap: settings.minSilence, pad: settings.keepPad)
                }
            }
            if settings.removeFillers, !p.words.isEmpty {
                fillers = EditEngine.fillerCuts(words: p.words, includeWordFillers: settings.removeWordFillers)
            }
            p.cuts += silences + fillers
            p.fix.lastRun = Date()
            project = p

            let saved = silences.reduce(0) { $0 + $1.length } + fillers.reduce(0) { $0 + $1.length }
            var parts: [String] = []
            if settings.removeSilences { parts.append("\(silences.count) silencios") }
            if settings.removeFillers { parts.append("\(fillers.count) muletillas") }
            fixSummary = "Listo. Quitamos \(parts.joined(separator: " y ")) — tu episodio ahora dura \(EditEngine.clock(p.duration - saved)) (antes \(EditEngine.clock(p.duration)))."
                + (settings.enhanceAudio ? " El audio quedó con sonido de estudio." : "")
    }

    func undoFix() {
        project.cuts.removeAll { $0.kind == .silence || $0.kind == .filler }
        project.fix.lastRun = nil
        fixSummary = nil
    }

    func transcribe() {
        run("Escribiendo la transcripción") { [self] in try await transcribeMissing() }
    }

    private func enhanceAudio() async throws {
        let ids = Set(project.lanes.flatMap { $0.clips.map(\.mediaId) })
        // Redo anything whose enhanced file is missing on disk (deleted, or an interrupted run).
        for i in project.media.indices {
            if let rel = project.media[i].enhancedAudioFile,
               !FileManager.default.fileExists(atPath: ProjectStore.url(rel, in: project.id).path) {
                project.media[i].enhancedAudioFile = nil
            }
        }
        let items = project.media.filter { ids.contains($0.id) && $0.hasAudio && $0.enhancedAudioFile == nil }
        for (i, m) in items.enumerated() {
            let who = project.lanes.first { $0.clips.contains { $0.mediaId == m.id } }.map { project.laneName($0.id) } ?? m.originalName
            report("Mejorando el audio", "Voz de \(who) (\(i + 1) de \(items.count))", 0)
            let rel = try await AudioAnalysis.enhance(media: m, slug: project.id) { [weak self] f in
                self?.reportAsync("Mejorando el audio", "Voz de \(who) (\(i + 1) de \(items.count))", f)
            }
            if let idx = project.media.firstIndex(where: { $0.id == m.id }) { project.media[idx].enhancedAudioFile = rel }
        }
        if project.media.contains(where: { $0.enhancedAudioFile != nil }) { project.enhanceAudio = true }
    }

    private func transcribeMissing() async throws {
        let lanes = project.lanes.filter { !project.transcribedLanes.contains($0.id) }
        guard !lanes.isEmpty else { return }
        var newWords: [Word] = []
        for (i, lane) in lanes.enumerated() {
            let who = project.laneName(lane.id)
            let label = "\(who) (\(i + 1) de \(lanes.count))"
            for placed in lane.placed {
                guard let media = project.mediaItem(placed.clip.mediaId), media.hasAudio else { continue }
                report("Escribiendo la transcripción", "Preparando audio de \(label)", nil)
                let wav = try await AudioAnalysis.whisperAudio(media: media, slug: project.id) { _ in }
                let words = try await Transcriber.shared.transcribe(
                    wav: wav, language: project.language,
                    status: { [weak self] s in self?.reportAsync("Escribiendo la transcripción", "\(s) — \(label)", nil) },
                    progress: { [weak self] f in self?.reportAsync("Escribiendo la transcripción", "Escuchando a \(label)", f) })
                let offset = placed.tlStart - placed.clip.srcIn
                for w in words where w.s >= placed.clip.srcIn - 0.01 && w.e <= placed.clip.srcOut + 0.01 {
                    newWords.append(Word(w: w.w, s: w.s + offset, e: w.e + offset, p: w.p, lane: lane.id))
                }
            }
            project.transcribedLanes.append(lane.id)
        }
        project.words = Transcripts.merge(project.words + newWords)
    }

    private func ensureEnergy() async throws {
        guard energy == nil else { return }
        report("Analizando quién habla", "", 0)
        energy = try await AudioAnalysis.computeEnergy(project: project) { [weak self] f in
            self?.reportAsync("Analizando quién habla", "", f)
        }
    }

    func suggestReels() {
        run("Buscando los mejores momentos") { [self] in try await performSuggest() }
    }

    func performSuggest() async throws {
            if project.words.isEmpty { try await transcribeMissing() }
            try await ensureEnergy()
            report("Buscando los mejores momentos", Keychain.apiKey == nil ? "Análisis automático" : "Preguntándole a Claude…", nil)
            let result = try await ClipSuggester.suggest(project: project)
            project.reels = result.clips.map { Reel(title: $0.title, reason: $0.reason, start: $0.start, end: $0.end) }
            if let s = result.summary { project.aiSummary = s }
            reelsNote = result.clips.isEmpty
                ? "No encontramos momentos claros. Prueba primero con “Arreglar” para tener la transcripción."
                : (result.usedAI ? "Claude eligió \(result.clips.count) momentos." : "Elegimos \(result.clips.count) momentos automáticamente. Con una clave de Claude en Ajustes la selección es mucho más inteligente.")
    }

    func export(format: ExportFormat) {
        run("Exportando") { [self] in
            let url = try await performExport(format: format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func performExport(format: ExportFormat) async throws -> URL {
            try await ensureEnergy()
            player.pause()
            report("Exportando \(format.title)", "", 0)
            let url = try await Exporter.export(project: project, format: format, energy: energy) { [weak self] f in
                self?.reportAsync("Exportando \(format.title)", "", f)
            }
            refreshExports()
            return url
    }

    func exportReels() {
        let reels = project.reels.filter(\.selected)
        guard !reels.isEmpty else { return }
        run("Exportando reels") { [self] in
            let urls = try await performExportReels()
            if let last = urls.last { NSWorkspace.shared.activateFileViewerSelecting([last]) }
        }
    }

    @discardableResult
    func performExportReels() async throws -> [URL] {
            let reels = project.reels.filter(\.selected)
            try await ensureEnergy()
            player.pause()
            var urls: [URL] = []
            for (i, reel) in reels.enumerated() {
                let label = "Reel \(i + 1) de \(reels.count): \(reel.title)"
                report("Exportando reels", label, 0)
                let url = try await Exporter.export(project: project, format: .vertical, window: (reel.start, reel.end),
                                                    baseName: "reel-\(i + 1)-\(reel.title)", energy: energy,
                                                    layout: project.reelLayout) { [weak self] f in
                    self?.reportAsync("Exportando reels", label, f)
                }
                if let idx = project.reels.firstIndex(where: { $0.id == reel.id }) {
                    project.reels[idx].exportedFile = url.lastPathComponent
                }
                urls.append(url)
            }
            refreshExports()
            return urls
    }

    // MARK: Intro y cierre

    func setBumper(isIntro: Bool, _ b: Bumper?) {
        if isIntro { project.intro = b } else { project.outro = b }
    }
    func chooseBumperImage(isIntro: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = isIntro ? "Elige la imagen del intro" : "Elige la imagen del cierre"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rel = "branding/\(isIntro ? "intro" : "outro").\(url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        var b = (isIntro ? project.intro : project.outro) ?? Bumper(imageFile: rel)
        b.imageFile = rel
        setBumper(isIntro: isIntro, b)
    }
    func chooseBumperMusic(isIntro: Bool) {
        guard var b = isIntro ? project.intro : project.outro else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Elige la música del \(isIntro ? "intro" : "cierre")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dest = ProjectStore.folder(for: project.id).appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let to = dest.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: url, to: to) }
        b.musicFile = "sfx/\(url.lastPathComponent)"
        setBumper(isIntro: isIntro, b)
    }

    // MARK: Sincronizar personas

    /// Mueve el inicio de la grabación de una persona (desfase). Arrastra con ella sus palabras transcritas
    /// y vuelve a calcular quién habla.
    func setLaneOffset(_ laneId: Int, _ newOffset: Double) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        let delta = max(0, newOffset) - project.lanes[i].offset
        guard abs(delta) > 0.0005 else { return }
        var p = project
        p.lanes[i].offset = max(0, newOffset)
        for w in p.words.indices where p.words[w].lane == laneId {
            p.words[w].s = max(0, p.words[w].s + delta)
            p.words[w].e = max(0, p.words[w].e + delta)
        }
        project = p
        try? FileManager.default.removeItem(at: AudioAnalysis.energyURL(project.id))
        energy = nil
        if project.lanes.count > 1 {
            run("Analizando quién habla") { [self] in
                try await ensureEnergy()
                schedulePreview(immediate: true)
            }
        }
    }

    // MARK: Música y efectos

    /// Mueve un sonido/música de la línea de audio a otro punto del episodio.
    func moveSound(_ clipId: Int, to timeline: Double) {
        guard let i = project.audioLane.firstIndex(where: { $0.id == clipId }) else { return }
        project.audioLane[i].tlStart = min(max(0, timeline), max(0, project.duration - 0.5))
    }

    /// El usuario elige archivos de música/efectos; se copian al proyecto y quedan en la biblioteca (y si se pide, puestos).
    func importSounds(placeAt: Double? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = true
        panel.message = "Elige música o efectos (mp3, wav, m4a)"
        guard panel.runModal() == .OK else { return }
        let dest = ProjectStore.folder(for: project.id).appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for url in panel.urls {
            let to = dest.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: url, to: to) }
            let rel = "sfx/\(url.lastPathComponent)"
            if !project.sfxLibrary.contains(rel) { project.sfxLibrary.insert(rel, at: 0) }
            if let placeAt { Task { await addSound(rel, at: placeAt) } }
        }
    }

    // MARK: Sound effects

    func addSound(_ rel: String, at timeline: Double) async {
        var p = project
        let mediaId: Int
        if let existing = p.media.first(where: { $0.file == rel }) {
            mediaId = existing.id
        } else {
            let url = ProjectStore.url(rel, in: p.id)
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 1
            mediaId = (p.media.map(\.id).max() ?? 0) + 1
            p.media.append(SourceMedia(id: mediaId, originalName: (rel as NSString).lastPathComponent, file: rel, kind: .audio,
                                       duration: d.isFinite ? d : 1, hasAudio: true, hasVideo: false))
        }
        let len = p.mediaItem(mediaId)?.duration ?? 1
        let id = (p.audioLane.map(\.id).max() ?? 0) + 1
        p.audioLane.append(AudioLaneClip(id: id, mediaId: mediaId, tlStart: max(0, timeline), srcIn: 0, srcOut: len, volume: 0.8))
        project = p
        selectedTrack = .sound(id)
    }

    /// Current playhead in TIMELINE time.
    /// Marca un momento donde está el video (como la tecla M en postPod web) y crea su reel.
    @discardableResult
    func markMoment() -> Reel {
        let t = playheadTimeline
        let n = project.moments.count + 1
        let id = (project.moments.map(\.id).max() ?? 0) + 1
        project.moments.append(Moment(id: id, time: t, duration: nil, label: "Momento \(n)"))
        let reel = Reel(title: "Momento \(n)", reason: "Marcado en la app", start: t, end: min(project.duration, t + 60))
        project.reels.append(reel)
        return reel
    }

    var playheadTimeline: Double {
        let t = player.currentTime().seconds
        guard let b = built, t.isFinite else { return 0 }
        return EditEngine.toTimeline(max(0, t - b.introDuration), keep: b.keep)
    }

    // MARK: Publishing (via prePod)

    @Published var publishStatus: PrePodClient.PublishStatus?
    @Published var publishNote: String?

    func latestExport(suffix: String, ext: String) -> URL? {
        refreshExports()
        return lastExports.first { $0.pathExtension == ext && $0.lastPathComponent.contains("_\(suffix)_") }
    }

    func loadPublishStatus() {
        guard let slug = project.episode.prepodSlug, let ep = project.episode.prepodEpisodeId else { return }
        Task {
            do {
                publishStatus = try await PrePodClient.shared.status(slug: slug, episodeId: ep)
                publishNote = nil
            } catch {
                publishNote = error.localizedDescription
            }
        }
    }

    func publishAudio() {
        guard let slug = project.episode.prepodSlug, let ep = project.episode.prepodEpisodeId else { return }
        run("Publicando en Spotify y Apple") { [self] in
            var file = latestExport(suffix: "audio", ext: "mp3")
            if file == nil { file = try await performExport(format: .audio) }
            guard let file else { return }
            report("Publicando en Spotify y Apple", "Subiendo el MP3 a prePod…", 0)
            let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                self?.reportAsync("Publicando en Spotify y Apple", "Subiendo el MP3 a prePod…", f)
            }
            report("Publicando en Spotify y Apple", "Poniéndolo en el feed…", nil)
            let job = try await PrePodClient.shared.publishAudio(slug: slug, episodeId: ep, uploadId: upload)
            let result = try await PrePodClient.shared.wait(job: job) { [weak self] f in
                self?.reportAsync("Publicando en Spotify y Apple", "Poniéndolo en el feed…", f)
            }
            project.episode.publishedAudioURL = result["media_url"]
            loadPublishStatus()
        }
    }

    func publishYouTube(title: String, description: String, privacy: String) {
        guard let slug = project.episode.prepodSlug, let ep = project.episode.prepodEpisodeId else { return }
        run("Subiendo a YouTube") { [self] in
            var file = latestExport(suffix: "youtube", ext: "mp4")
            if file == nil { file = try await performExport(format: .landscape) }
            guard let file else { return }
            report("Subiendo a YouTube", "Enviando el video a prePod…", 0)
            let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                self?.reportAsync("Subiendo a YouTube", "Enviando el video a prePod…", f)
            }
            report("Subiendo a YouTube", "prePod lo está subiendo a tu canal…", 0)
            let job = try await PrePodClient.shared.publishYouTube(slug: slug, episodeId: ep, uploadId: upload,
                                                                   title: title, description: description, privacy: privacy)
            let result = try await PrePodClient.shared.wait(job: job) { [weak self] f in
                self?.reportAsync("Subiendo a YouTube", "prePod lo está subiendo a tu canal…", f)
            }
            project.episode.publishedYouTubeURL = result["video_url"] ?? result["url"]
            loadPublishStatus()
        }
    }

    // MARK: Transcript editing

    struct Phrase: Identifiable, Equatable {
        var id: Int { range.lowerBound }
        var range: Swift.Range<Int>
        var start: Double
        var end: Double
        var lane: Int
        var text: String
        var isCut: Bool
    }

    func phrases() -> [Phrase] {
        let words = project.words
        guard !words.isEmpty else { return [] }
        var out: [Phrase] = []
        var startIdx = 0
        let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts)
        func close(_ end: Int) {
            guard end > startIdx else { return }
            let slice = words[startIdx..<end]
            let mid = (slice.first!.s + slice.last!.e) / 2
            out.append(Phrase(range: startIdx..<end, start: slice.first!.s, end: slice.last!.e, lane: slice.first!.lane,
                              text: slice.map(\.w).joined(separator: " "),
                              isCut: EditEngine.toOutput(mid, keep: keep) == nil))
            startIdx = end
        }
        for i in words.indices.dropFirst() {
            let prev = words[i - 1]
            let long = i - startIdx >= 18
            if words[i].lane != prev.lane || words[i].s - prev.e > 1.0 || long && ".?!,".contains(prev.w.last ?? " ") || i - startIdx >= 30 {
                close(i)
            }
        }
        close(words.count)
        return out
    }

    func updatePhrase(_ phrase: Phrase, text: String) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return }
        var words = project.words
        let old = Array(words[phrase.range])
        var replacement: [Word] = []
        if tokens.count == old.count {
            replacement = zip(old, tokens).map { var w = $0; w.w = $1; return w }
        } else {
            let span = phrase.end - phrase.start
            let step = span / Double(tokens.count)
            replacement = tokens.enumerated().map { (i, t) in
                Word(w: t, s: phrase.start + Double(i) * step, e: phrase.start + Double(i + 1) * step - 0.02, p: 1, lane: phrase.lane)
            }
        }
        words.replaceSubrange(phrase.range, with: replacement)
        project.words = words
    }

    func togglePhraseCut(_ phrase: Phrase) {
        if phrase.isCut {
            project.cuts.removeAll { $0.kind == .manual && $0.start <= phrase.start + 0.1 && $0.end >= phrase.end - 0.1 }
            for i in project.cuts.indices where project.cuts[i].start < phrase.end && project.cuts[i].end > phrase.start {
                if project.cuts[i].start >= phrase.start - 0.2 && project.cuts[i].end <= phrase.end + 0.2 { project.cuts[i].enabled = false }
            }
        } else {
            project.cuts.append(Cut(start: max(0, phrase.start - 0.05), end: phrase.end + 0.05, kind: .manual,
                                    label: "“\(phrase.text.prefix(40))…”"))
        }
    }
}

extension UserDefaults {
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) == nil ? value : bool(forKey: key)
    }
}
