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
    var layoutOptions = LayoutOptions()  // ajustes de cada diseño (marco de estudio, quien habla en grande…)
    var reelLayout: LayoutTemplate = .auto   // (viejo) ahora vive en reelLook.layout
    var reelLook = ReelLook()           // diseño y marca para todos los reels (cada reel puede tener el suyo)
    var showBackground: Bool = true     // usar la imagen de fondo del podcast detrás del video
    var intro: Bumper?                  // imagen (y música) antes del video
    var colorLook: String = "none"      // none | warm | cool | cine | bw | vivid
    var matchColors = false             // igualar el color de las cámaras
    var laneColorGain: [Int: [Double]] = [:]   // lane id -> [r, g, b] (calculado al activar matchColors)
    var exportHEVC = false              // archivo más liviano (HEVC) en vez de compatible (H.264)
    var normalizeLoudness = true        // ajustar el volumen final a −16 LUFS
    var outro: Bumper?                  // imagen (y música) al final
    var showNames: Bool = true
    var showLogo: Bool = true
    var laneCrop: [Int: Double] = [:]   // lane id -> horizontal crop center 0...1 for vertical
    var laneMirror: [Int: Bool] = [:]   // lane id -> voltear el video en espejo (horizontal)
    var laneBackground: [Int: VirtualBackground] = [:]   // lane id -> fondo virtual (quitar el fondo real de esa persona)
    var laneOrder: [Int] = []           // orden en pantalla (ids de pista); vacío = el orden de las pistas

    var episode = EpisodeInfo()         // from prePod (via postPod's proyecto.json)
    var sponsors: [Sponsor] = []
    var segments: [Segment] = []        // script blocks with timing (prePod "blocks")
    var showSponsors: Bool = true
    var cintillos: [DirectorCintillo] = []   // cintillos que el director puso en vivo (prodPod)
    var showCintillos: Bool = true
    var overlays: [VideoLayer] = []        // textos, imágenes y stickers encima del video
    var brolls: [BRollClip] = []           // b-roll: un video o imagen que tapa la pantalla un rato (la voz sigue)
    var sfxLibrary: [String] = []       // relative paths of sound effects available for this project
    var sfxNames: [String: String] = [:] // nombre de cada sonido en el soundboard de prodPod
    var moments: [Moment] = []          // "Momentos" marcados en postPod/prodPod → fuente de los reels
    var reels: [Reel] = []
    var aiSummary: String?

    var logoFile: String?               // relative to project folder
    var backgroundFile: String?
    var postpodSlug: String?            // proyecto de postPod web del que se descargó

    var duration: Double {
        // El episodio dura lo que duran las grabaciones de las personas. Una música más larga se corta al final
        // (antes alargaba el episodio y la música seguía sola, sin video, antes del cierre).
        let laneEnd = lanes.map { $0.duration }.max() ?? 0
        if laneEnd > 0 { return laneEnd }
        return audioLane.map { $0.tlStart + ($0.srcOut - $0.srcIn) }.max() ?? 0
    }

    func mediaItem(_ id: Int) -> SourceMedia? { media.first { $0.id == id } }

    /// Pistas en el orden en que van en pantalla (izquierda→derecha / arriba→abajo). Las que no estén en `laneOrder` van al final.
    var lanesOnScreen: [Lane] {
        let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        var out = laneOrder.compactMap { byId[$0] }
        for l in lanes where !out.contains(where: { $0.id == l.id }) { out.append(l) }
        return out
    }

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
    var eqAudioFile: String?            // audio con el ecualizador de la persona aplicado
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
        eqAudioFile = try c.decodeIfPresent(String.self, forKey: .eqAudioFile)
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
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        eq = try c.decodeIfPresent(VoiceEQ.self, forKey: .eq) ?? VoiceEQ()
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
    }
}

extension Project {
    /// Si una persona se oye, contando mudo y solo.
    func laneAudible(_ lane: Lane) -> Bool {
        if lane.muted { return false }
        let anySolo = lanes.contains { $0.solo }
        return !anySolo || lane.solo
    }
}

/// Ecualizador sencillo de voz. Todo en 0 = sin cambios.
struct VoiceEQ: Codable, Equatable {
    var low: Double = 0                 // graves (dB, ~120 Hz)
    var mid: Double = 0                 // medios (dB, ~1 kHz)
    var high: Double = 0                // agudos (dB, ~6 kHz)
    var rumbleCut = false               // quitar retumbe (corte bajo 120 Hz + menos 250 Hz)
    var isFlat: Bool { abs(low) < 0.1 && abs(mid) < 0.1 && abs(high) < 0.1 && !rumbleCut }
    static func preset(_ id: String) -> VoiceEQ {
        var e = VoiceEQ()
        switch id {
        case "warm": e.low = 2; e.mid = 0; e.high = -1
        case "clear": e.low = -2; e.mid = 1; e.high = 3
        case "rumble": e.rumbleCut = true; e.high = 1
        default: break
        }
        return e
    }
    /// Firma corta para nombrar el archivo procesado.
    var key: String { String(format: "l%+.1fm%+.1fh%+.1f%@", low, mid, high, rumbleCut ? "r" : "") }
    var ffmpegFilter: String {
        var f: [String] = []
        if rumbleCut { f += ["highpass=f=120", "equalizer=f=250:t=q:w=1:g=-3"] }
        if abs(low) >= 0.1 { f.append(String(format: "equalizer=f=120:t=q:w=0.8:g=%.1f", low)) }
        if abs(mid) >= 0.1 { f.append(String(format: "equalizer=f=1000:t=q:w=1:g=%.1f", mid)) }
        if abs(high) >= 0.1 { f.append(String(format: "equalizer=f=6000:t=q:w=0.8:g=%.1f", high)) }
        f.append("alimiter=limit=0.95:level=0")
        return f.joined(separator: ",")
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 0
        mid = try c.decodeIfPresent(Double.self, forKey: .mid) ?? 0
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 0
        rumbleCut = try c.decodeIfPresent(Bool.self, forKey: .rumbleCut) ?? false
    }
}

struct Lane: Codable, Identifiable, Equatable {
    var id: Int                         // 1-based track number
    var name: String
    var participantId: Int?
    var clips: [LaneClip]               // played back-to-back starting at `offset`
    var volume: Double = 1.0
    var offset: Double = 0              // timeline time where this person's recording starts
    var fadeIn: Double = 0              // segundos de entrada suave del audio de esta persona
    var fadeOut: Double = 0             // segundos de salida suave
    var eq = VoiceEQ()                  // ecualizador de 3 bandas (se aplica procesando el audio)
    var muted: Bool = false             // M: esta persona no suena (vista previa y export)
    var solo: Bool = false              // S: solo suenan las personas con solo

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
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var duck: Bool?                     // bajar bajo la voz; nil = automático (sí si dura más de 8 s: música, no efectos)
    var duckDB: Double = 12
    var loop: Bool = false              // repetir en bucle hasta el final del episodio
    var ducks: Bool { duck ?? ((srcOut - srcIn) > 8) }
    init(id: Int, mediaId: Int, tlStart: Double, srcIn: Double, srcOut: Double, volume: Double = 0.7, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.mediaId = mediaId; self.tlStart = tlStart; self.srcIn = srcIn; self.srcOut = srcOut
        self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        tlStart = try c.decode(Double.self, forKey: .tlStart)
        srcIn = try c.decodeIfPresent(Double.self, forKey: .srcIn) ?? 0
        srcOut = try c.decode(Double.self, forKey: .srcOut)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.7
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        duck = try c.decodeIfPresent(Bool.self, forKey: .duck)
        duckDB = try c.decodeIfPresent(Double.self, forKey: .duckDB) ?? 12
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
    }
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
    var strongNoise = false             // reducción de ruido con red neuronal (perro, teclas) en vez de la suave
    var gateOthers = true               // bajar la pista de quien no está hablando (teclas y ruidos del otro)
    var minSilence: Double = 0.8        // seconds of silence before we cut
    var keepPad: Double = 0.18          // breathing room kept around speech
    var lastRun: Date?
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removeSilences = try c.decodeIfPresent(Bool.self, forKey: .removeSilences) ?? true
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        removeWordFillers = try c.decodeIfPresent(Bool.self, forKey: .removeWordFillers) ?? false
        enhanceAudio = try c.decodeIfPresent(Bool.self, forKey: .enhanceAudio) ?? true
        strongNoise = try c.decodeIfPresent(Bool.self, forKey: .strongNoise) ?? false
        gateOthers = try c.decodeIfPresent(Bool.self, forKey: .gateOthers) ?? true
        minSilence = try c.decodeIfPresent(Double.self, forKey: .minSilence) ?? 0.8
        keepPad = try c.decodeIfPresent(Double.self, forKey: .keepPad) ?? 0.18
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
    }
}

struct Reel: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var reason: String = ""
    var start: Double                   // timeline time
    var end: Double
    var selected: Bool = true
    var exportedFile: String?
    var look: ReelLook?                 // diseño propio de este reel (nil = el de todos los reels)
    var cuts: [Cut] = []                // cortes solo de este reel (frases quitadas, silencios), aparte de los del episodio
    var brolls: [BRollClip] = []        // b-roll solo de este reel
    var music: [AudioLaneClip] = []     // música propia del reel (se usa cuando el reel no lleva la del episodio)
    var cintillos: [DirectorCintillo] = []   // cintillos solo de este reel
    var length: Double { max(0, end - start) }

    init(id: UUID = UUID(), title: String, reason: String = "", start: Double, end: Double, selected: Bool = true, exportedFile: String? = nil, look: ReelLook? = nil) {
        self.id = id; self.title = title; self.reason = reason; self.start = start; self.end = end
        self.selected = selected; self.exportedFile = exportedFile; self.look = look
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Reel"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        exportedFile = try c.decodeIfPresent(String.self, forKey: .exportedFile)
        look = try c.decodeIfPresent(ReelLook.self, forKey: .look)
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        brolls = try c.decodeIfPresent([BRollClip].self, forKey: .brolls) ?? []
        music = try c.decodeIfPresent([AudioLaneClip].self, forKey: .music) ?? []
        cintillos = try c.decodeIfPresent([DirectorCintillo].self, forKey: .cintillos) ?? []
    }
}

/// Fondo virtual de una persona: se separa a la persona de su fondo real (Apple Vision, en la Mac, sin internet)
/// y detrás se pone lo que se elija.
struct VirtualBackground: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case blur, podcast, color, image
        var name: String {
            switch self { case .blur: return "Difuminado"; case .podcast: return "Fondo del podcast"; case .color: return "Color"; case .image: return "Imagen" }
        }
    }
    var mode: Mode = .blur
    var blur: Double = 18               // difuminado: cuánto (6 suave … 40 muy borroso)
    var color: String = "#14141A"
    var imageFile: String?              // relativo a la carpeta del proyecto
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .blur
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 18
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#14141A"
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
    }
}

/// Cómo se ve un reel: diseño, sus opciones y la marca (fondo, logo, nombres), aparte del episodio.
/// `logoFile` y `backgroundFile` son un logo y un fondo solo para reels; si están vacíos se usan los del podcast.
struct ReelLook: Codable, Equatable {
    var layout: LayoutTemplate = .auto
    var options = LayoutOptions()
    var showBackground: Bool = true
    var showLogo: Bool = true
    var showNames: Bool = true
    var logoFile: String?
    var backgroundFile: String?
    var music: Bool = true              // música y efectos del episodio en el reel
    var captions: Bool = true           // subtítulos en el reel
    var captionStyle: CaptionStyle?     // estilo y posición propios de los subtítulos en el reel (nil = los del episodio)
    var laneOrder: [Int]?               // orden en pantalla propio (nil = el del episodio)
    var gateOthers: Bool?               // silenciar a quien no habla, propio (nil = como en Limpiar sonido)
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        music = try c.decodeIfPresent(Bool.self, forKey: .music) ?? true
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions) ?? true
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
        laneOrder = try c.decodeIfPresent([Int].self, forKey: .laneOrder)
        gateOthers = try c.decodeIfPresent(Bool.self, forKey: .gateOthers)
        layout = try c.decodeIfPresent(LayoutTemplate.self, forKey: .layout) ?? .auto
        options = try c.decodeIfPresent(LayoutOptions.self, forKey: .options) ?? LayoutOptions()
        showBackground = try c.decodeIfPresent(Bool.self, forKey: .showBackground) ?? true
        showLogo = try c.decodeIfPresent(Bool.self, forKey: .showLogo) ?? true
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? true
        logoFile = try c.decodeIfPresent(String.self, forKey: .logoFile)
        backgroundFile = try c.decodeIfPresent(String.self, forKey: .backgroundFile)
    }
}

extension Project {
    /// El diseño que le toca a un reel: el suyo si tiene, si no el de todos los reels.
    func look(for reel: Reel?) -> ReelLook { reel?.look ?? reelLook }

    /// Copia del proyecto con el aspecto de un reel puesto encima (para la vista previa y el export de ese reel).
    /// Con `reel` también entran sus cortes propios.
    func applying(_ look: ReelLook, reel: Reel? = nil) -> Project {
        var p = self
        if let reel {
            p.cuts += reel.cuts
            p.brolls += reel.brolls
            if !reel.cintillos.isEmpty { p.cintillos += reel.cintillos; p.showCintillos = true }
        }
        if let o = look.laneOrder { p.laneOrder = o }
        if let g = look.gateOthers { p.fix.gateOthers = g }
        p.layout = look.layout
        p.layoutOptions = look.options
        p.showBackground = look.showBackground
        p.showLogo = look.showLogo
        p.showNames = look.showNames
        if let f = look.logoFile { p.logoFile = f }
        if let f = look.backgroundFile { p.backgroundFile = f }
        if !look.music { p.audioLane = reel?.music ?? [] }   // sin la del episodio: la propia del reel (si tiene)
        if let cs = look.captionStyle { p.captionStyle = cs }
        if !look.captions { p.captionStyle.enabled = false }
        return p
    }
}

/// Intro o cierre: una imagen fija unos segundos, con música opcional (relativa a la carpeta del proyecto).
struct Bumper: Codable, Equatable {
    var imageFile: String
    var seconds: Double = 4
    var musicFile: String?
    var musicVolume: Double = 0.8
    init(imageFile: String, seconds: Double = 4, musicFile: String? = nil, musicVolume: Double = 0.8) {
        self.imageFile = imageFile; self.seconds = seconds; self.musicFile = musicFile; self.musicVolume = musicVolume
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageFile = try c.decode(String.self, forKey: .imageFile)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 4
        musicFile = try c.decodeIfPresent(String.self, forKey: .musicFile)
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.8
    }
}

/// Ajustes de los diseños. Cada campo tiene valor por defecto para que los proyectos viejos abran igual.
struct LayoutOptions: Codable, Equatable {
    var soloStudio: Bool = false        // Quien habla: un recuadro con marco sobre el fondo del podcast (sin recortar el video)
    var gridSpeakerBig: Bool = false    // Cuadrícula: quien habla en grande arriba, los demás en cuadritos abajo
    var pipFollowSpeaker: Bool = true   // Ventanita: en grande quien habla (si no, siempre la primera persona)
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soloStudio = try c.decodeIfPresent(Bool.self, forKey: .soloStudio) ?? false
        gridSpeakerBig = try c.decodeIfPresent(Bool.self, forKey: .gridSpeakerBig) ?? false
        pipFollowSpeaker = try c.decodeIfPresent(Bool.self, forKey: .pipFollowSpeaker) ?? true
    }
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

/// Capa encima del video: un texto, una imagen o un sticker (emoji), en un momento del episodio.
/// `start` es tiempo del episodio (como los cintillos): si se corta ese trozo, sale en lo siguiente que quede.
struct VideoLayer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, sticker }
    /// Estilos de texto: título grande con contorno, texto en caja oscura, etiqueta de color.
    enum Style: String, Codable, CaseIterable { case title, box, label
        var name: String { switch self { case .title: return "Título"; case .box: return "Caja"; case .label: return "Etiqueta" } }
    }
    var id: Int
    var kind: Kind
    var start: Double
    var duration: Double = 5
    var text: String = ""
    var style: Style = .title
    var color: String = "#FFFFFF"       // título/caja: color del texto · etiqueta: color de fondo
    var imageFile: String?              // relativo a la carpeta del proyecto
    var x: Double = 0.5                 // centro, 0 = izquierda … 1 = derecha
    var y: Double = 0.5                 // centro, 0 = arriba … 1 = abajo
    var scale: Double = 1               // tamaño (1 = normal)
    var animate: Bool = true            // entra y sale con fundido y un pequeño salto

    var end: Double { start + duration }
    var title: String {
        switch kind {
        case .text: return text.isEmpty ? "Texto" : text
        case .sticker: return text.isEmpty ? "Sticker" : text
        case .image: return imageFile.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Imagen"
        }
    }

    /// Las 9 posiciones rápidas (fila 0…2, columna 0…2) → centro de la capa.
    static func anchor(row: Int, col: Int) -> (x: Double, y: Double) {
        ([0.17, 0.5, 0.83][col], [0.14, 0.5, 0.84][row])
    }

    init(id: Int, kind: Kind, start: Double, duration: Double = 5, text: String = "", style: Style = .title,
         color: String = "#FFFFFF", imageFile: String? = nil, x: Double = 0.5, y: Double = 0.5, scale: Double = 1) {
        self.id = id; self.kind = kind; self.start = start; self.duration = duration; self.text = text
        self.style = style; self.color = color; self.imageFile = imageFile; self.x = x; self.y = y; self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .title
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? true
    }
}

/// B-roll: un video o una imagen que tapa la pantalla desde `start` (tiempo del episodio) durante `duration` segundos;
/// la voz del podcast sigue debajo. El video del b-roll va sin su propio sonido salvo que se suba `volume`.
struct BRollClip: Codable, Identifiable, Equatable {
    var id: Int
    var file: String                    // relativo a la carpeta del proyecto (broll/…)
    var isVideo: Bool
    var start: Double
    var duration: Double = 6
    var srcIn: Double = 0               // desde qué segundo del video de b-roll
    var fill: Bool = true               // llenar la pantalla (recorta) o entrar completo con bordes
    var volume: Double = 0              // sonido del b-roll (0 = mudo)
    var placement: String = "full"      // full | pipLeft | pipRight (ventanita abajo a la izquierda o a la derecha)
    var end: Double { start + duration }
    static let maxSeconds = 10.0        // un b-roll es un apoyo corto, no otro video
    var title: String { (((file as NSString).lastPathComponent) as NSString).deletingPathExtension }

    init(id: Int, file: String, isVideo: Bool, start: Double, duration: Double = 6) {
        self.id = id; self.file = file; self.isVideo = isVideo; self.start = start; self.duration = duration
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? true
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 6
        srcIn = try c.decodeIfPresent(Double.self, forKey: .srcIn) ?? 0
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? true
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0
        placement = try c.decodeIfPresent(String.self, forKey: .placement) ?? "full"
    }
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
    // Desde 0.10: cintillos creados en la app, con estilo
    var style: String = "news"  // news (dos barras) | clean (línea y texto) | sponsor (tarjeta con logo)
    var tag: String?            // etiqueta de la barra ("AHORA", "PATROCINA"…); nil = según `kind`; "" = sin etiqueta
    var color: String?          // hex; nil = el color del podcast (o el de `kind`)
    var sound: Bool = true      // whoosh bajo al entrar y salir
    var fromDirector: Bool = false   // vino de prodPod (el director lo lanzó en vivo)

    var end: Double { start + duration }
    var tagText: String {
        if let tag { return tag }
        switch kind {
        case "sponsor": return "PATROCINA"
        case "banner": return "AHORA"
        case "segment": return "SEGMENTO"
        default: return ""
        }
    }

    init(id: Int, kind: String, title: String, text: String, start: Double, duration: Double, logoFile: String? = nil,
         style: String = "news", tag: String? = nil, color: String? = nil, sound: Bool = true, fromDirector: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.start = start; self.duration = duration
        self.logoFile = logoFile; self.style = style; self.tag = tag; self.color = color; self.sound = sound; self.fromDirector = fromDirector
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "banner"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 6
        logoFile = try c.decodeIfPresent(String.self, forKey: .logoFile)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "news"
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        // Los guardados antes de 0.10 eran todos del director
        fromDirector = try c.decodeIfPresent(Bool.self, forKey: .fromDirector) ?? true
    }
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
        layoutOptions = try c.decodeIfPresent(LayoutOptions.self, forKey: .layoutOptions) ?? LayoutOptions()
        showBackground = try c.decodeIfPresent(Bool.self, forKey: .showBackground) ?? true
        intro = try c.decodeIfPresent(Bumper.self, forKey: .intro)
        colorLook = try c.decodeIfPresent(String.self, forKey: .colorLook) ?? "none"
        matchColors = try c.decodeIfPresent(Bool.self, forKey: .matchColors) ?? false
        laneColorGain = try c.decodeIfPresent([Int: [Double]].self, forKey: .laneColorGain) ?? [:]
        exportHEVC = try c.decodeIfPresent(Bool.self, forKey: .exportHEVC) ?? false
        normalizeLoudness = try c.decodeIfPresent(Bool.self, forKey: .normalizeLoudness) ?? true
        outro = try c.decodeIfPresent(Bumper.self, forKey: .outro)
        reelLayout = try c.decodeIfPresent(LayoutTemplate.self, forKey: .reelLayout) ?? .auto
        if let rl = try c.decodeIfPresent(ReelLook.self, forKey: .reelLook) { reelLook = rl }
        else { reelLook = ReelLook(); reelLook.layout = reelLayout }
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? true
        showLogo = try c.decodeIfPresent(Bool.self, forKey: .showLogo) ?? true
        laneCrop = try c.decodeIfPresent([Int: Double].self, forKey: .laneCrop) ?? [:]
        laneMirror = try c.decodeIfPresent([Int: Bool].self, forKey: .laneMirror) ?? [:]
        laneBackground = try c.decodeIfPresent([Int: VirtualBackground].self, forKey: .laneBackground) ?? [:]
        laneOrder = try c.decodeIfPresent([Int].self, forKey: .laneOrder) ?? []
        moments = try c.decodeIfPresent([Moment].self, forKey: .moments) ?? []
        episode = try c.decodeIfPresent(EpisodeInfo.self, forKey: .episode) ?? EpisodeInfo()
        sponsors = try c.decodeIfPresent([Sponsor].self, forKey: .sponsors) ?? []
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        showSponsors = try c.decodeIfPresent(Bool.self, forKey: .showSponsors) ?? true
        cintillos = try c.decodeIfPresent([DirectorCintillo].self, forKey: .cintillos) ?? []
        showCintillos = try c.decodeIfPresent(Bool.self, forKey: .showCintillos) ?? true
        overlays = try c.decodeIfPresent([VideoLayer].self, forKey: .overlays) ?? []
        brolls = try c.decodeIfPresent([BRollClip].self, forKey: .brolls) ?? []
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
    var freeX: Double?                  // posición libre (centro, 0…1 desde la izquierda); nil = usar `position`
    var freeY: Double?                  // posición libre (centro, 0…1 desde arriba)
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
