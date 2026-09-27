import SwiftUI
import AVFoundation

struct JobState: Equatable {
    var title: String
    var detail: String = ""
    var fraction: Double? = nil      // nil = indeterminate
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var session: ProjectSession?
    @Published var importJob: JobState?
    @Published var errorMessage: String?
    /// true cuando terminó la entrada de thePod (o está apagada): recién ahí se consulta la cuenta.
    @Published var introDone = SelfTest.isRequested || !UserDefaults.standard.bool(forKey: "introAlAbrir", default: true)
    private var importTask: Task<Void, Never>?

    init() { reload() }

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
    case overview, fix, captions, sounds, reels, export, publish
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Tu grabación"
        case .fix: return "Arreglar"
        case .captions: return "Subtítulos"
        case .sounds: return "Efectos"
        case .reels: return "Reels"
        case .export: return "Exportar"
        case .publish: return "Publicar"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "person.2.wave.2"
        case .fix: return "wand.and.stars"
        case .captions: return "captions.bubble"
        case .sounds: return "speaker.wave.3"
        case .reels: return "iphone.gen3"
        case .export: return "square.and.arrow.up"
        case .publish: return "paperplane"
        }
    }
    var number: Int { (Step.allCases.firstIndex(of: self) ?? 0) + 1 }
}

@MainActor
final class ProjectSession: ObservableObject {
    @Published var project: Project { didSet { if project != oldValue { dirty() } } }
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
        let current = player.currentTime().seconds
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
                target = EditEngine.toOutput(tl, keep: b.keep) ?? min(current, b.duration)
            }
            if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if wasPlaying { player.play() }
        } catch {
            built = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Seek preview to a TIMELINE time.
    func seek(timeline t: Double, play: Bool = true) {
        guard let b = built else { return }
        let o = EditEngine.toOutput(t, keep: b.keep)
            ?? b.keep.firstIndex { $0.start >= t }.map { i in EditEngine.outputDuration(Array(b.keep.prefix(i))) }
            ?? 0
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
        return EditEngine.toTimeline(t, keep: b.keep)
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
