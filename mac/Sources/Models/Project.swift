import Foundation

// MARK: - Project model
//
// "Timeline time" = seconds on the original recording timeline (all lanes start at 0,
// like prodPod's synced per-host recordings). Cuts are expressed in timeline time.
// "Output time" = seconds in the rendered file, after removing cuts.

struct Project: Codable, Identifiable, Equatable {
    var id: String                      // slug (folder name)
    var name: String
    var podcastName: String?
    var createdAt: Date
    var importedFrom: String            // "postpod-bundle" | "tracks"

    var media: [SourceMedia] = []
    var lanes: [Lane] = []              // one camera/mic lane per participant
    var audioLane: [AudioLaneClip] = [] // music / SFX placed on the timeline
    var participants: [Participant] = []

    var language: String = "es"
    var words: [Word] = []              // merged transcript, timeline time
    var transcribedLanes: [Int] = []    // lane ids already transcribed

    var cuts: [Cut] = []
    var fix = FixSettings()
    var enhanceAudio: Bool = false      // true once enhanced audio files exist and are in use

    var captionStyle = CaptionStyle()
    var layout: LayoutTemplate = .auto
    var reelLayout: LayoutTemplate = .auto
    var showNames: Bool = true
    var showLogo: Bool = true
    var laneCrop: [Int: Double] = [:]   // lane id -> horizontal crop center 0...1 for vertical

    var episode = EpisodeInfo()         // from prePod (via postPod's proyecto.json)
    var sponsors: [Sponsor] = []
    var segments: [Segment] = []        // script blocks with timing (prePod "blocks")
    var showSponsors: Bool = true
    var cintillos: [DirectorCintillo] = []   // cintillos que el director puso en vivo (prodPod)
    var showCintillos: Bool = true
    var sfxLibrary: [String] = []       // relative paths of sound effects available for this project
    var sfxNames: [String: String] = [:] // nombre de cada sonido en el soundboard de prodPod
    var moments: [Moment] = []          // "Momentos" marcados en postPod/prodPod → fuente de los reels
    var reels: [Reel] = []
    var aiSummary: String?

    var logoFile: String?               // relative to project folder
    var backgroundFile: String?
    var postpodSlug: String?            // proyecto de postPod web del que se descargó

    var duration: Double {
        let laneEnd = lanes.map { $0.duration }.max() ?? 0
        let audioEnd = audioLane.map { $0.tlStart + ($0.srcOut - $0.srcIn) }.max() ?? 0
        return max(laneEnd, audioEnd)
    }

    func mediaItem(_ id: Int) -> SourceMedia? { media.first { $0.id == id } }

    func laneName(_ laneId: Int) -> String {
        if let lane = lanes.first(where: { $0.id == laneId }) {
            if let pid = lane.participantId, let p = participants.first(where: { $0.id == pid }) {
                return p.name
            }
            return lane.name
        }
        return "Pista \(laneId)"
    }

    func participant(forLane laneId: Int) -> Participant? {
        guard let lane = lanes.first(where: { $0.id == laneId }), let pid = lane.participantId else { return nil }
        return participants.first { $0.id == pid }
    }

    var isTranscribed: Bool { !words.isEmpty }
    var enabledCuts: [Cut] { cuts.filter { $0.enabled } }
}

struct SourceMedia: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case video, audio, image }
    var id: Int
    var originalName: String
    var file: String                    // playable file, relative to project folder
    var kind: Kind
    var duration: Double
    var hasAudio: Bool = true
    var hasVideo: Bool = true
    var enhancedAudioFile: String?      // relative, produced by "Mejorar audio"
    var transcriptionAudioFile: String? // 16 kHz mono wav for Whisper
    var startOffset: Double = 0         // recording started this late vs. the others (lost head chunk)
}

extension SourceMedia {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        originalName = try c.decode(String.self, forKey: .originalName)
        file = try c.decode(String.self, forKey: .file)
        kind = try c.decode(Kind.self, forKey: .kind)
        duration = try c.decode(Double.self, forKey: .duration)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        hasVideo = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? true
        enhancedAudioFile = try c.decodeIfPresent(String.self, forKey: .enhancedAudioFile)
        transcriptionAudioFile = try c.decodeIfPresent(String.self, forKey: .transcriptionAudioFile)
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? 0
    }
}

extension Lane {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        participantId = try c.decodeIfPresent(Int.self, forKey: .participantId)
        clips = try c.decode([LaneClip].self, forKey: .clips)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }
}

struct Lane: Codable, Identifiable, Equatable {
    var id: Int                         // 1-based track number
    var name: String
    var participantId: Int?
    var clips: [LaneClip]               // played back-to-back starting at `offset`
    var volume: Double = 1.0
    var offset: Double = 0              // timeline time where this person's recording starts

    var duration: Double { offset + clips.reduce(0) { $0 + $1.length } }

    /// Timeline spans of each clip.
    var placed: [(clip: LaneClip, tlStart: Double, tlEnd: Double)] {
        var t = offset
        return clips.map { c in
            defer { t += c.length }
            return (c, t, t + c.length)
        }
    }

    var primaryMediaId: Int? { clips.first?.mediaId }
}

struct LaneClip: Codable, Equatable {
    var mediaId: Int
    var srcIn: Double
    var srcOut: Double
    var volume: Double = 1.0
    var length: Double { max(0, srcOut - srcIn) }
}

struct AudioLaneClip: Codable, Identifiable, Equatable {
    var id: Int
    var mediaId: Int
    var tlStart: Double
    var srcIn: Double
    var srcOut: Double
    var volume: Double = 0.7
}

struct Participant: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var role: String = "guest"
    var track: Int?
    var instagram: String?
    var twitter: String?
    var youtube: String?
    var tiktok: String?
    var photoFile: String?              // foto del invitado (de prePod), relativa al proyecto

    var handle: String? {
        for h in [instagram, tiktok, twitter, youtube] {
            if let h, !h.trimmingCharacters(in: .whitespaces).isEmpty {
                let clean = h.trimmingCharacters(in: .whitespaces)
                if clean.contains("/") { return clean.split(separator: "/").last.map { "@" + $0 } }
                return clean.hasPrefix("@") ? clean : "@" + clean
            }
        }
        return nil
    }
}

/// Same shape as postPod's words.json ("w","s","e","p") plus the lane it came from.
struct Word: Codable, Equatable, Hashable {
    var w: String
    var s: Double
    var e: Double
    var p: Double = 1.0
    var lane: Int = 1
}

struct Cut: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case silence, filler, manual, imported }
    var id = UUID()
    var start: Double
    var end: Double
    var kind: Kind
    var enabled: Bool = true
    var label: String = ""
    var length: Double { max(0, end - start) }
}

struct FixSettings: Codable, Equatable {
    var removeSilences = true
    var removeFillers = true
    var removeWordFillers = false       // "este", "o sea", "pues"... off by default
    var enhanceAudio = true
    var minSilence: Double = 0.8        // seconds of silence before we cut
    var keepPad: Double = 0.18          // breathing room kept around speech
    var lastRun: Date?
}

struct Reel: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var reason: String = ""
    var start: Double                   // timeline time
    var end: Double
    var selected: Bool = true
    var exportedFile: String?
    var length: Double { max(0, end - start) }
}

enum LayoutTemplate: String, Codable, CaseIterable, Identifiable {
    case auto, solo, sideBySide, grid, spotlight, pip, stack, studio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automático"
        case .solo: return "Quien habla"
        case .sideBySide: return "Lado a lado"
        case .grid: return "Cuadrícula"
        case .spotlight: return "Protagonista"
        case .pip: return "Ventanita"
        case .stack: return "Arriba y abajo"
        case .studio: return "Estudio"
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .solo: return "person.fill"
        case .sideBySide: return "rectangle.split.2x1"
        case .grid: return "square.grid.2x2"
        case .spotlight: return "rectangle.lefthalf.inset.filled"
        case .pip: return "pip"
        case .stack: return "rectangle.split.1x2"
        case .studio: return "photo.artframe"
        }
    }
    var help: String {
        switch self {
        case .auto: return "Elegimos el mejor según el formato"
        case .solo: return "Pantalla completa para quien está hablando"
        case .sideBySide: return "Todos a la vez, uno al lado del otro"
        case .grid: return "Todos en cuadrícula"
        case .spotlight: return "Quien habla en grande, el resto al costado"
        case .pip: return "Quien habla en grande, otro en una esquina"
        case .stack: return "Uno arriba y otro abajo (ideal vertical)"
        case .studio: return "Las cámaras en recuadros sobre el fondo de tu podcast"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case landscape, vertical, square, audio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: return "YouTube"
        case .vertical: return "Reels · TikTok · Shorts"
        case .square: return "Instagram cuadrado"
        case .audio: return "Solo audio (MP3)"
        }
    }
    var subtitle: String {
        switch self {
        case .landscape: return "Horizontal 16:9 · 1080p"
        case .vertical: return "Vertical 9:16 · 1080×1920"
        case .square: return "Cuadrado 1:1 · 1080×1080"
        case .audio: return "Para Spotify, Apple Podcasts…"
        }
    }
    var symbol: String {
        switch self {
        case .landscape: return "play.rectangle.fill"
        case .vertical: return "iphone"
        case .square: return "square.fill"
        case .audio: return "waveform"
        }
    }
    var renderSize: CGSize {
        switch self {
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .audio: return CGSize(width: 16, height: 16)
        }
    }
    var isVertical: Bool { self == .vertical }
    var fileSuffix: String {
        switch self {
        case .landscape: return "youtube"
        case .vertical: return "vertical"
        case .square: return "cuadrado"
        case .audio: return "audio"
        }
    }
}

/// Episode data that prePod sends to postPod.
struct EpisodeInfo: Codable, Equatable {
    var number: Int?
    var title: String?
    var description: String?
    var podcastDescription: String?
    var scheduledDate: String?
    var script: [ScriptItem] = []
    var links: [String] = []
    // Where this episode lives in prePod (for publishing)
    var prepodURL: String?
    var prepodSlug: String?
    var prepodEpisodeId: Int?
    // Last publish results
    var publishedAudioURL: String?
    var publishedYouTubeURL: String?
}

/// One piece of the prePod script (free-form: title and/or text).
struct ScriptItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
}

/// Cintillo tipo noticiero que el director lanzó durante la grabación.
struct DirectorCintillo: Codable, Equatable, Identifiable {
    var id: Int
    var kind: String            // sponsor | banner | segment | comment
    var title: String
    var text: String
    var start: Double           // segundos desde que empezó la grabación
    var duration: Double
    var logoFile: String?       // relativo a la carpeta del proyecto
}

struct Sponsor: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var copy: String?
    var url: String?
    var logoFile: String?               // relative to project folder, if the bundle brought it
}

struct Segment: Codable, Equatable, Identifiable {
    var id: Int
    var position: Int
    var kind: String
    var title: String
    var durationEstimate: Double?
    var sponsorId: Int?
    var notes: String?
    var actualOffset: Double?           // real start in the recording (prodPod chapters)
    var plannedOffset: Double?          // planned start from prePod
}

/// A moment marked in postPod (or prodPod chapters). Point moments have no duration.
struct Moment: Codable, Identifiable, Equatable {
    var id: Int
    var time: Double                    // timeline seconds
    var duration: Double?
    var label: String
}

extension Project {
    /// Tolerant decoding: projects saved by older versions keep opening when new fields appear.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        podcastName = try c.decodeIfPresent(String.self, forKey: .podcastName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom) ?? "tracks"
        media = try c.decodeIfPresent([SourceMedia].self, forKey: .media) ?? []
        lanes = try c.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
        audioLane = try c.decodeIfPresent([AudioLaneClip].self, forKey: .audioLane) ?? []
        participants = try c.decodeIfPresent([Participant].self, forKey: .participants) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "es"
        words = try c.decodeIfPresent([Word].self, forKey: .words) ?? []
        transcribedLanes = try c.decodeIfPresent([Int].self, forKey: .transcribedLanes) ?? []
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        fix = try c.decodeIfPresent(FixSettings.self, forKey: .fix) ?? FixSettings()
        enhanceAudio = try c.decodeIfPresent(Bool.self, forKey: .enhanceAudio) ?? false
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle) ?? CaptionStyle()
        layout = try c.decodeIfPresent(LayoutTemplate.self, forKey: .layout) ?? .auto
        reelLayout = try c.decodeIfPresent(LayoutTemplate.self, forKey: .reelLayout) ?? .auto
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? true
        showLogo = try c.decodeIfPresent(Bool.self, forKey: .showLogo) ?? true
        laneCrop = try c.decodeIfPresent([Int: Double].self, forKey: .laneCrop) ?? [:]
        moments = try c.decodeIfPresent([Moment].self, forKey: .moments) ?? []
        episode = try c.decodeIfPresent(EpisodeInfo.self, forKey: .episode) ?? EpisodeInfo()
        sponsors = try c.decodeIfPresent([Sponsor].self, forKey: .sponsors) ?? []
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        showSponsors = try c.decodeIfPresent(Bool.self, forKey: .showSponsors) ?? true
        cintillos = try c.decodeIfPresent([DirectorCintillo].self, forKey: .cintillos) ?? []
        showCintillos = try c.decodeIfPresent(Bool.self, forKey: .showCintillos) ?? true
        sfxLibrary = try c.decodeIfPresent([String].self, forKey: .sfxLibrary) ?? []
        sfxNames = try c.decodeIfPresent([String: String].self, forKey: .sfxNames) ?? [:]
        reels = try c.decodeIfPresent([Reel].self, forKey: .reels) ?? []
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
        logoFile = try c.decodeIfPresent(String.self, forKey: .logoFile)
        backgroundFile = try c.decodeIfPresent(String.self, forKey: .backgroundFile)
        postpodSlug = try c.decodeIfPresent(String.self, forKey: .postpodSlug)
    }

    /// When each sponsor appears (timeline time) — same rule as postPod web's exporter:
    /// the block's real offset if prodPod marked it, otherwise the sum of estimated durations.
    func sponsorAppearances(seconds: Double = 6) -> [(sponsor: Sponsor, start: Double, end: Double)] {
        var cursor = 0.0
        var out: [(Sponsor, Double, Double)] = []
        for seg in segments.sorted(by: { $0.position < $1.position }) {
            defer { cursor += seg.durationEstimate ?? 0 }
            guard let sid = seg.sponsorId, let sp = sponsors.first(where: { $0.id == sid }) else { continue }
            let t0 = seg.actualOffset ?? seg.plannedOffset ?? cursor
            guard t0 < duration else { continue }
            out.append((sp, t0, min(duration, t0 + seconds)))
        }
        return out
    }

    /// Chapters for YouTube descriptions: moments with labels, else script blocks with real offsets.
    var chapters: [(time: Double, title: String)] {
        let fromMoments = moments.filter { !$0.label.isEmpty }.map { ($0.time, $0.label) }
        if !fromMoments.isEmpty { return fromMoments.sorted { $0.0 < $1.0 } }
        return segments.compactMap { s in s.actualOffset.map { ($0, s.title) } }.filter { !$0.1.isEmpty }.sorted { $0.0 < $1.0 }
    }

    /// Same rule as postPod web (exportMoment): the moment's own duration, or until the next moment.
    func reelsFromMoments() -> [Reel] {
        let sorted = moments.sorted { $0.time < $1.time }
        return sorted.enumerated().compactMap { (i, m) in
            let start = max(0, m.time)
            var end: Double
            if let d = m.duration, d > 0 { end = start + d }
            else { end = i + 1 < sorted.count ? sorted[i + 1].time : duration }
            end = min(end, duration)
            guard end > start + 1 else { return nil }
            let title = m.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return Reel(title: title.isEmpty ? "Momento \(i + 1)" : title,
                        reason: "Momento marcado en postPod", start: start, end: end)
        }
    }
}

// MARK: - Captions

struct CaptionStyle: Codable, Equatable {
    enum Size: String, Codable, CaseIterable { case small, medium, large }
    enum Position: String, Codable, CaseIterable { case top, center, bottom }

    var enabled = true
    var preset: String = "clasico"
    var fontName: String = "HelveticaNeue-Bold"   // PostScript name
    var size: Size = .medium
    var textColor: String = "#FFFFFF"
    var outlineColor: String = "#000000"
    var backgroundColor: String?        // nil = no box
    var highlightColor: String = "#FFD700"
    var position: Position = .bottom
    var uppercase = false
    var karaoke = true                  // highlight the word being said

    static let presets: [(id: String, title: String, style: CaptionStyle)] = {
        var clasico = CaptionStyle()
        clasico.preset = "clasico"

        var tiktok = CaptionStyle()
        tiktok.preset = "tiktok"
        tiktok.fontName = "LuckiestGuy-Regular"
        tiktok.size = .large
        tiktok.uppercase = true
        tiktok.highlightColor = "#FFE14D"
        tiktok.position = .center

        var comic = CaptionStyle()
        comic.preset = "comic"
        comic.fontName = "Bangers-Regular"
        comic.size = .large
        comic.highlightColor = "#5CE1E6"

        var caja = CaptionStyle()
        caja.preset = "caja"
        caja.fontName = "HelveticaNeue-Bold"
        caja.backgroundColor = "#000000"
        caja.outlineColor = "#000000"
        caja.highlightColor = "#FF5757"

        var minimal = CaptionStyle()
        minimal.preset = "minimal"
        minimal.fontName = "HelveticaNeue-Medium"
        minimal.size = .small
        minimal.karaoke = false

        return [("clasico", "Clásico", clasico),
                ("tiktok", "TikTok", tiktok),
                ("comic", "Cómic", comic),
                ("caja", "Caja negra", caja),
                ("minimal", "Discreto", minimal)]
    }()
}

/// A line of on-screen captions in OUTPUT time.
struct CaptionLine: Equatable {
    struct W: Equatable { var text: String; var start: Double; var end: Double }
    var start: Double
    var end: Double
    var words: [W]
    var text: String { words.map(\.text).joined(separator: " ") }
}

/// Active speaker change in OUTPUT time.
struct SpeakerSwitch: Equatable { var time: Double; var lane: Int }
