import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CoreImage

struct JobState: Equatable {
    var title: String
    var detail: String = ""
    var fraction: Double? = nil      // nil = indeterminate
}

enum AppSection: String { case pre, prod, post, pub, ama }

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
        importJob = JobState(title: String(localized: "Importando tu grabación"), detail: "Preparando…", fraction: 0)
        importTask = Task {
            do {
                // Sin la app en el plan (Gratis o Web): cada grabación nueva que se importa cuenta como un episodio
                if PrePodClient.isConfigured, !Plan.includesApp {
                    if let denied = await PrePodClient.shared.claimEpisode(String(localized: "mac:\(UUID().uuidString)")) {
                        importJob = nil
                        errorMessage = denied
                        return
                    }
                    AccountRole.shared.refresh()
                }
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
                self.importJob = JobState(title: String(localized: "Importando tu grabación"), detail: stage, fraction: fraction)
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
        let title = String(localized: "Trayendo «\(web.name)» de postPod")
        importJob = JobState(title: title, detail: String(localized: "Conectando con postPod…"), fraction: nil)
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
                                                      detail: String(localized: "postPod está preparando el episodio") + (f.map { " · \(Int($0 * 100))%" } ?? "…"),
                                                      fraction: f)
                        case .downloading(let got, let total):
                            self.importJob = JobState(title: title,
                                                      detail: total > 0 ? String(localized: "Descargando \(size(got)) de \(size(total))") : String(localized: "Descargando \(size(got))"),
                                                      fraction: total > 0 ? Double(got) / Double(total) : nil)
                        case .reconnecting:
                            self.importJob = JobState(title: title, detail: String(localized: "Se cortó la conexión. Reanudando desde donde quedó…"),
                                                      fraction: self.importJob?.fraction)
                        }
                    }
                }
                zip = file
                try Task.checkCancellation()
                importJob = JobState(title: String(localized: "Importando tu grabación"), detail: "Preparando…", fraction: 0)
                var project = try await runImport([file])
                project.postpodSlug = web.slug
                importJob = JobState(title: String(localized: "Importando tu grabación"), detail: String(localized: "Buscando el fondo y el logo del podcast en prePod…"), fraction: 1)
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
    case overview, fix, captions, sensitive, look, layers, sounds, cintillos, brands, reels, cover, export, publish
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Grabación"
        case .fix: return "Limpiar sonido"
        case .captions: return "Subtítulos"
        case .sensitive: return "Palabras sensibles"
        case .look: return "Aspecto"
        case .layers: return "Textos y stickers"
        case .cintillos: return "Cintillos"
        case .sounds: return "Música y efectos"
        case .brands: return "Patrocinios y marcas"
        case .reels: return "Reels"
        case .cover: return "Portada"
        case .export: return "Exportar video"
        case .publish: return "Publicar"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "person.2.wave.2"
        case .fix: return "wand.and.stars"
        case .captions: return "captions.bubble"
        case .sensitive: return "exclamationmark.bubble"
        case .look: return "rectangle.3.group"
        case .layers: return "textformat"
        case .cintillos: return "rectangle.bottomthird.inset.filled"
        case .sounds: return "music.note"
        case .brands: return "tag"
        case .reels: return "iphone.gen3"
        case .cover: return "photo.on.rectangle.angled"
        case .export: return "square.and.arrow.up"
        case .publish: return "paperplane"
        }
    }
    /// Bloques de la barra lateral: Preparar y Armar son de ida y vuelta; Entregar va en orden.
    enum Group: String, CaseIterable { case prepare = "PREPARAR", build = "ARMAR", deliver = "ENTREGAR" }
    var group: Group {
        switch self {
        case .overview, .fix, .captions, .sensitive: return .prepare
        case .look, .layers, .sounds, .cintillos, .brands: return .build
        case .reels, .cover, .export, .publish: return .deliver
        }
    }
    var number: Int { (Step.allCases.firstIndex(of: self) ?? 0) + 1 }
}

@MainActor
final class ProjectSession: ObservableObject {
    @Published var project: Project {
        didSet {
            guard project != oldValue else { return }
            history.record(before: oldValue)
            // Solo cambió el ecualizador / voz pareja / siseo de alguien: se aplica al vuelo en la cadena de voz
            // (vista previa y export en marcha), sin rearmar la vista previa ni cortar el audio.
            if Self.onlyVoiceChainChanged(oldValue, project), !Self.pluginListChanged(oldValue, project) {
                for l in project.lanes {
                    let before = oldValue.lanes.first(where: { $0.id == l.id })
                    if l.eq != before?.eq || l.chain != before?.chain {
                        VoiceChainRegistry.shared.update(lane: l.id, l.effectiveChain)
                    }
                }
                dirty(preview: false)
            } else {
                dirty()
            }
        }
    }

    /// Cambió qué plugins hay (o su orden) en alguna persona: hay que rearmar la cadena.
    private static func pluginListChanged(_ a: Project, _ b: Project) -> Bool {
        guard a.lanes.count == b.lanes.count else { return true }
        for (x, y) in zip(a.lanes, b.lanes) where x.effectiveChain.plugins.map(\.id) != y.effectiveChain.plugins.map(\.id) { return true }
        return false
    }

    private static func onlyVoiceChainChanged(_ a: Project, _ b: Project) -> Bool {
        guard a.lanes.count == b.lanes.count else { return false }
        var c = b
        for i in c.lanes.indices { c.lanes[i].eq = a.lanes[i].eq; c.lanes[i].chain = a.lanes[i].chain }
        return c == a
    }
    let history = ProjectHistory()
    @Published var note: String?          // aviso corto (atajos, deshacer)
    private var offsetWork: Task<Void, Never>?
    var noteId = UUID()
    var inPoint: Double?                  // tecla I: inicio de un reel pendiente
    @Published var selectedVolumePoint: (lane: Int, id: UUID)?   // punto elegido de la línea de volumen (Suprimir lo quita)
    /// Pista elegida en el timeline (o en la lista de sonidos): se edita en el panel bajo el video.
    enum TrackSel: Equatable { case lane(Int), sound(Int), overlay(Int), broll(Int), reelBRoll(UUID, Int), cintillo(Int), reelSound(UUID, Int), reelCintillo(UUID, Int) }
    @Published var selectedTrack: TrackSel?
    @Published var step: Step = .overview
    @Published var job: JobState?
    @Published var errorMessage: String?
    @Published var previewFormat: ExportFormat = .landscape
    @Published var previewWindow: EditEngine.Span?
    @Published var previewLayout: LayoutTemplate?
    @Published var previewLook: ReelLook?          // viendo un reel: su diseño y marca encima del episodio
    @Published var previewReel: Reel?              // viendo un reel: sus cortes propios

    /// Título de gancho de un reel (nil = sin título).
    func setReelHook(_ reelId: UUID, _ text: String?) {
        guard let r = project.reels.firstIndex(where: { $0.id == reelId }) else { return }
        project.reels[r].hook = text
        if previewReel?.id == reelId { previewReel = project.reels[r] }
    }
    /// A quién le cambia la posición de los subtítulos al arrastrarlos sobre el video (nil = no se pueden arrastrar).
    enum CaptionTarget: Equatable { case episode, allReels, reel(UUID) }
    @Published var captionDragTarget: CaptionTarget?

    /// El estilo de subtítulos que se está viendo (según el blanco del arrastre).
    func captionStyle(for target: CaptionTarget) -> CaptionStyle {
        switch target {
        case .episode: return project.captionStyle
        case .allReels: return project.reelLook.captionStyle ?? project.captionStyle
        case .reel(let id): return project.reels.first { $0.id == id }?.look?.captionStyle ?? project.reelLook.captionStyle ?? project.captionStyle
        }
    }
    func setCaptionPosition(_ target: CaptionTarget, x: Double, y: Double) {
        let cx = min(1, max(0, x)), cy = min(1, max(0, y))
        switch target {
        case .episode:
            project.captionStyle.freeX = cx; project.captionStyle.freeY = cy
        case .allReels:
            var cs = project.reelLook.captionStyle ?? project.captionStyle
            cs.freeX = cx; cs.freeY = cy
            project.reelLook.captionStyle = cs
        case .reel(let id):
            guard let i = project.reels.firstIndex(where: { $0.id == id }) else { return }
            var l = project.reels[i].look ?? project.reelLook
            var cs = l.captionStyle ?? project.reelLook.captionStyle ?? project.captionStyle
            cs.freeX = cx; cs.freeY = cy
            l.captionStyle = cs
            project.reels[i].look = l
        }
    }
    @Published var lastExports: [URL] = []
    @Published var fixSummary: String?
    @Published var reelsNote: String?
    @Published var captionsNote: String?            // resultado de ajustar o volver a escuchar los subtítulos
    @Published private(set) var built: BuiltComposition?

    let player = AVPlayer()
    weak var app: AppModel?
    var energy: EnergyMap?
    private var jobTask: Task<Void, Never>?
    private var queueJobTask: Task<[URL], Error>?
    /// Cola de exportación (feature 15): se procesa en segundo plano, de a uno.
    @Published var exportQueue: [ExportJob] = []
    /// Proxys (copias livianas para la vista previa): qué se está preparando, o nil
    @Published var proxyStatus: String?
    private var proxyTask: Task<Void, Never>?
    var exportQueueTask: Task<Void, Never>?
    /// Solo para pruebas: reemplaza la exportación real por una función que simula cada trabajo.
    var exportQueueRunner: ((ExportJob.Kind) async throws -> [URL])?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(project: Project, app: AppModel) {
        self.project = project
        self.app = app
        self.energy = AudioAnalysis.loadEnergy(project.id)
        Self.vigilarToques()
        if project.fix.lastRun != nil { step = .captions }
        refreshExports()
        vigilarPausa()
        schedulePreview(immediate: true)
        prepareProxies()
        // Proyectos traídos antes de que la app bajara el fondo de prePod: completarlos una sola vez.
        if project.backgroundFile == nil || project.logoFile == nil || project.sponsors.isEmpty || project.segments.isEmpty { fetchBranding() }
        // Sin el análisis de audio la vista previa no sabe quién habla (siempre saldría la primera persona en grande):
        // calcularlo al abrir si hay más de una persona.
        if energy == nil, !project.lanes.isEmpty {
            run(project.lanes.count > 1 ? String(localized: "Analizando quién habla") : String(localized: "Analizando el sonido")) { [self] in
                try await ensureEnergy()
                schedulePreview(immediate: true)
            }
        }
    }

    /// Busca en prePod el fondo y el logo del podcast (si el proyecto no los tiene).
    func fetchBranding() {
        brandingStatus = String(localized: "Buscando en prePod el fondo, el logo, los sponsors y el guion…")
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
                brandingStatus = project.backgroundFile == nil ? String(localized: "No encontré el fondo en prePod. Puedes elegir una imagen aquí.") : nil
            }
        }
    }
    @Published var brandingStatus: String?

    /// El usuario elige a mano la imagen de fondo (o el logo).
    func chooseBranding(kind: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = kind == "background" ? String(localized: "Elige la imagen de fondo para el video") : String(localized: "Elige el logo del podcast")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Importer.setBranding(&project, kind: kind, from: url); brandingStatus = nil }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Persistence & preview

    private func dirty(preview: Bool = true) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? ProjectStore.save(project)
        }
        if preview { schedulePreview() }
    }

    func schedulePreview(immediate: Bool = false) {
        previewTask?.cancel()
        previewTask = Task {
            if !immediate { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            // Mientras suena, la vista previa NO se cambia por trabajos de fondo (terminar de analizar quién habla,
            // mejorar el audio, el ecualizador, guardar). Cambiarla a media reproducción reemplaza el audio en marcha
            // y en Macs más lentos se oía bajar la voz un momento, en sitios distintos cada vez. Si la persona acaba
            // de tocar algo (un volumen, un corte) sí se aplica ya; lo demás espera a la pausa.
            if player.rate > 0, !Self.tocoHaceUnMomento {
                previewPendiente = true
                return
            }
            previewPendiente = false
            await rebuildPreview()
        }
    }

    /// Hay una vista previa nueva esperando a que se pause la reproducción.
    private var previewPendiente = false
    private var observadorPausa: NSKeyValueObservation?

    /// Al pausar, se aplica la vista previa que quedó esperando.
    private func vigilarPausa() {
        observadorPausa = player.observe(\.timeControlStatus) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, player.timeControlStatus == .paused, self.previewPendiente else { return }
                self.schedulePreview(immediate: true)
            }
        }
    }

    /// La última vez que la persona usó el teclado o el ratón dentro de la app.
    nonisolated(unsafe) private static var ultimoToque: CFTimeInterval = 0
    nonisolated(unsafe) private static var monitorToques: Any?
    private static var tocoHaceUnMomento: Bool { CACurrentMediaTime() - ultimoToque < 1.5 }
    private static func vigilarToques() {
        guard monitorToques == nil else { return }
        monitorToques = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                                    .rightMouseDown, .scrollWheel]) { ev in
            ultimoToque = CACurrentMediaTime()
            return ev
        }
    }

    func setPreview(format: ExportFormat, window: EditEngine.Span? = nil, layout: LayoutTemplate? = nil, look: ReelLook? = nil, reel: Reel? = nil) {
        var reel = reel
        if reel != nil {
            reel?.seen = true       // mirado (revisión antes de exportar); igual en la copia para no reconstruir dos veces
            if let i = project.reels.firstIndex(where: { $0.id == reel?.id }), project.reels[i].seen != true {
                project.reels[i].seen = true
            }
        }
        let changed = format != previewFormat || layout != previewLayout || look != previewLook || reel != previewReel
            || window?.start != previewWindow?.start || window?.end != previewWindow?.end
        previewFormat = format
        previewWindow = window
        previewLayout = layout
        previewLook = look
        previewReel = reel
        if changed { schedulePreview(immediate: true) }
    }

    private func rebuildPreview() async {
        let wasPlaying = player.rate > 0
        let current = player.currentTime().seconds - (built?.introDuration ?? 0)
        let oldKeep = built?.keep
        do {
            let shown = previewLook.map { project.applying($0, reel: previewReel) } ?? project
            let b = try await CompositionBuilder.build(project: shown, format: previewFormat == .audio ? .landscape : previewFormat,
                                                       window: previewWindow, energy: energy, layoutOverride: previewLayout, preview: true)
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

    /// Sugerencias que la persona todavía no miró (muletillas dudosas, frases repetidas, sonidos sin palabras).
    var pendingSuggestions: [Cut] {
        project.cuts.filter { $0.suggested == true && $0.reviewed != true }.sorted { $0.start < $1.start }
    }

    /// Decide una sugerencia: quitarla (se corta) o dejarla (queda como está).
    func decide(_ id: UUID, remove: Bool) {
        guard let i = project.cuts.firstIndex(where: { $0.id == id }) else { return }
        project.cuts[i].enabled = remove
        project.cuts[i].reviewed = true
    }

    /// Todas las sugerencias pendientes de una vez.
    func decideAllPending(remove: Bool) {
        var p = project
        for i in p.cuts.indices where p.cuts[i].suggested == true && p.cuts[i].reviewed != true {
            p.cuts[i].enabled = remove
            p.cuts[i].reviewed = true
        }
        project = p
    }

    /// Corta a mano un trozo marcado en la línea de tiempo (tiempo del episodio). Se puede deshacer en la lista de cortes.
    func cutRange(_ start: Double, _ end: Double) {
        let a = max(0, min(start, end)), b = min(project.duration, max(start, end))
        guard b - a > 0.05 else { return }
        player.pause()
        project.cuts.append(Cut(start: a, end: b, kind: .manual, label: String(localized: "Cortado a mano")))
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
        let fresh = files.filter { ["mp4", "mp3", "m4a", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        // Solo avisar si cambió: si se publica en cada redibujo, las vistas que lo leen se redibujan en bucle y la app se cuelga.
        if fresh != lastExports { lastExports = fresh }
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

    func cancelJob() { jobTask?.cancel(); queueJobTask?.cancel() }

    /// La cola usa la misma barra de trabajo: mientras exporta, nada más arranca.
    func startQueueJob(title: String, task: Task<[URL], Error>) {
        job = JobState(title: title, detail: queueDetail, fraction: 0)
        queueJobTask = task
    }
    func endQueueJob() { queueJobTask = nil; job = nil }

    private func report(_ title: String, _ detail: String = "", _ fraction: Double? = nil) {
        job = JobState(title: title, detail: detail, fraction: fraction)
    }

    private nonisolated func reportAsync(_ title: String, _ detail: String, _ fraction: Double?) {
        Task { @MainActor in self.job = JobState(title: title, detail: detail, fraction: fraction) }
    }

    // MARK: Steps

    /// The one-button fix: better audio → transcript → remove silences & filler sounds.
    func fixEverything() {
        run(String(localized: "Arreglando tu episodio")) { [self] in try await performFix() }
    }

    func performFix() async throws {
            let settings = project.fix
            if settings.enhanceAudio { try await enhanceAudio() }
            try await transcribeMissing()
            // Los silencios se calculan con los tiempos de las palabras: primero que estén donde suena la voz
            if !project.wordsSynced, !project.words.isEmpty { _ = try await syncWords() }
            if energy == nil || settings.removeSilences { try await ensureEnergy() }

            var p = project
            let old = p.cuts.filter { Self.isAutoCut($0) }
            p.cuts.removeAll { Self.isAutoCut($0) }
            let (silences, fillers) = autoCuts(p)
            let fresh = EditEngine.carryDecisions(from: old, into: silences + fillers)
            p.cuts += fresh
            p.fix.lastRun = Date()
            project = p

            let on = fresh.filter(\.enabled)
            let saved = on.reduce(0) { $0 + $1.length }
            let removedFillers = on.filter { $0.kind == .filler }.count
            let pending = fresh.filter { $0.suggested == true && $0.reviewed != true }.count
            var parts: [String] = []
            if settings.removeSilences { parts.append(String(localized: "\(on.filter { $0.kind == .silence }.count) silencios")) }
            if settings.removeFillers { parts.append(String(localized: "\(removedFillers) muletillas")) }
            fixSummary = String(localized: "Listo. Quitamos \(parts.joined(separator: " y ")) — tu episodio ahora dura \(EditEngine.clock(p.duration - saved)) (antes \(EditEngine.clock(p.duration))).")
                + (settings.enhanceAudio ? String(localized: " El audio quedó con sonido de estudio.") : "")
                + (pending > 0 ? String(localized: " Te dejamos \(pending) \(pending == 1 ? "sugerencia" : "sugerencias") para revisar (muletillas dudosas y frases repetidas): no se quitan hasta que las marques.") : "")
    }

    /// Silencios y muletillas que quita "Arreglar", con los ajustes del proyecto (no los agrega).
    private func autoCuts(_ p: Project) -> (silences: [Cut], fillers: [Cut]) {
        let settings = p.fix
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
            fillers += EditEngine.repeatCuts(words: p.words)
            if let energy {
                // sonidos sin palabras que no se pisen con lo que ya se marcó
                let marked = fillers
                fillers += EditEngine.soundOnlyCuts(words: p.words, energy: energy)
                    .filter { c in !marked.contains { $0.start < c.end && $0.end > c.start } }
            }
            fillers.sort { $0.start < $1.start }
        }
        return (silences, fillers)
    }

    /// Cortes que pone «Arreglar» (se recalculan); los manuales e importados no se tocan.
    static func isAutoCut(_ c: Cut) -> Bool { c.kind == .silence || c.kind == .filler || c.kind == .repeated }

    func undoFix() {
        project.cuts.removeAll { Self.isAutoCut($0) }
        project.fix.lastRun = nil
        fixSummary = nil
    }

    func transcribe() {
        run(String(localized: "Escribiendo la transcripción")) { [self] in try await transcribeMissing() }
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
        let level = project.fix.noiseLevel
        // Si se cambió cuánto limpia, el archivo esperado es otro: se vuelve a procesar
        let items = project.media.filter { ids.contains($0.id) && $0.hasAudio && $0.enhancedAudioFile != AudioAnalysis.enhancedRel(mediaId: $0.id, level: level) }
        for (i, m) in items.enumerated() {
            let who = project.lanes.first { $0.clips.contains { $0.mediaId == m.id } }.map { project.laneName($0.id) } ?? m.originalName
            report(String(localized: "Separando la voz del ruido"), String(localized: "Voz de \(who) (\(i + 1) de \(items.count))"), 0)
            let rel = try await AudioAnalysis.enhance(media: m, slug: project.id, level: level) { [weak self] f in
                self?.reportAsync(String(localized: "Separando la voz del ruido"), String(localized: "Voz de \(who) (\(i + 1) de \(items.count))"), f)
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
                report(String(localized: "Escribiendo la transcripción"), String(localized: "Preparando audio de \(label)"), nil)
                let wav = try await AudioAnalysis.whisperAudio(media: media, slug: project.id) { _ in }
                let words = try await Transcriber.shared.transcribe(
                    wav: wav, language: project.language,
                    status: { [weak self] s in self?.reportAsync(String(localized: "Escribiendo la transcripción"), "\(s) — \(label)", nil) },
                    progress: { [weak self] f in self?.reportAsync(String(localized: "Escribiendo la transcripción"), String(localized: "Escuchando a \(label)"), f) })
                let offset = placed.tlStart - placed.clip.srcIn
                for w in words where w.s >= placed.clip.srcIn - 0.01 && w.e <= placed.clip.srcOut + 0.01 {
                    newWords.append(Word(w: w.w, s: w.s + offset, e: w.e + offset, p: w.p, lane: lane.id))
                }
            }
            project.transcribedLanes.append(lane.id)
        }
        let wasEmpty = project.words.isEmpty
        report(String(localized: "Ajustando los subtítulos al audio"), "", 0)
        newWords = try await SubtitleSync.align(newWords, project: project) { [weak self] f in
            self?.reportAsync(String(localized: "Ajustando los subtítulos al audio"), "", f)
        }.words
        project.words = Transcripts.merge(project.words + newWords)
        if wasEmpty { project.wordsSynced = true }
    }

    func ensureEnergy() async throws {
        guard energy == nil else { return }
        report(String(localized: "Analizando quién habla"), "", 0)
        energy = try await AudioAnalysis.computeEnergy(project: project) { [weak self] f in
            self?.reportAsync(String(localized: "Analizando quién habla"), "", f)
        }
    }

    func suggestReels() {
        run(String(localized: "Buscando los mejores momentos")) { [self] in try await performSuggest() }
    }

    // MARK: Notas y momentos con IA (una vez por episodio)

    @Published var askAIConsent = false
    @Published var aiNote: String?

    /// Botón «Buscar momentos con IA». La primera vez pide permiso para mandar la transcripción.
    func findMomentsWithAI(confirmed: Bool = false) {
        if !confirmed && !UserDefaults.standard.bool(forKey: "aiConsentTranscript") {
            askAIConsent = true
            return
        }
        UserDefaults.standard.set(true, forKey: "aiConsentTranscript")
        run(String(localized: "Buscando los mejores momentos con IA")) { [self] in try await performAIMoments() }
    }

    func performAIMoments() async throws {
        if project.words.isEmpty { try await transcribeMissing() }
        report(String(localized: "Buscando los mejores momentos con IA"), String(localized: "La IA está leyendo el episodio: tarda uno o dos minutos"), nil)
        let result = try await PostPodWebClient.shared.aiMoments(ref: String(localized: "mac:\(project.id)"), text: EditEngine.transcriptForAI(project))
        var p = project
        // Notas: resumen y puntos destacados (van a la descripción al publicar)
        if let notes = result["notes"] as? [String: Any] {
            var text = (notes["summary"] as? String) ?? ""
            let highlights = (notes["highlights"] as? [String]) ?? []
            if !highlights.isEmpty { text += "\n\n" + highlights.map { "• " + $0 }.joined(separator: "\n") }
            if !text.isEmpty { p.aiSummary = text }
        }
        // Momentos: un reel por cada uno (sin repetir los que ya están)
        var added = 0
        for c in (result["clips"] as? [[String: Any]]) ?? [] {
            guard let s = (c["start"] as? String).flatMap(ClipSuggester.parseClock),
                  let e = (c["end"] as? String).flatMap(ClipSuggester.parseClock), e > s else { continue }
            let sug = ClipSuggester.snap(.init(title: (c["title"] as? String) ?? "Momento", reason: (c["reason"] as? String) ?? "",
                                               start: s, end: e), words: p.words, duration: p.duration)
            if p.reels.contains(where: { abs($0.start - sug.start) < 3 }) { continue }
            p.reels.append(Reel(title: sug.title, reason: sug.reason, start: sug.start, end: sug.end))
            added += 1
        }
        let first = p.aiAnalyzedAt == nil
        p.aiAnalyzedAt = p.aiAnalyzedAt ?? Date()
        project = p
        aiNote = added > 0
            ? String(localized: "La IA encontró \(added) \(added == 1 ? "momento" : "momentos") y escribió las notas del episodio.")
            : (first ? String(localized: "La IA escribió las notas; no encontró momentos claros.") : String(localized: "Ya estaban todos los momentos de la IA."))
    }

    func performSuggest() async throws {
            if project.words.isEmpty { try await transcribeMissing() }
            try await ensureEnergy()
            report(String(localized: "Buscando los mejores momentos"), Keychain.apiKey == nil ? String(localized: "Análisis automático") : String(localized: "Preguntándole a Claude…"), nil)
            let result = try await ClipSuggester.suggest(project: project)
            project.reels = result.clips.map { Reel(title: $0.title, reason: $0.reason, start: $0.start, end: $0.end) }
            if let s = result.summary { project.aiSummary = s }
            reelsNote = result.clips.isEmpty
                ? String(localized: "No encontramos momentos claros. Prueba primero con “Arreglar” para tener la transcripción.")
                : (result.usedAI ? String(localized: "Claude eligió \(result.clips.count) momentos.") : String(localized: "Elegimos \(result.clips.count) momentos automáticamente. Con una clave de Claude en Ajustes la selección es mucho más inteligente."))
    }

    func export(format: ExportFormat) {
        run("Exportando") { [self] in
            let url = try await performExport(format: format)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Pistas por separado (WAV): una por persona y la música aparte.
    func exportStems() {
        run(String(localized: "Exportando pistas")) { [self] in
            try await ensureEnergy()
            player.pause()
            report(String(localized: "Exportando pistas por separado"), "", 0)
            let folder = try await Exporter.exportStems(project: project, energy: energy) { [weak self] f in
                self?.reportAsync(String(localized: "Exportando pistas por separado"), "", f)
            }
            refreshExports()
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func performExport(format: ExportFormat) async throws -> URL {
            try await ensureEnergy()
            player.pause()
            let uhd = format == .landscape && ExportFormat.uhdAvailable && UserDefaults.standard.bool(forKey: "export.youtube4k")
            let title = uhd ? "\(format.title) en 4K" : format.title
            report(String(localized: "Exportando \(title)"), "", 0)
            let project = self.project, energy = self.energy
            let url = try await ExportFormat.$uhd.withValue(uhd) {
                try await Exporter.export(project: project, format: format, energy: energy) { [weak self] f in
                    self?.reportAsync(String(localized: "Exportando \(title)"), "", f)
                }
            }
            refreshExports()
            return url
    }

    // MARK: Revisión compartida

    /// Exporta el MP3 completo, lo sube a postPod web y guarda el enlace para compartir.
    func sendForReview() {
        guard let slug = project.postpodSlug else { note = String(localized: "Este episodio no vino de postPod web: no hay dónde subirlo."); return }
        run(String(localized: "Enviando a revisión")) { [self] in
            let url = try await performExport(format: .audio)
            report(String(localized: "Subiendo a postPod"), url.lastPathComponent, 0.95)
            let r = try await PostPodWebClient.shared.uploadReview(slug: slug, file: url, title: Exporter.episodeTitle(project))
            let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts)
            let intro = project.intro.map { max(1, $0.seconds) } ?? 0
            project.review = ReviewLink(token: r.token, url: r.url, sentAt: Date(), introDuration: intro, keep: keep)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.url, forType: .string)
            note = String(localized: "Enlace de revisión copiado al portapapeles.")
        }
    }

    func refreshReviewComments() {
        guard let slug = project.postpodSlug, let r = project.review else { return }
        Task { @MainActor in
            do {
                let cs = try await PostPodWebClient.shared.reviewComments(slug: slug, token: r.token)
                project.review?.comments = cs
                project.review?.fetchedAt = Date()
            } catch { note = String(localized: "No se pudieron traer los comentarios: \(error.localizedDescription)") }
        }
    }

    func resolveReviewComment(_ id: Int, _ resolved: Bool) {
        guard let slug = project.postpodSlug, let r = project.review else { return }
        if let i = project.review?.comments.firstIndex(where: { $0.id == id }) { project.review?.comments[i].resolved = resolved }
        Task { try? await PostPodWebClient.shared.resolveReview(slug: slug, token: r.token, id: id, resolved: resolved) }
    }

    func revokeReview() {
        guard let slug = project.postpodSlug, let r = project.review else { return }
        project.review = nil
        Task { try? await PostPodWebClient.shared.revokeReview(slug: slug, token: r.token) }
    }

    func exportReels() {
        let reels = project.reels.filter(\.selected)
        guard !reels.isEmpty else { return }
        run(String(localized: "Exportando reels")) { [self] in
            let urls = try await performExportReels()
            if let last = urls.last { NSWorkspace.shared.activateFileViewerSelecting([last]) }
        }
    }

    /// Exporta un solo reel (botón de su tarjeta) y lo muestra en el Finder.
    func exportReel(_ reel: Reel) {
        run(String(localized: "Exportando reel")) { [self] in
            let urls = try await performExportReels(only: reel)
            if let last = urls.last { NSWorkspace.shared.activateFileViewerSelecting([last]) }
        }
    }

    @discardableResult
    func performExportReels(only: Reel? = nil) async throws -> [URL] {
            let reels = only.map { [$0] } ?? project.reels.filter(\.selected)
            try await ensureEnergy()
            player.pause()
            var urls: [URL] = []
            for (i, reel) in reels.enumerated() {
                let label = String(localized: "Reel \(i + 1) de \(reels.count): \(reel.title)")
                report(String(localized: "Exportando reels"), label, 0)
                let url = try await Exporter.export(project: project.applying(project.look(for: reel), reel: reel), format: .vertical,
                                                    window: (reel.start, reel.end),
                                                    baseName: "reel-\((project.reels.firstIndex { $0.id == reel.id } ?? i) + 1)-\(reel.title)", energy: energy) { [weak self] f in
                    self?.reportAsync(String(localized: "Exportando reels"), label, f)
                }
                if let idx = project.reels.firstIndex(where: { $0.id == reel.id }) {
                    project.reels[idx].exportedFile = url.lastPathComponent
                }
                urls.append(url)
            }
            refreshExports()
            return urls
    }

    // MARK: Subtítulos a archivo

    /// Guarda los subtítulos (.srt) o la transcripción (.txt) donde el usuario elija.
    func saveSubtitles(asText: Bool) {
        guard project.isTranscribed else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = asText ? [.plainText] : [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = ProjectStore.slugify(project.name) + (asText ? "-transcripcion.txt" : ".srt")
        panel.message = asText ? String(localized: "Transcripción en texto, con quién habla") : String(localized: "Subtítulos SRT (YouTube, Spotify, editores de video)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = asText ? Exporter.transcriptText(project: project) : Exporter.srt(project: project)
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Intro y cierre

    func setBumper(isIntro: Bool, _ b: Bumper?) {
        if isIntro { project.intro = b } else { project.outro = b }
    }
    func chooseBumperImage(isIntro: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = isIntro ? String(localized: "Elige la imagen del intro") : String(localized: "Elige la imagen del cierre")
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
        panel.message = String(localized: "Elige la música del \(isIntro ? "intro" : "cierre")")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dest = ProjectStore.folder(for: project.id).appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let to = dest.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: url, to: to) }
        b.musicFile = "sfx/\(url.lastPathComponent)"
        setBumper(isIntro: isIntro, b)
    }

    // MARK: Ecualizador por persona

    /// (Hasta 0.30) procesaba el audio con ffmpeg; ahora la cadena de voz va en tiempo real y no hay nada que aplicar.
    /// Se conserva para proyectos que todavía tengan archivos `eq_*.m4a`: ya no se usan.
    func applyEQ(laneId: Int) {
        guard let lane = project.lanes.first(where: { $0.id == laneId }) else { return }
        let eq = lane.eq
        let who = project.laneName(laneId)
        run(String(localized: "Ecualizando la voz de \(who)")) { [self] in
            for clip in lane.clips {
                guard let i = project.media.firstIndex(where: { $0.id == clip.mediaId }) else { continue }
                let m = project.media[i]
                guard m.hasAudio else { continue }
                if eq.isFlat { project.media[i].eqAudioFile = nil; continue }
                var base = (project.enhanceAudio ? m.enhancedAudioFile : nil) ?? m.file
                if !FileManager.default.fileExists(atPath: ProjectStore.url(base, in: project.id).path) { base = m.file }
                let rel = try await AudioAnalysis.applyEQ(media: m, base: base, eq: eq, slug: project.id) { [weak self] f in
                    self?.reportAsync(String(localized: "Ecualizando la voz de \(who)"), "", f)
                }
                if let j = project.media.firstIndex(where: { $0.id == m.id }) { project.media[j].eqAudioFile = rel }
            }
            schedulePreview(immediate: true)
        }
    }

    /// ¿El ecualizador de esta persona ya está aplicado tal como está configurado? Con la cadena en
    /// tiempo real, siempre: se oye al instante.
    func eqApplied(laneId: Int) -> Bool { true }

    // MARK: Proxys

    /// Prepara en segundo plano, con prioridad baja, los proxys de las grabaciones grandes que no lo tengan; al
    /// terminar cada uno, la vista previa se rearma con él. No bloquea nada y no toca el export.
    func prepareProxies() {
        guard ProxyStore.enabled, proxyTask == nil else { return }
        let p = project
        proxyTask = Task(priority: .utility) { [weak self] in
            defer { Task { @MainActor in self?.proxyTask = nil } }
            let pending = await ProxyStore.pending(project: p)
            guard !pending.isEmpty else { return }
            for (i, m) in pending.enumerated() {
                if Task.isCancelled { return }
                await MainActor.run { self?.proxyStatus = String(localized: "Preparando proxy \(i + 1) de \(pending.count): \(m.originalName)") }
                do {
                    try await ProxyStore.make(m, project: p.id)
                    await MainActor.run { self?.schedulePreview(immediate: true) }
                } catch {
                    await MainActor.run { self?.note = String(localized: "No se pudo preparar el proxy de \(m.originalName): \(error.localizedDescription)") }
                }
            }
            await MainActor.run { self?.proxyStatus = nil }
        }
    }

    /// Encender o apagar los proxys (preferencia de la app) y rearmar la vista previa.
    func setProxies(_ on: Bool) {
        ProxyStore.enabled = on
        if on { prepareProxies() } else { proxyTask?.cancel(); proxyTask = nil; proxyStatus = nil }
        schedulePreview(immediate: true)
    }

    // MARK: Igualar color de las cámaras

    /// Igualar cámaras: con `reference`, esa cámara manda y las demás reciben una ganancia por canal (balance) y una
    /// exposición (brillo) en su color de Studio; sin referencia (botón del paso simple), la primera en pantalla.
    func matchCameraColors(reference: Int? = nil) {
        run(String(localized: "Igualando el color de las cámaras")) { [self] in
            let ctx = CIContext()
            var avg: [Int: [Double]] = [:]
            for lane in project.lanes {
                guard let clip = lane.clips.first, let m = project.mediaItem(clip.mediaId), m.hasVideo else { continue }
                let asset = AVURLAsset(url: ProjectStore.url(m.file, in: project.id))
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                var sum = [0.0, 0.0, 0.0], n = 0.0
                for k in 1...6 {
                    let t = CMTime(seconds: m.duration * Double(k) / 7, preferredTimescale: 600)
                    guard let cg = try? await gen.image(at: t).image else { continue }
                    let img = CIImage(cgImage: cg)
                    let e = img.extent
                    let center = e.insetBy(dx: e.width * 0.2, dy: e.height * 0.2)
                    let a = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: center)])
                    var px = [UInt8](repeating: 0, count: 4)
                    ctx.render(a, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                    sum[0] += Double(px[0]); sum[1] += Double(px[1]); sum[2] += Double(px[2]); n += 1
                }
                if n > 0 { avg[lane.id] = sum.map { max(1, $0 / n) } }
            }
            guard let refId = reference.flatMap({ avg[$0] != nil ? $0 : nil }) ?? project.lanesOnScreen.map(\.id).first(where: { avg[$0] != nil }),
                  let ref = avg[refId] else { return }
            var gains: [Int: [Double]] = [:]
            for (id, a) in avg where id != refId {
                let fix = CameraMatch.fix(camera: a, reference: ref)
                gains[id] = fix.gain
                if reference != nil, let li = project.lanes.firstIndex(where: { $0.id == id }) {
                    var g = project.lanes[li].grade ?? ColorGrade()
                    g.exposure = fix.exposure
                    project.lanes[li].grade = g.isEmpty ? nil : g
                }
            }
            project.laneColorGain = gains
            project.matchColors = true
        }
    }

    // MARK: Orden en pantalla

    /// Pone a una persona en la posición `pos` (1 = primera). El resto corre.
    func setLanePosition(_ laneId: Int, _ pos: Int) {
        var order = project.lanesOnScreen.map(\.id)
        guard let i = order.firstIndex(of: laneId) else { return }
        order.remove(at: i)
        order.insert(laneId, at: min(max(0, pos - 1), order.count))
        project.laneOrder = order
    }

    /// Orden en pantalla propio de un reel (o de todos los reels).
    func setReelLanePosition(_ laneId: Int, _ pos: Int, reelId: UUID?) {
        func moved(_ base: [Int]) -> [Int] {
            var order = base
            for l in project.lanes.map(\.id) where !order.contains(l) { order.append(l) }
            guard let i = order.firstIndex(of: laneId) else { return order }
            order.remove(at: i)
            order.insert(laneId, at: min(max(0, pos - 1), order.count))
            return order
        }
        if let reelId, let i = project.reels.firstIndex(where: { $0.id == reelId }) {
            var l = project.reels[i].look ?? project.reelLook
            l.laneOrder = moved(l.laneOrder ?? project.reelLook.laneOrder ?? project.lanesOnScreen.map(\.id))
            project.reels[i].look = l
        } else {
            project.reelLook.laneOrder = moved(project.reelLook.laneOrder ?? project.lanesOnScreen.map(\.id))
        }
    }

    // MARK: Sincronizar personas

    /// Mueve el inicio de la grabación de una persona (desfase). Negativo = suena antes (se salta el
    /// principio de su grabación); positivo = suena después. Arrastra con ella sus palabras transcritas,
    /// actualiza la vista previa al instante y vuelve a calcular quién habla cuando se deja de tocar.
    func setLaneOffset(_ laneId: Int, _ newOffset: Double) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        let target = (max(project.lanes[i].minOffset, newOffset) * 100).rounded() / 100
        let delta = target - project.lanes[i].offset
        guard abs(delta) > 0.0005 else { return }
        var p = project
        p.lanes[i].offset = target
        for w in p.words.indices where p.words[w].lane == laneId {
            p.words[w].s += delta
            p.words[w].e += delta
        }
        project = p
        let name = project.laneName(laneId)
        flashNote("\(name): \(Self.offsetText(target))")
        schedulePreview(immediate: true)
        // Quién habla (y los silencios) se recalculan una sola vez, cuando se deja de tocar el desfase
        offsetWork?.cancel()
        offsetWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled else { return }
            while self.job != nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            try? FileManager.default.removeItem(at: AudioAnalysis.energyURL(self.project.id))
            self.energy = nil
            guard self.project.lanes.count > 1 else { return }
            self.run(String(localized: "Analizando quién habla")) { [self] in
                try await self.ensureEnergy()
                self.schedulePreview(immediate: true)
            }
        }
    }

    /// «9,0 s antes» / «0,3 s después» / «en su lugar original».
    static func offsetText(_ o: Double) -> String {
        if abs(o) < 0.005 { return String(localized: "en su lugar original") }
        let v = String(format: "%.2f", abs(o)).replacingOccurrences(of: ".", with: ",")
            .replacingOccurrences(of: #",?0+$"#, with: "", options: .regularExpression)
        return o < 0 ? String(localized: "suena \(v) s antes") : String(localized: "suena \(v) s después")
    }

    // MARK: Música y efectos

    /// Mueve un sonido/música de la línea de audio a otro punto del episodio.
    func moveSound(_ clipId: Int, to timeline: Double) {
        guard let i = project.audioLane.firstIndex(where: { $0.id == clipId }) else { return }
        project.audioLane[i].tlStart = min(max(0, timeline), max(0, project.duration - 0.5))
    }

    /// El usuario elige archivos de música/efectos; se copian al proyecto y quedan en la biblioteca (y si se pide, puestos).
    func importSounds(placeAt: Double? = nil, reelId: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Elige música o efectos (mp3, wav, m4a)")
        guard panel.runModal() == .OK else { return }
        let dest = ProjectStore.folder(for: project.id).appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for url in panel.urls {
            let to = dest.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: url, to: to) }
            let rel = "sfx/\(url.lastPathComponent)"
            if !project.sfxLibrary.contains(rel) { project.sfxLibrary.insert(rel, at: 0) }
            if let placeAt { Task { await addSound(rel, at: placeAt, reelId: reelId) } }
        }
    }

    // MARK: Sound effects

    func addSound(_ rel: String, at timeline: Double, reelId: UUID? = nil) async {
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
        if let reelId, let r = p.reels.firstIndex(where: { $0.id == reelId }) {
            // Música propia del reel: empieza donde empieza el reel (o donde está el video, si está dentro del reel)
            let reel = p.reels[r]
            let id = (reel.music.map(\.id).max() ?? 0) + 1
            let at = (timeline >= reel.start && timeline < reel.end) ? timeline : reel.start
            var clip = AudioLaneClip(id: id, mediaId: mediaId, tlStart: at, srcIn: 0, srcOut: len, volume: 0.8)
            clip.loop = len < reel.length   // más corta que el reel: se repite hasta el final
            p.reels[r].music.append(clip)
            project = p
            if previewReel?.id == reelId { previewReel = project.reels[r] }
            selectedTrack = .reelSound(reelId, id)
            return
        }
        let id = (p.audioLane.map(\.id).max() ?? 0) + 1
        p.audioLane.append(AudioLaneClip(id: id, mediaId: mediaId, tlStart: max(0, timeline), srcIn: 0, srcOut: len, volume: 0.8))
        project = p
        selectedTrack = .sound(id)
    }

    /// Acceso a un sonido por dónde vive (episodio o reel), para el panel bajo el video.
    func soundBinding(_ sel: TrackSel) -> Binding<AudioLaneClip>? {
        switch sel {
        case .sound(let id):
            guard let clip = project.audioLane.first(where: { $0.id == id }) else { return nil }
            return Binding(get: { self.project.audioLane.first { $0.id == id } ?? clip },
                           set: { v in if let i = self.project.audioLane.firstIndex(where: { $0.id == id }) { self.project.audioLane[i] = v } })
        case .reelSound(let rid, let id):
            guard let r = project.reels.firstIndex(where: { $0.id == rid }), let clip = project.reels[r].music.first(where: { $0.id == id }) else { return nil }
            return Binding(get: { self.project.reels.first { $0.id == rid }?.music.first { $0.id == id } ?? clip },
                           set: { v in
                               guard let r = self.project.reels.firstIndex(where: { $0.id == rid }),
                                     let i = self.project.reels[r].music.firstIndex(where: { $0.id == id }) else { return }
                               self.project.reels[r].music[i] = v
                               if self.previewReel?.id == rid { self.previewReel = self.project.reels[r] }
                           })
        default: return nil
        }
    }

    func removeSound(_ sel: TrackSel) {
        switch sel {
        case .sound(let id): project.audioLane.removeAll { $0.id == id }
        case .reelSound(let rid, let id):
            if let r = project.reels.firstIndex(where: { $0.id == rid }) {
                project.reels[r].music.removeAll { $0.id == id }
                if previewReel?.id == rid { previewReel = project.reels[r] }
            }
        default: break
        }
        selectedTrack = nil
    }

    // MARK: Voz artificial

    @Published var voiceSheet = false

    /// Genera el texto con una voz de la Mac y lo pone donde está el video (o donde se pida).
    func addVoice(text: String, voice: Speech.Voice?, rate: Float, at timeline: Double? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let dest = ProjectStore.folder(for: project.id).appendingPathComponent("sfx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let stem = "voz-" + ProjectStore.slugify(String(t.prefix(28)))
        var name = stem + ".caf", n = 2
        while FileManager.default.fileExists(atPath: dest.appendingPathComponent(name).path) { name = "\(stem)-\(n).caf"; n += 1 }
        let rel = "sfx/\(name)"
        let at = timeline ?? playheadTimeline
        run(String(localized: "Generando la voz")) { [self] in
            try await Speech.synthesize(t, voice: voice, rate: rate, to: dest.appendingPathComponent(name))
            if !project.sfxLibrary.contains(rel) { project.sfxLibrary.insert(rel, at: 0) }
            project.sfxNames[rel] = String(localized: "Voz: ") + String(t.prefix(40))
            await addSound(rel, at: at)
            if let i = project.audioLane.firstIndex(where: { project.mediaItem($0.mediaId)?.file == rel }) {
                project.audioLane[i].volume = 1
                project.audioLane[i].duck = false
            }
        }
    }

    // MARK: Cintillos

    /// Crea un cintillo donde está el video (estilo news | clean | sponsor) y lo deja elegido.
    @discardableResult
    func addCintillo(style: String, kind: String = "banner", title: String = "", text: String = "", logoFile: String? = nil, tag: String? = nil, reelId: UUID? = nil) -> Int {
        let reel = reelId.flatMap { rid in project.reels.first { $0.id == rid } }
        let id = ((reel?.cintillos ?? project.cintillos).map(\.id).max() ?? 0) + 1
        var t = min(playheadTimeline, max(0, project.duration - 1))
        if let reel { t = min(max(reel.start, t), max(reel.start, reel.end - 2)) }
        var c = DirectorCintillo(id: id, kind: kind, title: title.isEmpty ? (style == "sponsor" ? String(localized: "Nombre del sponsor") : "Título") : title,
                                 text: text.isEmpty ? (style == "sponsor" ? String(localized: "Una frase corta sobre el sponsor") : String(localized: "Un texto corto debajo del título")) : text,
                                 start: t, duration: 7, logoFile: logoFile, style: style, tag: tag)
        if style == "clean" { c.tag = "" }
        if let reelId, let r = project.reels.firstIndex(where: { $0.id == reelId }) {
            if let reel { c.duration = min(c.duration, max(2, reel.end - c.start)) }
            project.reels[r].cintillos.append(c)
            if previewReel?.id == reelId { previewReel = project.reels[r] }
            selectedTrack = .reelCintillo(reelId, id)
            return id
        }
        project.cintillos.append(c)
        selectedTrack = .cintillo(id)
        if !project.showCintillos { project.showCintillos = true }
        return id
    }

    /// Cintillo de sponsor a partir de un sponsor de prePod (logo y frase ya puestos).
    func addSponsorCintillo(_ sp: Sponsor, reelId: UUID? = nil) {
        _ = addCintillo(style: "sponsor", kind: "sponsor", title: sp.name, text: sp.copy ?? "", logoFile: sp.logoFile, tag: "PATROCINA", reelId: reelId)
    }

    /// Acceso a un cintillo por dónde vive (episodio o reel), para el panel bajo el video.
    func cintilloBinding(_ sel: TrackSel) -> Binding<DirectorCintillo>? {
        switch sel {
        case .cintillo(let id):
            guard let c = project.cintillos.first(where: { $0.id == id }) else { return nil }
            return Binding(get: { self.project.cintillos.first { $0.id == id } ?? c },
                           set: { v in if let i = self.project.cintillos.firstIndex(where: { $0.id == id }) { self.project.cintillos[i] = v } })
        case .reelCintillo(let rid, let id):
            guard let r = project.reels.firstIndex(where: { $0.id == rid }), let c = project.reels[r].cintillos.first(where: { $0.id == id }) else { return nil }
            return Binding(get: { self.project.reels.first { $0.id == rid }?.cintillos.first { $0.id == id } ?? c },
                           set: { v in
                               guard let r = self.project.reels.firstIndex(where: { $0.id == rid }),
                                     let i = self.project.reels[r].cintillos.firstIndex(where: { $0.id == id }) else { return }
                               self.project.reels[r].cintillos[i] = v
                               if self.previewReel?.id == rid { self.previewReel = self.project.reels[r] }
                           })
        default: return nil
        }
    }

    func removeCintillo(_ sel: TrackSel) {
        switch sel {
        case .cintillo(let id): project.cintillos.removeAll { $0.id == id }
        case .reelCintillo(let rid, let id):
            if let r = project.reels.firstIndex(where: { $0.id == rid }) {
                project.reels[r].cintillos.removeAll { $0.id == id }
                if previewReel?.id == rid { previewReel = project.reels[r] }
            }
        default: break
        }
        selectedTrack = nil
    }

    func duplicateCintillo(_ id: Int) {
        guard var c = project.cintillos.first(where: { $0.id == id }) else { return }
        c.id = (project.cintillos.map(\.id).max() ?? 0) + 1
        c.start = min(playheadTimeline, max(0, project.duration - 1))
        c.fromDirector = false
        project.cintillos.append(c)
        selectedTrack = .cintillo(c.id)
    }

    func chooseCintilloLogo(_ id: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige el logo del cintillo (un PNG con fondo transparente queda mejor)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let rel = "cintillos/logo-\(id)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        if let i = project.cintillos.firstIndex(where: { $0.id == id }) { project.cintillos[i].logoFile = rel }
    }

    func chooseCintilloLogo(_ sel: TrackSel) {
        guard let b = cintilloBinding(sel) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige el logo del cintillo (un PNG con fondo transparente queda mejor)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let rel = "cintillos/logo-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        b.wrappedValue.logoFile = rel
    }

    // MARK: B-roll

    /// Elige un video o una imagen y lo pone como b-roll donde está el video (del episodio, o solo de un reel).
    func chooseBRoll(reelId: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video, .png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige un video o una imagen para poner encima un rato (b-roll)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = ProjectStore.folder(for: project.id).appendingPathComponent("broll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: to.path) {
            do { try FileManager.default.copyItem(at: url, to: to) } catch { errorMessage = error.localizedDescription; return }
        }
        let rel = "broll/\(url.lastPathComponent)"
        let isVideo = !["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff"].contains(url.pathExtension.lowercased())
        let reel = reelId.flatMap { id in project.reels.first { $0.id == id } }
        let pool = reel?.brolls ?? project.brolls
        let id = (pool.map(\.id).max() ?? 0) + 1
        // Tope: 10 s, y dentro de un reel nunca más largo que el reel (menos 1 s)
        let cap = reel.map { max(1, min(BRollClip.maxSeconds, $0.length - 1)) } ?? BRollClip.maxSeconds
        var start = min(playheadTimeline, max(0, project.duration - 1))
        if let reel { start = min(max(reel.start, start), max(reel.start, reel.end - 1)) }
        var clip = BRollClip(id: id, file: rel, isVideo: isVideo, start: start, duration: min(6, cap))
        func add(_ c: BRollClip) {
            if let reelId, let i = project.reels.firstIndex(where: { $0.id == reelId }) {
                project.reels[i].brolls.append(c)
                selectedTrack = .reelBRoll(reelId, c.id)
                if previewReel?.id == reelId { previewReel = project.reels[i] }
            } else {
                project.brolls.append(c)
                selectedTrack = .broll(c.id)
            }
        }
        if isVideo {
            Task { [self] in
                let d = (try? await AVURLAsset(url: to).load(.duration).seconds) ?? 6
                if d.isFinite, d > 0 { clip.duration = min(d, cap) }
                add(clip)
            }
        } else {
            add(clip)
        }
    }

    func removeBRoll(_ id: Int, reelId: UUID? = nil) {
        if let reelId, let i = project.reels.firstIndex(where: { $0.id == reelId }) {
            project.reels[i].brolls.removeAll { $0.id == id }
            if previewReel?.id == reelId { previewReel = project.reels[i] }
        } else {
            project.brolls.removeAll { $0.id == id }
        }
        selectedTrack = nil
    }

    // MARK: Capas (textos, imágenes, stickers)

    /// Agrega una capa donde está el video ahora y la deja elegida para editarla bajo el video.
    @discardableResult
    func addOverlay(kind: VideoLayer.Kind, text: String = "", imageFile: String? = nil) -> Int {
        let id = (project.overlays.map(\.id).max() ?? 0) + 1
        let t = min(playheadTimeline, max(0, project.duration - 1))
        var o = VideoLayer(id: id, kind: kind, start: t, duration: kind == .sticker ? 3 : 5, text: text, imageFile: imageFile)
        switch kind {
        case .text: (o.x, o.y) = VideoLayer.anchor(row: 0, col: 1)
        case .sticker: (o.x, o.y) = VideoLayer.anchor(row: 0, col: 2)
        case .image: (o.x, o.y) = VideoLayer.anchor(row: 1, col: 1)
        }
        project.overlays.append(o)
        selectedTrack = .overlay(id)
        return id
    }

    /// Elige una imagen (PNG con transparencia, JPG, HEIC, GIF) y la agrega como capa.
    func chooseOverlayImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige una imagen para poner encima del video (un PNG con fondo transparente queda mejor)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let rel = "capas/\(Int(Date().timeIntervalSince1970))_\(ProjectStore.slugify(url.deletingPathExtension().lastPathComponent)).\(ext)"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        addOverlay(kind: .image, imageFile: rel)
    }

    /// Logo o fondo solo para los reels (de todos, o del reel elegido).
    func chooseReelImage(kind: String, reelId: UUID?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.message = kind == "logo" ? String(localized: "Elige el logo para los reels (un PNG con fondo transparente queda mejor)") : String(localized: "Elige el fondo para los reels (vertical, 1080×1920)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let rel = "branding/reel-\(kind)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        setReelImage(kind: kind, reelId: reelId, file: rel)
    }

    func setReelImage(kind: String, reelId: UUID?, file: String?) {
        if let reelId, let i = project.reels.firstIndex(where: { $0.id == reelId }) {
            var l = project.reels[i].look ?? project.reelLook
            if kind == "logo" { l.logoFile = file } else { l.backgroundFile = file }
            project.reels[i].look = l
        } else {
            if kind == "logo" { project.reelLook.logoFile = file } else { project.reelLook.backgroundFile = file }
        }
    }

    /// Imagen para el fondo virtual de una persona.
    func chooseVirtualBackgroundImage(laneId: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige la imagen que va detrás de \(project.laneName(laneId))")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let rel = "branding/fondo-\(laneId)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = ProjectStore.url(rel, in: project.id)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { errorMessage = error.localizedDescription; return }
        var vb = project.laneBackground[laneId] ?? VirtualBackground()
        vb.mode = .image
        vb.imageFile = rel
        project.laneBackground[laneId] = vb
    }

    func removeOverlay(_ id: Int) {
        project.overlays.removeAll { $0.id == id }
        if selectedTrack == .overlay(id) { selectedTrack = nil }
    }

    func duplicateOverlay(_ id: Int) {
        guard var o = project.overlays.first(where: { $0.id == id }) else { return }
        o.id = (project.overlays.map(\.id).max() ?? 0) + 1
        o.start = min(playheadTimeline, max(0, project.duration - 1))
        project.overlays.append(o)
        selectedTrack = .overlay(o.id)
    }

    /// Current playhead in TIMELINE time.
    /// Marca un momento donde está el video (como la tecla M en postPod web) y crea su reel.
    @discardableResult
    func markMoment() -> Reel {
        let t = playheadTimeline
        let n = project.moments.count + 1
        let id = (project.moments.map(\.id).max() ?? 0) + 1
        project.moments.append(Moment(id: id, time: t, duration: nil, label: String(localized: "Momento \(n)")))
        let reel = Reel(title: String(localized: "Momento \(n)"), reason: String(localized: "Marcado en la app"), start: t, end: min(project.duration, t + 60))
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

    /// Solo lee la lista ya cargada (se llama desde el dibujo de las vistas: no debe cambiar estado).
    func latestExport(suffix: String, ext: String) -> URL? {
        lastExports.first { $0.pathExtension == ext && $0.lastPathComponent.contains("_\(suffix)_") }
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
        run(String(localized: "Publicando en Spotify y Apple")) { [self] in
            var file = latestExport(suffix: "audio", ext: "mp3")
            if file == nil { file = try await performExport(format: .audio) }
            guard let file else { return }
            report(String(localized: "Publicando en Spotify y Apple"), String(localized: "Subiendo el MP3 a prePod…"), 0)
            let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                self?.reportAsync(String(localized: "Publicando en Spotify y Apple"), String(localized: "Subiendo el MP3 a prePod…"), f)
            }
            report(String(localized: "Publicando en Spotify y Apple"), String(localized: "Poniéndolo en el feed…"), nil)
            let job = try await PrePodClient.shared.publishAudio(slug: slug, episodeId: ep, uploadId: upload)
            let result = try await PrePodClient.shared.wait(job: job) { [weak self] f in
                self?.reportAsync(String(localized: "Publicando en Spotify y Apple"), String(localized: "Poniéndolo en el feed…"), f)
            }
            project.episode.publishedAudioURL = result["media_url"]
            loadPublishStatus()
        }
    }

    func publishYouTube(title: String, description: String, privacy: String) {
        guard let slug = project.episode.prepodSlug, let ep = project.episode.prepodEpisodeId else { return }
        run(String(localized: "Subiendo a YouTube")) { [self] in
            var file = latestExport(suffix: "youtube", ext: "mp4")
            if file == nil { file = try await performExport(format: .landscape) }
            guard let file else { return }
            report(String(localized: "Subiendo a YouTube"), String(localized: "Enviando el video a prePod…"), 0)
            let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                self?.reportAsync(String(localized: "Subiendo a YouTube"), String(localized: "Enviando el video a prePod…"), f)
            }
            report(String(localized: "Subiendo a YouTube"), String(localized: "prePod lo está subiendo a tu canal…"), 0)
            let job = try await PrePodClient.shared.publishYouTube(slug: slug, episodeId: ep, uploadId: upload,
                                                                   title: title, description: description, privacy: privacy)
            let result = try await PrePodClient.shared.wait(job: job) { [weak self] f in
                self?.reportAsync(String(localized: "Subiendo a YouTube"), String(localized: "prePod lo está subiendo a tu canal…"), f)
            }
            project.episode.publishedYouTubeURL = result["video_url"] ?? result["url"]
            loadPublishStatus()
        }
    }

    // MARK: pubPod: reels a redes

    @Published var reelPosts: [PrePodClient.PubPost]?

    /// pubPod: el episodio completo a sus destinos (ahora o programado). Cada destino lleva su archivo:
    /// youtube = video 16:9, feed = el audio (Spotify y Apple Podcasts), instagram_image = la portada.
    func publishEpisode(title: String, targets: [(platform: String, caption: String)], at: Date?) {
        guard let slug = project.episode.prepodSlug else { return }
        let episodeId = project.episode.prepodEpisodeId
        reelPosts = nil
        run(String(localized: "Publicando el episodio")) { [self] in
            var all: [PrePodClient.PubPost] = []
            for t in targets {
                let (label, file): (String, URL)
                switch t.platform {
                case "feed":
                    report(String(localized: "Publicando el episodio"), String(localized: "Exportando el audio…"), nil)
                    var mp3 = latestExport(suffix: "audio", ext: "mp3")
                    if mp3 == nil { mp3 = try await performExport(format: .audio) }
                    (label, file) = (String(localized: "el audio"), mp3!)
                case "instagram_image":
                    report(String(localized: "Publicando el episodio"), String(localized: "Preparando la portada…"), nil)
                    (label, file) = (String(localized: "la portada"), try await exportCover())
                default:
                    (label, file) = (String(localized: "el video"), try await performExport(format: .landscape))
                }
                report(String(localized: "Publicando el episodio"), String(localized: "Subiendo \(label) a thePod…"), 0)
                let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                    self?.reportAsync(String(localized: "Publicando el episodio"), String(localized: "Subiendo \(label) a thePod…"), f)
                }
                all += try await PrePodClient.shared.createReelPosts(
                    slug: slug, episodeId: episodeId, uploadId: upload, title: title,
                    targets: [t], at: at, kind: "episode")
            }
            reelPosts = all
        }
    }

    /// Segundo del episodio que sale en la portada: el elegido en Portada o, si no, el primer reel o un cuarto del episodio.
    var coverTimeline: Double {
        project.coverTime ?? project.reels.first.map { $0.start + 1 } ?? project.duration * 0.25
    }

    /// Portada del episodio (Instagram, miniatura): un cuadro del episodio tal como se ve (diseño, logo, fondo). JPEG 16:9.
    func exportCover() async throws -> URL {
        let img = try await CoverScout.render(project: project, at: coverTimeline, energy: energy)
        guard let data = CoverScout.jpeg(img, quality: 0.9) else {
            throw PrePodClient.Failure(message: String(localized: "No se pudo preparar la portada"))
        }
        let url = ProjectStore.exportsFolder(for: project.id).appendingPathComponent("portada.jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Busca los segundos donde todas las personas salen sonriendo y nítidas, y deja una imagen de cada uno.
    func findCoverCandidates() {
        run(String(localized: "Buscando capturas")) { [self] in
            report(String(localized: "Buscando capturas"), String(localized: "Mirando las caras…"), 0)
            let found = try await CoverScout.scan(project: project) { [weak self] f, what in
                self?.reportAsync(String(localized: "Buscando capturas"), what, f * 0.7)
            }
            if found.isEmpty {
                project.coverCandidates = []
                project.coverScannedAt = Date()
                note = String(localized: "No encontré caras en el video. Elige el segundo a mano en Portada.")
                return
            }
            report(String(localized: "Buscando capturas"), String(localized: "Dibujando las portadas…"), 0.7)
            let folder = ProjectStore.cacheFolder(for: project.id).appendingPathComponent("portadas")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let images = try await CoverScout.renderAll(project: project, times: found.map { $0.time }, energy: energy, maxSize: 960) { [weak self] f in
                self?.reportAsync(String(localized: "Buscando capturas"), String(localized: "Dibujando las portadas…"), 0.7 + f * 0.3)
            }
            var out: [CoverCandidate] = []
            for s in found {
                guard let img = images[s.time], let data = CoverScout.jpeg(img, quality: 0.85) else { continue }
                let name = "portada-\(Int(s.time * 10)).jpg"
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                out.append(CoverCandidate(time: s.time, score: s.score, allSmiling: s.allSmiling, faces: s.faces, file: "portadas/" + name))
            }
            project.coverCandidates = out
            project.coverScannedAt = Date()
            if project.coverTime == nil, let best = out.max(by: { ($0.allSmiling ? 1 : 0, $0.score) < ($1.allSmiling ? 1 : 0, $1.score) }) {
                project.coverTime = best.time
            }
        }
    }

    /// Una captura del segundo donde está parado el episodio, para elegirla a mano.
    func addCoverCandidateAtPlayhead() {
        let t = playheadTimeline
        run("Capturando") { [self] in
            let img = try await CoverScout.render(project: project, at: t, energy: energy, maxSize: 960)
            guard let data = CoverScout.jpeg(img, quality: 0.85) else { return }
            let folder = ProjectStore.cacheFolder(for: project.id).appendingPathComponent("portadas")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "portada-\(Int(t * 10)).jpg"
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            project.coverCandidates.removeAll { abs($0.time - t) < 0.05 }
            project.coverCandidates.append(CoverCandidate(time: t, score: 0, allSmiling: false, faces: 0, file: "portadas/" + name))
            project.coverCandidates.sort { $0.time < $1.time }
            project.coverTime = t
        }
    }

    /// Guarda la portada elegida como JPEG en la carpeta de exportados y la muestra en el Finder.
    func saveCover() {
        run(String(localized: "Guardando la portada")) { [self] in
            let url = try await exportCover()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Exporta el reel tal como está ahora, lo sube a prePod y crea una publicación por red.
    func publishReel(_ reel: Reel, targets: [(platform: String, caption: String)], at: Date?) {
        guard let slug = project.episode.prepodSlug else { return }
        let episodeId = project.episode.prepodEpisodeId
        reelPosts = nil
        run(String(localized: "Publicando en redes")) { [self] in
            let urls = try await performExportReels(only: reel)
            guard let file = urls.first else { return }
            report(String(localized: "Publicando en redes"), String(localized: "Subiendo el reel a thePod…"), 0)
            let upload = try await PrePodClient.shared.upload(file: file) { [weak self] f in
                self?.reportAsync(String(localized: "Publicando en redes"), String(localized: "Subiendo el reel a thePod…"), f)
            }
            report(String(localized: "Publicando en redes"), String(localized: "Enviándolo a tus redes…"), nil)
            reelPosts = try await PrePodClient.shared.createReelPosts(
                slug: slug, episodeId: episodeId, uploadId: upload, title: reel.title, targets: targets, at: at)
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
        var reelId: UUID?               // la frase es del texto propio de ese reel (no del episodio)
    }

    /// Frases del transcrito. Con `reel`: solo las que caen en ese reel, y "cortada" cuenta también sus cortes propios.
    func phrases(reel: Reel? = nil) -> [Phrase] {
        let ownId = reel?.words != nil ? reel?.id : nil
        let words = reel?.words ?? project.words
        guard !words.isEmpty else { return [] }
        var out: [Phrase] = []
        var startIdx = 0
        let keep = EditEngine.keepRanges(duration: project.duration, cuts: project.cuts + (reel?.cuts ?? []))

        func close(_ end: Int) {
            guard end > startIdx else { return }
            let slice = words[startIdx..<end]
            let mid = (slice.first!.s + slice.last!.e) / 2
            out.append(Phrase(range: startIdx..<end, start: slice.first!.s, end: slice.last!.e, lane: slice.first!.lane,
                              text: slice.map(\.w).joined(separator: " "),
                              isCut: EditEngine.toOutput(mid, keep: keep) == nil, reelId: ownId))
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
        if let reel { out.removeAll { $0.end < reel.start || $0.start > reel.end } }
        return out
    }

    /// Quitar o devolver una frase solo en un reel (sus cortes propios; el episodio no cambia).
    func togglePhraseCut(_ phrase: Phrase, reel: Reel) {
        guard let i = project.reels.firstIndex(where: { $0.id == reel.id }) else { return }
        let cuts = project.reels[i].cuts
        if cuts.contains(where: { $0.enabled && $0.start <= phrase.start + 0.1 && $0.end >= phrase.end - 0.1 }) {
            project.reels[i].cuts.removeAll { $0.start <= phrase.start + 0.1 && $0.end >= phrase.end - 0.1 }
        } else if phrase.isCut {
            togglePhraseCut(phrase)   // estaba cortada en el episodio: devolverla ahí
        } else {
            project.reels[i].cuts.append(Cut(start: max(0, phrase.start - 0.05), end: phrase.end + 0.05, kind: .manual,
                                             label: "“\(phrase.text.prefix(40))…”"))
        }
        if previewReel?.id == reel.id { previewReel = project.reels[i] }
    }

    /// Quita los silencios solo dentro de un reel (cortes propios del reel).
    func removeSilences(in reel: Reel) {
        run(String(localized: "Buscando silencios en el reel")) { [self] in
            try await ensureEnergy()
            guard let i = project.reels.firstIndex(where: { $0.id == reel.id }) else { return }
            let inside = reelSilences(project.reels[i])
            project.reels[i].cuts.removeAll { $0.kind == .silence }
            project.reels[i].cuts += inside
            if previewReel?.id == reel.id { previewReel = project.reels[i] }
            reelsNote = inside.isEmpty ? String(localized: "No hay silencios largos en este reel.") : String(localized: "Quitamos \(inside.count) silencios solo en este reel (\(String(format: "%.1f", inside.reduce(0) { $0 + $1.length })) s).")
        }
    }

    /// Silencios dentro de un reel que no estén ya cortados en el episodio (con el texto del reel si tiene uno propio).
    private func reelSilences(_ reel: Reel) -> [Cut] {
        let st = project.fix
        let words = reel.words ?? project.words
        var found: [Cut] = []
        if !words.isEmpty {
            found = EditEngine.silenceCuts(words: words, duration: project.duration, minGap: st.minSilence, pad: st.keepPad)
            if let energy { found = EditEngine.protectSpeech(found, energy: energy.combined, hop: EnergyMap.hop, pad: st.keepPad) }
        } else if let energy {
            found = EditEngine.silenceCuts(energy: energy.combined, hop: EnergyMap.hop, minGap: st.minSilence, pad: st.keepPad)
        }
        return found.filter { $0.start >= reel.start - 0.01 && $0.end <= reel.end + 0.01 }
            .filter { c in !project.cuts.contains { $0.enabled && $0.start <= c.start + 0.05 && $0.end >= c.end - 0.05 } }
    }

    /// Solo el sonido de estudio (sin tocar cortes ni transcripción): para reels cuando el episodio no se limpió.
    func enhanceAudioOnly() {
        run(String(localized: "Limpiando el sonido")) { [self] in
            try await enhanceAudio()
            project.enhanceAudio = true
            schedulePreview(immediate: true)
        }
    }

    // MARK: Subtítulos: ajustar al audio y volver a escuchar

    /// Ajusta al audio todas las palabras del episodio. Devuelve cuántas se corrieron y el corrimiento típico.
    @discardableResult
    func syncWords() async throws -> SubtitleSync.Result {
        report(String(localized: "Ajustando los subtítulos al audio"), "", 0)
        let old = project.words
        let res = try await SubtitleSync.align(old, project: project) { [weak self] f in
            self?.reportAsync(String(localized: "Ajustando los subtítulos al audio"), "", f)
        }
        var p = project
        p.sensitive = SubtitleSync.remapSensitive(p.sensitive, old: old, new: res.words)
        p.words = res.words.sorted { $0.s < $1.s }
        p.wordsSynced = true
        project = p
        return res
    }

    /// Botón «Ajustar al audio»: corre las palabras a donde suena la voz y, si el episodio ya se arregló,
    /// vuelve a calcular sus silencios y muletillas (y los silencios de cada reel) con los tiempos nuevos.
    func syncSubtitles() {
        run(String(localized: "Ajustando los subtítulos al audio")) { [self] in
            let res = try await syncWords()
            let redid = try await redoAutoCuts()
            var msg = res.moved == 0
                ? String(localized: "Los subtítulos ya estaban en su lugar.")
                : String(localized: "Listo: corrimos \(res.moved) palabras para que salgan cuando se escucha la voz (en general \(Self.ms(res.typicalShift))).")
            if redid { msg += String(localized: " También volvimos a buscar los silencios con los tiempos nuevos.") }
            captionsNote = msg
            schedulePreview(immediate: true)
        }
    }

    /// Recalcula los cortes automáticos (si el episodio se arregló) y los silencios propios de los reels. true si cambió algo.
    private func redoAutoCuts() async throws -> Bool {
        var changed = false
        if project.fix.lastRun != nil {
            try await ensureEnergy()
            var p = project
            let old = p.cuts.filter { Self.isAutoCut($0) }
            p.cuts.removeAll { Self.isAutoCut($0) }
            let (silences, fillers) = autoCuts(p)
            p.cuts += EditEngine.carryDecisions(from: old, into: silences + fillers)
            project = p
            changed = true
        }
        for i in project.reels.indices where project.reels[i].cuts.contains(where: { $0.kind == .silence }) {
            try await ensureEnergy()
            let found = reelSilences(project.reels[i])
            project.reels[i].cuts.removeAll { $0.kind == .silence }
            project.reels[i].cuts += found
            if previewReel?.id == project.reels[i].id { previewReel = project.reels[i] }
            changed = true
        }
        return changed
    }

    /// Vuelve a escuchar TODO el episodio y escribe la transcripción de nuevo (ya ajustada al audio).
    /// Se pierden las correcciones hechas a mano en el texto; las palabras sensibles se vuelven a buscar
    /// y conservan lo que se había elegido (pitido, cambio) cuando son la misma palabra.
    func relistenEpisode() {
        run(String(localized: "Escribiendo la transcripción de nuevo")) { [self] in
            let previous = project.sensitive
            let backup = (project.words, project.transcribedLanes, project.wordsSynced)
            var p = project
            p.words = []
            p.transcribedLanes = []
            project = p
            do {
                try await transcribeMissing()
            } catch {
                // Cancelado o con error: se devuelve el texto que había (nunca quedar sin transcripción)
                var back = project
                (back.words, back.transcribedLanes, back.wordsSynced) = backup
                project = back
                throw error
            }
            project.wordsSynced = true
            if project.sensitiveScanned {
                project.sensitive = SensitiveWords.scan(project).map { m in
                    guard let old = previous.first(where: { $0.lane == m.lane && abs($0.s - m.s) < 0.8
                                                          && $0.word.lowercased() == m.word.lowercased() }) else { return m }
                    var out = m
                    out.bleep = old.bleep; out.replace = old.replace; out.replacement = old.replacement; out.ignored = old.ignored
                    return out
                }
            }
            let redid = try await redoAutoCuts()
            captionsNote = String(localized: "Listo: escribimos la transcripción de nuevo y la ajustamos al audio.")
                + (redid ? String(localized: " También volvimos a buscar los silencios.") : "")
            schedulePreview(immediate: true)
        }
    }

    /// Vuelve a escuchar solo el tramo de un reel y le deja ese texto propio (el episodio no cambia).
    func relistenReel(_ reel: Reel) {
        run(String(localized: "Escuchando el reel de nuevo")) { [self] in
            var words = try await SubtitleSync.listen(project: project, from: reel.start, to: reel.end) { [weak self] detail, f in
                self?.reportAsync(String(localized: "Escuchando el reel de nuevo"), detail, f)
            }
            report(String(localized: "Ajustando los subtítulos al audio"), "", nil)
            words = try await SubtitleSync.align(words, project: project).words.sorted { $0.s < $1.s }
            guard let i = project.reels.firstIndex(where: { $0.id == reel.id }) else { return }
            project.reels[i].words = words
            if project.reels[i].cuts.contains(where: { $0.kind == .silence }) {
                try await ensureEnergy()
                let found = reelSilences(project.reels[i])
                project.reels[i].cuts.removeAll { $0.kind == .silence }
                project.reels[i].cuts += found
            }
            if previewReel?.id == reel.id { previewReel = project.reels[i] }
            reelsNote = words.isEmpty
                ? String(localized: "No escuchamos palabras en este reel.")
                : String(localized: "Listo: este reel tiene su propio texto (\(words.count) palabras), ajustado al audio. El episodio no cambió.")
            schedulePreview(immediate: true)
        }
    }

    /// Deja que el reel vuelva a usar el texto del episodio.
    func useEpisodeText(_ reel: Reel) {
        guard let i = project.reels.firstIndex(where: { $0.id == reel.id }) else { return }
        project.reels[i].words = nil
        if previewReel?.id == reel.id { previewReel = project.reels[i] }
        schedulePreview(immediate: true)
    }

    static func ms(_ seconds: Double) -> String {
        let txt = String(format: "%.2f", abs(seconds)).replacingOccurrences(of: ".", with: ",") + " s"
        return seconds >= 0 ? String(localized: "\(txt) más tarde") : String(localized: "\(txt) antes")
    }

    func updatePhrase(_ phrase: Phrase, text: String) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return }
        let reelIndex = phrase.reelId.flatMap { id in project.reels.firstIndex { $0.id == id } }
        var words = reelIndex.flatMap { project.reels[$0].words } ?? project.words
        guard phrase.range.upperBound <= words.count else { return }
        let old = Array(words[phrase.range])
        // Las palabras que quedan iguales conservan su tiempo; solo las nuevas se reparten en su hueco
        // (antes se repartía toda la frase en partes iguales y los subtítulos dejaban de coincidir con la voz).
        words.replaceSubrange(phrase.range, with: EditEngine.retime(old: old, tokens: tokens, lane: phrase.lane))
        if let reelIndex {
            project.reels[reelIndex].words = words
            if previewReel?.id == project.reels[reelIndex].id { previewReel = project.reels[reelIndex] }
        } else {
            project.words = words
        }
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
