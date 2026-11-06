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
    var sensitive: [SensitiveMark] = [] // palabras sensibles detectadas y qué hacer con cada una
    var sensitiveCustom: [String] = []  // palabras propias que también se buscan
    var sensitiveScanned = false
    var transcribedLanes: [Int] = []    // lane ids already transcribed
    var wordsSynced = false             // las palabras ya se ajustaron al audio (SubtitleSync)

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
    var matchVoices = false             // voces parejas por medición: aplicar `Lane.matchGain`
    var grade: ColorGrade?              // Studio · Video: color de toda la pista (todas las cámaras)
    var conversationPan = false         // panorama de conversación: cada persona un poco a un lado, como en pantalla
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
    var studioVideo = StudioVideoSettings() // Studio · Video: cortes de cámara a mano y cómo sigue a quien habla
    var review: ReviewLink?                 // revisión compartida: enlace y comentarios traídos
    var sfxLibrary: [String] = []       // relative paths of sound effects available for this project
    var sfxNames: [String: String] = [:] // nombre de cada sonido en el soundboard de prodPod
    var moments: [Moment] = []          // "Momentos" marcados en postPod/prodPod → fuente de los reels
    var reels: [Reel] = []
    var aiSummary: String?
    var aiAnalyzedAt: Date?             // la IA ya buscó notas y momentos de este episodio (se hace una sola vez)
    var coverTime: Double?              // portada: segundo del episodio elegido (nil = el de siempre: primer reel o un cuarto)
    var coverCandidates: [CoverCandidate] = []   // capturas encontradas (la imagen queda en la caché del proyecto)
    var coverScannedAt: Date?

    var logoFile: String?               // relative to project folder
    var backgroundFile: String?
    var postpodSlug: String?            // proyecto de postPod web del que se descargó

    var duration: Double {
        // El episodio dura lo que duran las grabaciones de las personas. Una música más larga se corta al final
        // (antes alargaba el episodio y la música seguía sola, sin video, antes del cierre).
        let laneEnd = lanes.map { $0.duration }.max() ?? 0
        if laneEnd > 0 { return laneEnd }
        return audioLane.map { $0.tlEnd }.max() ?? 0
    }

    func mediaItem(_ id: Int) -> SourceMedia? { media.first { $0.id == id } }

    /// Pistas en el orden en que van en pantalla (izquierda→derecha / arriba→abajo). Las que no estén en `laneOrder` van al final.
    var lanesOnScreen: [Lane] {
        let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        var out = laneOrder.compactMap { byId[$0] }
        for l in lanes where !out.contains(where: { $0.id == l.id }) { out.append(l) }
        return out
    }

    /// ¿Esta pista tiene cámara (alguno de sus archivos trae video)?
    func laneHasVideo(_ laneId: Int) -> Bool {
        guard let lane = lanes.first(where: { $0.id == laneId }) else { return false }
        return lane.clips.contains { mediaItem($0.mediaId)?.hasVideo == true }
    }

    func laneName(_ laneId: Int) -> String {
        if let lane = lanes.first(where: { $0.id == laneId }) {
            if let pid = lane.participantId, let p = participants.first(where: { $0.id == pid }) {
                return p.name
            }
            return lane.name
        }
        return String(localized: "Pista \(laneId)")
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
        chain = try c.decodeIfPresent(ChainSettings.self, forKey: .chain)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        volumePoints = try c.decodeIfPresent([VolumePoint].self, forKey: .volumePoints) ?? []
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        noiseReduce = try c.decodeIfPresent(Bool.self, forKey: .noiseReduce) ?? false
        noiseAmount = try c.decodeIfPresent(Double.self, forKey: .noiseAmount) ?? 0.6
        noiseProfile = try c.decodeIfPresent([Float].self, forKey: .noiseProfile)
        noiseProfileAt = try c.decodeIfPresent(Double.self, forKey: .noiseProfileAt)
        declick = try c.decodeIfPresent(Bool.self, forKey: .declick) ?? false
        declickAmount = try c.decodeIfPresent(Double.self, forKey: .declickAmount) ?? 0.5
        measuredLUFS = try c.decodeIfPresent(Double.self, forKey: .measuredLUFS)
        matchGain = try c.decodeIfPresent(Double.self, forKey: .matchGain) ?? 0
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade)
        mask = try c.decodeIfPresent(ShapeMask.self, forKey: .mask)
    }
}

/// Un punto de la línea de volumen de una persona: en el segundo `t` del episodio, `db` más o menos (0 = como está).
struct VolumePoint: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var db: Double
    static let minDB = -60.0, maxDB = 12.0
}

extension Lane {
    /// dB de la línea de volumen en el segundo `t` (interpolación lineal entre puntos; plano fuera de ellos).
    func automationDB(at t: Double) -> Double {
        let pts = volumePoints.sorted { $0.t < $1.t }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if t <= first.t { return first.db }
        if t >= last.t { return last.db }
        for i in 0..<(pts.count - 1) where t >= pts[i].t && t <= pts[i + 1].t {
            let a = pts[i], b = pts[i + 1]
            let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
            return a.db + (b.db - a.db) * u
        }
        return 0
    }
    var hasAutomation: Bool { !volumePoints.isEmpty }
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
    var compress = false                // «Voz pareja»: compresor suave (lo bajo sube, lo alto no pega)
    var deess = false                   // «Menos siseo»: de-esser
    var isFlat: Bool { abs(low) < 0.1 && abs(mid) < 0.1 && abs(high) < 0.1 && !rumbleCut && !compress && !deess }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 0
        mid = try c.decodeIfPresent(Double.self, forKey: .mid) ?? 0
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 0
        rumbleCut = try c.decodeIfPresent(Bool.self, forKey: .rumbleCut) ?? false
        compress = try c.decodeIfPresent(Bool.self, forKey: .compress) ?? false
        deess = try c.decodeIfPresent(Bool.self, forKey: .deess) ?? false
    }
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
    var key: String { String(format: "l%+.1fm%+.1fh%+.1f%@%@%@", low, mid, high, rumbleCut ? "r" : "", compress ? "c" : "", deess ? "d" : "") }
    var ffmpegFilter: String {
        var f: [String] = []
        if rumbleCut { f += ["highpass=f=120", String(localized: "equalizer=f=250:t=q:w=1:g=-3")] }
        if abs(low) >= 0.1 { f.append(String(format: "equalizer=f=120:t=q:w=0.8:g=%.1f", low)) }
        if abs(mid) >= 0.1 { f.append(String(format: "equalizer=f=1000:t=q:w=1:g=%.1f", mid)) }
        if abs(high) >= 0.1 { f.append(String(format: "equalizer=f=6000:t=q:w=0.8:g=%.1f", high)) }
        if deess { f.append(String(localized: "deesser=i=0.5:m=0.5:f=0.5")) }
        if compress { f.append(String(localized: "acompressor=threshold=-20dB:ratio=3:attack=8:release=140:makeup=4dB:knee=4")) }
        f.append(String(localized: "alimiter=limit=0.95:level=0"))
        return f.joined(separator: ",")
    }
}

/// Una banda del ecualizador paramétrico del estudio.
struct EQBand: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case highpass, lowshelf, peak, highshelf, lowpass }
    var id = UUID()
    var kind: Kind = .peak
    var freq: Double = 1000             // Hz
    var gain: Double = 0                // dB (no aplica a paso alto/bajo)
    var q: Double = 1.0                 // ancho (octavas aprox. en AUNBandEQ)
    var enabled = true
    var label: String {
        switch kind {
        case .highpass: return String(localized: "Paso alto")
        case .lowshelf: return String(localized: "Estante bajo")
        case .peak: return String(localized: "Campana")
        case .highshelf: return String(localized: "Estante alto")
        case .lowpass: return String(localized: "Paso bajo")
        }
    }
}

/// Un punto de automatización: en el segundo `t` del episodio, el parámetro vale `v`.
struct AutoPoint: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var v: Double
}

/// Un plugin Audio Unit de terceros (o del sistema) insertado en la cadena de una persona.
struct PluginInsert: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var type: UInt32          // kAudioUnitType_Effect / MusicEffect
    var subtype: UInt32
    var manufacturer: UInt32
    var name: String
    var vendor: String = ""
    var enabled = true
    var state: Data?          // ClassInfo / fullState del plugin (sus parámetros)
}

/// La cadena de voz completa de una persona (el estudio). El nivel simple (`VoiceEQ`) es un preset de esto.
struct ChainSettings: Codable, Equatable {
    static let maxBands = 8
    var bands: [EQBand] = []
    /// Plugins después del compresor y antes del limitador, en orden.
    var plugins: [PluginInsert] = []
    /// Automatización por parámetro (`comp.threshold`, `eq.<id de banda>.gain`, …): puntos en tiempo del episodio.
    var automation: [String: [AutoPoint]] = [:]
    var compressorOn = false
    var threshold: Double = -20          // dB
    var ratio: Double = 3               // :1 (se traduce a «head room» del AU)
    var attack: Double = 0.008          // s
    var release: Double = 0.14          // s
    var makeup: Double = 4              // dB
    var deesserOn = false
    var deesserAmount: Double = 0.5     // 0…1 (cuánto baja las eses)
    var limiterOn = true
    var gateOn = false
    var gateThreshold: Double = -45     // dB (expansión suave por debajo)

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? []
        compressorOn = try c.decodeIfPresent(Bool.self, forKey: .compressorOn) ?? false
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? -20
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 3
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 0.008
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 0.14
        makeup = try c.decodeIfPresent(Double.self, forKey: .makeup) ?? 4
        deesserOn = try c.decodeIfPresent(Bool.self, forKey: .deesserOn) ?? false
        deesserAmount = try c.decodeIfPresent(Double.self, forKey: .deesserAmount) ?? 0.5
        limiterOn = try c.decodeIfPresent(Bool.self, forKey: .limiterOn) ?? true
        gateOn = try c.decodeIfPresent(Bool.self, forKey: .gateOn) ?? false
        gateThreshold = try c.decodeIfPresent(Double.self, forKey: .gateThreshold) ?? -45
        automation = try c.decodeIfPresent([String: [AutoPoint]].self, forKey: .automation) ?? [:]
        plugins = try c.decodeIfPresent([PluginInsert].self, forKey: .plugins) ?? []
    }

    // Parámetros automatizables (id → cómo leerlo y escribirlo)
    static let compThreshold = "comp.threshold", compRatio = "comp.ratio", compMakeup = "comp.makeup"
    static let deesserAmount = "deesser.amount", gateThreshold = "gate.threshold"
    static func bandGain(_ b: EQBand) -> String { "eq.\(b.id.uuidString).gain" }
    static func bandFreq(_ b: EQBand) -> String { "eq.\(b.id.uuidString).freq" }

    /// Valor actual (sin automatización) de un parámetro.
    func value(of param: String) -> Double? {
        switch param {
        case Self.compThreshold: return threshold
        case Self.compRatio: return ratio
        case Self.compMakeup: return makeup
        case Self.deesserAmount: return deesserAmount
        case Self.gateThreshold: return gateThreshold
        default:
            let parts = param.split(separator: ".")
            guard parts.count == 3, parts[0] == "eq", let id = UUID(uuidString: String(parts[1])), let b = bands.first(where: { $0.id == id }) else { return nil }
            return parts[2] == "gain" ? b.gain : (parts[2] == "freq" ? b.freq : nil)
        }
    }

    mutating func set(_ param: String, _ v: Double) {
        switch param {
        case Self.compThreshold: threshold = v
        case Self.compRatio: ratio = v
        case Self.compMakeup: makeup = v
        case Self.deesserAmount: deesserAmount = v
        case Self.gateThreshold: gateThreshold = v
        default:
            let parts = param.split(separator: ".")
            guard parts.count == 3, parts[0] == "eq", let id = UUID(uuidString: String(parts[1])), let i = bands.firstIndex(where: { $0.id == id }) else { return }
            if parts[2] == "gain" { bands[i].gain = v } else if parts[2] == "freq" { bands[i].freq = v }
        }
    }

    /// Valor de un parámetro en el segundo `t` del episodio, siguiendo su automatización (lineal entre puntos).
    func value(of param: String, at t: Double) -> Double? {
        guard let pts = automation[param], let first = pts.first else { return value(of: param) }
        let sorted = pts.sorted { $0.t < $1.t }
        if t <= first.t { return sorted[0].v }
        if let last = sorted.last, t >= last.t { return last.v }
        for i in 0..<(sorted.count - 1) where t >= sorted[i].t && t <= sorted[i + 1].t {
            let a = sorted[i], b = sorted[i + 1]
            let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
            return a.v + (b.v - a.v) * u
        }
        return value(of: param)
    }

    /// La cadena con todos los parámetros automatizados puestos en su valor de ese segundo.
    func resolved(at t: Double) -> ChainSettings {
        var c = self
        for (param, _) in automation { if let v = value(of: param, at: t) { c.set(param, v) } }
        c.automation = [:]
        return c
    }

    var hasAutomation: Bool { automation.values.contains { !$0.isEmpty } }

    /// Escribe un punto (o mueve el que haya a menos de 0,25 s) y deja el valor base también ahí.
    mutating func writePoint(_ param: String, t: Double, v: Double) {
        var pts = automation[param] ?? []
        if let i = pts.firstIndex(where: { abs($0.t - t) < 0.25 }) { pts[i].v = v } else { pts.append(AutoPoint(t: t, v: v)) }
        automation[param] = pts.sorted { $0.t < $1.t }
    }

    /// Lo que describe el nivel simple, traducido a la cadena.
    static func preset(_ e: VoiceEQ) -> ChainSettings {
        var c = ChainSettings()
        if e.rumbleCut {
            c.bands.append(EQBand(kind: .highpass, freq: 120, gain: 0, q: 0.7))
            c.bands.append(EQBand(kind: .peak, freq: 250, gain: -3, q: 1))
        }
        if abs(e.low) >= 0.1 { c.bands.append(EQBand(kind: .peak, freq: 120, gain: e.low, q: 0.8)) }
        if abs(e.mid) >= 0.1 { c.bands.append(EQBand(kind: .peak, freq: 1000, gain: e.mid, q: 1)) }
        if abs(e.high) >= 0.1 { c.bands.append(EQBand(kind: .peak, freq: 6000, gain: e.high, q: 0.8)) }
        c.compressorOn = e.compress
        c.deesserOn = e.deess
        return c
    }

    /// Si esta cadena es exactamente lo que el nivel simple sabe decir, devuelve ese preset; si no, nil.
    var asSimple: VoiceEQ? {
        var e = VoiceEQ()
        var rest = bands.filter { $0.enabled }
        if let hp = rest.firstIndex(where: { $0.kind == .highpass && abs($0.freq - 120) < 1 }),
           let r = rest.firstIndex(where: { $0.kind == .peak && abs($0.freq - 250) < 1 && abs($0.gain + 3) < 0.05 }) {
            e.rumbleCut = true
            for i in [hp, r].sorted(by: >) { rest.remove(at: i) }
        }
        for b in rest {
            guard b.kind == .peak else { return nil }
            if abs(b.freq - 120) < 1, abs(b.q - 0.8) < 0.01, e.low == 0 { e.low = b.gain }
            else if abs(b.freq - 1000) < 1, abs(b.q - 1) < 0.01, e.mid == 0 { e.mid = b.gain }
            else if abs(b.freq - 6000) < 1, abs(b.q - 0.8) < 0.01, e.high == 0 { e.high = b.gain }
            else { return nil }
        }
        if compressorOn {
            guard abs(threshold + 20) < 0.05, abs(ratio - 3) < 0.05, abs(attack - 0.008) < 0.0005, abs(release - 0.14) < 0.005, abs(makeup - 4) < 0.05 else { return nil }
            e.compress = true
        }
        if deesserOn {
            guard abs(deesserAmount - 0.5) < 0.01 else { return nil }
            e.deess = true
        }
        guard limiterOn, !gateOn, !hasAutomation, plugins.isEmpty else { return nil }
        return e
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
    var eq = VoiceEQ()                  // ecualizador de 3 bandas (el nivel simple)
    var chain: ChainSettings?           // la cadena completa del estudio; nil = la que describe `eq`
    var muted: Bool = false             // M: esta persona no suena (vista previa y export)
    var solo: Bool = false              // S: solo suenan las personas con solo
    var volumePoints: [VolumePoint] = []   // volumen dibujado: puntos (tiempo del episodio, dB); vacío = plano
    var pan: Double = 0                 // panorama: −1 izquierda … 0 centro … 1 derecha (lo pone «Panorama de conversación»)
    var noiseReduce: Bool = false       // reducción de ruido por huella (resta espectral, sin IA)
    var noiseAmount: Double = 0.6       // cuánto: 0,3 suave · 0,6 normal · 0,9 fuerte
    var noiseProfile: [Float]?          // la huella: magnitud media por banda del segundo más quieto
    var noiseProfileAt: Double?         // de qué segundo del episodio salió la huella
    var declick: Bool = false           // quitar clics y chasquidos de boca
    var declickAmount: Double = 0.5     // sensibilidad 0…1
    var measuredLUFS: Double?           // sonoridad medida de esta voz (BS.1770 con compuerta), si se midió
    var matchGain: Double = 0           // dB que la igualan con las demás (lo pone «Voces parejas por medición»)
    var grade: ColorGrade?              // Studio · Video: color de esta cámara (toda la persona)
    var mask: ShapeMask?                // Studio · Video: dónde se aplica ese color (y qué se oscurece fuera)

    /// La cadena que suena: la del estudio si existe, si no el preset del nivel simple.
    var effectiveChain: ChainSettings { chain ?? ChainSettings.preset(eq) }
    /// El estudio cambió algo que el nivel simple no sabe decir.
    var tunedInStudio: Bool { chain != nil && chain?.asSimple == nil }

    /// Guarda una cadena del estudio: si el nivel simple la sabe decir, va al preset (y los controles
    /// simples la muestran); si no, queda como cadena del estudio y el simple avisa.
    static func store(_ c: ChainSettings, in lane: inout Lane) {
        if let simple = c.asSimple { lane.eq = simple; lane.chain = nil } else { lane.chain = c }
    }

    var duration: Double { offset + clips.reduce(0) { $0 + $1.length } }

    /// Timeline spans of each clip.
    /// Con desfase negativo la persona suena antes: se salta el principio de su grabación
    /// (lo que quedaría antes del segundo 0 del episodio no se usa).
    var placed: [(clip: LaneClip, tlStart: Double, tlEnd: Double)] {
        var t = offset
        var out: [(clip: LaneClip, tlStart: Double, tlEnd: Double)] = []
        for c in clips {
            let start = t, end = t + c.length
            t = end
            if end <= 0 { continue }
            if start < 0 {
                var cut = c
                cut.srcIn += -start
                out.append((cut, 0, end))
            } else {
                out.append((c, start, end))
            }
        }
        return out
    }

    /// Lo más que se puede adelantar: siempre queda al menos un segundo de su grabación.
    var minOffset: Double { -max(0, clips.reduce(0) { $0 + $1.length } - 1) }

    var primaryMediaId: Int? { clips.first?.mediaId }
}

struct LaneClip: Codable, Equatable {
    var mediaId: Int
    var srcIn: Double
    var srcOut: Double
    var volume: Double = 1.0
    var length: Double { max(0, srcOut - srcIn) }
    init(mediaId: Int, srcIn: Double, srcOut: Double, volume: Double = 1.0) {
        self.mediaId = mediaId; self.srcIn = srcIn; self.srcOut = srcOut; self.volume = volume
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        srcIn = try c.decodeIfPresent(Double.self, forKey: .srcIn) ?? 0
        srcOut = try c.decode(Double.self, forKey: .srcOut)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0   // proyectos de antes de que hubiera volumen por clip
    }
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
    var crossfade: Bool = false         // Studio · Video: fades curvos (igual potencia), para cruzar con otro clip
    /// Studio · Video: velocidad (1 = normal). 0,5 = a la mitad (dura el doble), 2 = al doble. El tono se mantiene.
    var speed: Double = 1
    var ducks: Bool { duck ?? ((srcOut - srcIn) > 8) }
    /// Lo que dura en el episodio (la fuente, estirada o comprimida por la velocidad)
    var length: Double { (srcOut - srcIn) / max(0.1, speed) }
    var tlEnd: Double { tlStart + length }
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
        crossfade = try c.decodeIfPresent(Bool.self, forKey: .crossfade) ?? false
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
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
    enum Kind: String, Codable { case silence, filler, manual, imported, repeated }
    var id = UUID()
    var start: Double
    var end: Double
    var kind: Kind
    var enabled: Bool = true
    var label: String = ""
    /// Sugerencia dudosa (muletilla que puede ser palabra válida, frase repetida, sonido sin palabras):
    /// nace apagada y no se quita hasta que la persona la marque.
    var suggested: Bool? = nil
    /// La persona ya la miró (la prendió o la apagó a mano). Se conserva al volver a arreglar.
    var reviewed: Bool? = nil
    var length: Double { max(0, end - start) }
}

struct FixSettings: Codable, Equatable {
    var removeSilences = true
    var removeFillers = true
    var removeWordFillers = false       // "este", "o sea", "pues"... off by default
    var enhanceAudio = true
    var strongNoise = false             // (versiones viejas) ya no se usa: ver `noiseLevel`
    var noiseLevel = 2                  // cuánto se limpia la voz: 1 natural · 2 normal · 3 máximo
    var gateOthers = true               // bajar la pista de quien no está hablando (teclas y ruidos del otro)
    var gateDB: Double = 12             // cuánto se baja: 8 suave, 12 normal, 18 fuerte
    var minSilence: Double = 0.8        // seconds of silence before we cut
    var keepPad: Double = 0.18          // breathing room kept around speech
    var roomTone = true                 // tono de sala: rellena los huecos muertos de cada persona con su propio ambiente y suaviza las uniones de los cortes
    var lastRun: Date?
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removeSilences = try c.decodeIfPresent(Bool.self, forKey: .removeSilences) ?? true
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        removeWordFillers = try c.decodeIfPresent(Bool.self, forKey: .removeWordFillers) ?? false
        enhanceAudio = try c.decodeIfPresent(Bool.self, forKey: .enhanceAudio) ?? true
        strongNoise = try c.decodeIfPresent(Bool.self, forKey: .strongNoise) ?? false
        noiseLevel = try c.decodeIfPresent(Int.self, forKey: .noiseLevel) ?? 2
        gateOthers = try c.decodeIfPresent(Bool.self, forKey: .gateOthers) ?? true
        gateDB = try c.decodeIfPresent(Double.self, forKey: .gateDB) ?? 12
        minSilence = try c.decodeIfPresent(Double.self, forKey: .minSilence) ?? 0.8
        keepPad = try c.decodeIfPresent(Double.self, forKey: .keepPad) ?? 0.18
        roomTone = try c.decodeIfPresent(Bool.self, forKey: .roomTone) ?? true
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
    var words: [Word]?                  // texto propio del reel (se volvió a escuchar solo este reel); nil = el del episodio
    var seen: Bool?                     // la persona ya lo miró en la vista previa (para la revisión antes de exportar)
    var hook: String?                   // título de gancho: grande los primeros segundos del reel (nil = sin título)
    var length: Double { max(0, end - start) }
    static let hookSeconds = 3.0

    init(id: UUID = UUID(), title: String, reason: String = "", start: Double, end: Double, selected: Bool = true, exportedFile: String? = nil, look: ReelLook? = nil) {
        self.id = id; self.title = title; self.reason = reason; self.start = start; self.end = end
        self.selected = selected; self.exportedFile = exportedFile; self.look = look
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? String(localized: "Reel")
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        exportedFile = try c.decodeIfPresent(String.self, forKey: .exportedFile)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen)
        look = try c.decodeIfPresent(ReelLook.self, forKey: .look)
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        brolls = try c.decodeIfPresent([BRollClip].self, forKey: .brolls) ?? []
        music = try c.decodeIfPresent([AudioLaneClip].self, forKey: .music) ?? []
        cintillos = try c.decodeIfPresent([DirectorCintillo].self, forKey: .cintillos) ?? []
        words = try c.decodeIfPresent([Word].self, forKey: .words)
        hook = try c.decodeIfPresent(String.self, forKey: .hook)
    }
}

/// Fondo virtual de una persona: se separa a la persona de su fondo real (Apple Vision, en la Mac, sin internet)
/// y detrás se pone lo que se elija.
struct VirtualBackground: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case blur, podcast, color, image
        var name: String {
            switch self { case .blur: return String(localized: "Difuminado"); case .podcast: return String(localized: "Fondo del podcast"); case .color: return String(localized: "Color"); case .image: return String(localized: "Imagen") }
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
            if let own = reel.words { p.words = own }   // el texto propio del reel (no cambia el episodio)
            p.cuts += reel.cuts
            p.brolls += reel.brolls
            if !reel.cintillos.isEmpty { p.cintillos += reel.cintillos; p.showCintillos = true }
            // Título de gancho: arriba, grande, desde lo primero que suena del reel
            if let h = reel.hook?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty {
                let keep = EditEngine.keepRanges(duration: p.duration, cuts: p.cuts, window: (reel.start, reel.end))
                let at = keep.first?.start ?? reel.start
                p.overlays.append(VideoLayer(id: (p.overlays.map(\.id).max() ?? 0) + 1000, kind: .text, start: at,
                                             duration: Reel.hookSeconds, text: h, style: .title, color: "#FFFFFF",
                                             x: 0.5, y: 0.09, scale: 1.0))
            }
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
    var punchIn: Bool = false           // acercamiento sutil a cada persona cuando sube la energía de su voz
    var audiogram: Bool = true          // episodios sin cámara: ondas que siguen la voz de quien habla
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soloStudio = try c.decodeIfPresent(Bool.self, forKey: .soloStudio) ?? false
        gridSpeakerBig = try c.decodeIfPresent(Bool.self, forKey: .gridSpeakerBig) ?? false
        pipFollowSpeaker = try c.decodeIfPresent(Bool.self, forKey: .pipFollowSpeaker) ?? true
        punchIn = try c.decodeIfPresent(Bool.self, forKey: .punchIn) ?? false
        audiogram = try c.decodeIfPresent(Bool.self, forKey: .audiogram) ?? true
    }
}

enum LayoutTemplate: String, Codable, CaseIterable, Identifiable {
    case auto, solo, sideBySide, grid, spotlight, pip, stack, studio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return String(localized: "Automático")
        case .solo: return String(localized: "Quien habla")
        case .sideBySide: return String(localized: "Lado a lado")
        case .grid: return String(localized: "Cuadrícula")
        case .spotlight: return String(localized: "Protagonista")
        case .pip: return String(localized: "Ventanita")
        case .stack: return String(localized: "Arriba y abajo")
        case .studio: return String(localized: "Estudio")
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
        case .auto: return String(localized: "Elegimos el mejor según el formato")
        case .solo: return String(localized: "Pantalla completa para quien está hablando")
        case .sideBySide: return String(localized: "Todos a la vez, uno al lado del otro")
        case .grid: return String(localized: "Todos en cuadrícula")
        case .spotlight: return String(localized: "Quien habla en grande, el resto al costado")
        case .pip: return String(localized: "Quien habla en grande, otro en una esquina")
        case .stack: return String(localized: "Uno arriba y otro abajo (ideal vertical)")
        case .studio: return String(localized: "Las cámaras en recuadros sobre el fondo de tu podcast")
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case landscape, vertical, square, audio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .landscape: return String(localized: "YouTube")
        case .vertical: return String(localized: "Reels · TikTok · Shorts")
        case .square: return String(localized: "Instagram cuadrado")
        case .audio: return String(localized: "Solo audio (MP3)")
        }
    }
    var subtitle: String {
        switch self {
        case .landscape: return String(localized: "Horizontal 16:9 · \(Int(renderSize.height))p") + planNote
        case .vertical: return String(localized: "Vertical 9:16 · \(Int(renderSize.width))×\(Int(renderSize.height))") + planNote
        case .square: return String(localized: "Cuadrado 1:1 · \(Int(renderSize.width))×\(Int(renderSize.height))") + planNote
        case .audio: return String(localized: "Para Spotify, Apple Podcasts…")
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
    /// Tamaño del video. Con el plan Gratis el lado corto es 720 (1280×720, 720×1280, 720×720).
    private var planNote: String { (Plan.maxHeight ?? 1080) < 1080 ? String(localized: " (plan \(Plan.name))") : "" }

    /// 4K para YouTube: solo mientras se exporta (la vista previa sigue en 1080) y solo con un plan
    /// que incluye la app. Se activa con `ExportFormat.$uhd.withValue(true) { … }`.
    @TaskLocal static var uhd = false
    static var uhdAvailable: Bool { Plan.maxHeight == nil }
    var uses4K: Bool { self == .landscape && Self.uhd && Self.uhdAvailable }

    var renderSize: CGSize {
        let short = uses4K ? 2160 : CGFloat(min(1080, Plan.maxHeight ?? 1080))
        let long = (short * 16 / 9 / 2).rounded() * 2
        switch self {
        case .landscape: return CGSize(width: long, height: short)
        case .vertical: return CGSize(width: short, height: long)
        case .square: return CGSize(width: short, height: short)
        case .audio: return CGSize(width: 16, height: 16)
        }
    }
    var isVertical: Bool { self == .vertical }
    var fileSuffix: String {
        switch self {
        case .landscape: return uses4K ? "youtube4k" : "youtube"
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
        var name: String { switch self { case .title: return String(localized: "Título"); case .box: return String(localized: "Caja"); case .label: return String(localized: "Etiqueta") } }
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
    /// Studio · Video: keyframes de posición, tamaño, giro y opacidad (nil = la capa está quieta, como la puso el simple)
    var animation: LayerAnimation?
    /// Studio · Video: cómo entra y cómo sale (nil = el fundido con saltito de `animate`)
    var enter: TitleMotion?
    var exit: TitleMotion?

    var end: Double { start + duration }
    /// Tocada en Studio: tiene keyframes o entradas que el paso simple no sabe expresar.
    var tunedInStudio: Bool { !(animation?.isEmpty ?? true) || enter != nil || exit != nil }
    var title: String {
        switch kind {
        case .text: return text.isEmpty ? String(localized: "Texto") : text
        case .sticker: return text.isEmpty ? String(localized: "Sticker") : text
        case .image: return imageFile.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? String(localized: "Imagen")
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
        animation = try c.decodeIfPresent(LayerAnimation.self, forKey: .animation)
        enter = try c.decodeIfPresent(TitleMotion.self, forKey: .enter)
        exit = try c.decodeIfPresent(TitleMotion.self, forKey: .exit)
    }
}

/// Cómo entra (o sale) un título, sticker o imagen: la animación va sobre la capa ya dibujada.
struct TitleMotion: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case rise, fade, reveal, grow, wipe, drop
        var name: String {
            switch self {
            case .rise: return String(localized: "Subir"); case .fade: return String(localized: "Fundido"); case .reveal: return String(localized: "Escribir")
            case .grow: return String(localized: "Crecer"); case .wipe: return String(localized: "Barrido"); case .drop: return String(localized: "Caer")
            }
        }
    }
    var kind: Kind = .rise
    var duration: Double = 0.4
    init(kind: Kind = .rise, duration: Double = 0.4) { self.kind = kind; self.duration = duration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .rise
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.4
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
    /// Studio · Video: cómo entra este clip (nil = el fundido corto de siempre)
    var transitionIn: Transition?
    /// Studio · Video: velocidad del video (1 = normal). 0,25–1 cámara lenta, 1–4 acelerado. `duration` sigue siendo lo que ocupa en pantalla.
    var speed: Double = 1
    /// Rampa de velocidad: si está, el clip va de `speed` al inicio a `speedEnd` al final (suave); nil = velocidad fija.
    var speedEnd: Double?
    var grade: ColorGrade?              // Studio · Video: color solo de este clip
    var end: Double { start + duration }
    static let maxSeconds = 10.0

    /// Velocidad en una fracción 0–1 del clip (con la rampa, interpolada suave; sin ella, `speed`).
    func speed(at f: Double) -> Double {
        guard let e = speedEnd else { return max(0.1, speed) }
        let k = min(1, max(0, f)); let ease = k * k * (3 - 2 * k)
        return max(0.1, speed + (e - speed) * ease)
    }
    /// Tramos de la rampa para armar la mezcla: (segundos en pantalla, segundos de la fuente) por trozo, en orden.
    /// Sin rampa, un solo tramo. `screenLen` es lo que ocupa en pantalla.
    func speedSegments(screenLen: Double, step: Double = 0.25) -> [(screen: Double, source: Double)] {
        guard speedEnd != nil, screenLen > step else { return [(screenLen, screenLen * speed(at: 0))] }
        var out: [(Double, Double)] = []
        var t = 0.0
        while t < screenLen - 1e-6 {
            let d = min(step, screenLen - t)
            let v = speed(at: (t + d / 2) / screenLen)
            out.append((d, d * v)); t += d
        }
        return out
    }
    /// Segundos de fuente que consume la rampa entera en `screenLen` segundos de pantalla.
    func sourceNeeded(screenLen: Double) -> Double { speedSegments(screenLen: screenLen).reduce(0) { $0 + $1.source } }        // un b-roll es un apoyo corto, no otro video
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
        transitionIn = try c.decodeIfPresent(Transition.self, forKey: .transitionIn)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        speedEnd = try c.decodeIfPresent(Double.self, forKey: .speedEnd)
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade)
    }
}

// MARK: - Studio · Video

/// Un punto de una curva: en qué segundo del episodio, qué valor, y cómo se llega al siguiente punto.
struct Keyframe: Codable, Equatable, Hashable, Identifiable {
    enum Ease: String, Codable, CaseIterable {
        case linear, smooth, hold
        var name: String { switch self { case .linear: return String(localized: "Lineal"); case .smooth: return String(localized: "Suave"); case .hold: return String(localized: "Pausa") } }
    }
    var id = UUID()
    var t: Double
    var v: Double
    var ease: Ease = .smooth
    init(t: Double, v: Double, ease: Ease = .smooth) { self.t = t; self.v = v; self.ease = ease }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        t = try c.decode(Double.self, forKey: .t)
        v = try c.decode(Double.self, forKey: .v)
        ease = try c.decodeIfPresent(Ease.self, forKey: .ease) ?? .smooth
    }
}

/// Animación de una capa: por parámetro, sus keyframes (tiempo del episodio). Posición en fracciones del cuadro
/// (0–1, como `VideoLayer.x/y`) para que la misma curva valga en 16:9, 9:16 y 1:1; tamaño como factor; giro en
/// grados; opacidad 0–1. Un parámetro sin keyframes usa el valor fijo de la capa.
struct LayerAnimation: Codable, Equatable {
    static let x = "x", y = "y", scale = "scale", rotation = "rotation", opacity = "opacity"
    static let params = [x, y, scale, rotation, opacity]
    var tracks: [String: [Keyframe]] = [:]

    var isEmpty: Bool { tracks.values.allSatisfy(\.isEmpty) }
    func has(_ p: String) -> Bool { !(tracks[p] ?? []).isEmpty }

    /// Valor del parámetro en `t`, o nil si no tiene keyframes.
    func value(_ p: String, at t: Double) -> Double? {
        guard let pts = tracks[p], !pts.isEmpty else { return nil }
        return Self.interpolate(pts, at: t)
    }

    static func interpolate(_ raw: [Keyframe], at t: Double) -> Double {
        let pts = raw.sorted { $0.t < $1.t }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if t <= first.t { return first.v }
        if t >= last.t { return last.v }
        for i in 0..<(pts.count - 1) where t >= pts[i].t && t <= pts[i + 1].t {
            let a = pts[i], b = pts[i + 1]
            let span = b.t - a.t
            guard span > 1e-6 else { return b.v }
            var f = (t - a.t) / span
            switch a.ease {
            case .hold: f = 0
            case .smooth: f = f * f * (3 - 2 * f)
            case .linear: break
            }
            return a.v + (b.v - a.v) * f
        }
        return last.v
    }

    /// Pone (o mueve) un keyframe en `t`; dos keyframes a menos de 40 ms se consideran el mismo.
    mutating func write(_ p: String, t: Double, v: Double, ease: Keyframe.Ease = .smooth) {
        var pts = tracks[p] ?? []
        if let i = pts.firstIndex(where: { abs($0.t - t) < 0.04 }) { pts[i].v = v; pts[i].ease = ease }
        else { pts.append(Keyframe(t: t, v: v, ease: ease)) }
        tracks[p] = pts.sorted { $0.t < $1.t }
    }
    mutating func remove(_ p: String, id: UUID) {
        var pts = tracks[p] ?? []
        pts.removeAll { $0.id == id }
        tracks[p] = pts.isEmpty ? nil : pts
    }
    mutating func clear(_ p: String) { tracks[p] = nil }

    /// La misma animación con los tiempos convertidos (p. ej. del episodio al video final).
    func mapped(_ f: (Double) -> Double?) -> LayerAnimation {
        var out = LayerAnimation()
        for (p, pts) in tracks {
            let m = pts.compactMap { k -> Keyframe? in f(k.t).map { var c = k; c.t = $0; return c } }
            if !m.isEmpty { out.tracks[p] = m }
        }
        return out
    }
}

/// Máscara de una cámara (Studio · Video): una elipse o un rectángulo, en fracciones del recuadro de esa persona, con
/// borde suavizado. Dentro se aplica el color de la cámara; fuera, el cuadro queda como está (o se oscurece).
/// Sigue el movimiento con keyframes de posición y tamaño (x, y, scale), a mano: ningún reconocimiento automático.
struct ShapeMask: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable {
        case ellipse, rect
        var name: String { self == .ellipse ? String(localized: "Elipse") : String(localized: "Rectángulo") }
    }
    var shape: Shape = .ellipse
    var x: Double = 0.5                 // centro, fracción del recuadro (0 = izquierda)
    var y: Double = 0.42                // centro, fracción del recuadro (0 = arriba)
    var w: Double = 0.5                 // ancho, fracción del recuadro
    var h: Double = 0.7                 // alto, fracción del recuadro
    var feather: Double = 24            // suavizado del borde, px a 1080p
    var invert: Bool = false            // el color va fuera, no dentro
    var dimOutside: Double = 0          // 0…1: oscurecer lo que queda fuera
    var animation: LayerAnimation?      // x, y, scale en tiempo del episodio
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .ellipse
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.42
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 0.5
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 0.7
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 24
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        dimOutside = try c.decodeIfPresent(Double.self, forKey: .dimOutside) ?? 0
        animation = try c.decodeIfPresent(LayerAnimation.self, forKey: .animation)
    }
    /// Dónde está la máscara en `t`: centro y escala con los keyframes si los hay.
    func placement(at t: Double) -> (x: Double, y: Double, scale: Double) {
        (animation?.value(LayerAnimation.x, at: t) ?? x, animation?.value(LayerAnimation.y, at: t) ?? y, animation?.value(LayerAnimation.scale, at: t) ?? 1)
    }
}

/// Cómo entra un clip desde lo que había antes.
struct Transition: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case cut, fade, black, slide, zoom
        var name: String {
            switch self {
            case .cut: return String(localized: "Corte"); case .fade: return String(localized: "Fundido"); case .black: return String(localized: "A negro")
            case .slide: return String(localized: "Deslizar"); case .zoom: return String(localized: "Zoom")
            }
        }
    }
    var kind: Kind = .fade
    var duration: Double = 0.6
    init(kind: Kind = .fade, duration: Double = 0.6) { self.kind = kind; self.duration = duration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .fade
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.6
    }
}

/// Un tramo de cámara fijado a mano en Studio (tiempo del episodio): dentro de él gana sobre «sigue a quien habla».
struct CameraCut: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var lane: Int?                      // la persona en grande; nil = todas, con la plantilla
    var template: LayoutTemplate?       // plantilla solo para este tramo; nil = la del proyecto
    init(start: Double, end: Double, lane: Int? = nil, template: LayoutTemplate? = nil) {
        self.start = start; self.end = end; self.lane = lane; self.template = template
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane)
        template = try c.decodeIfPresent(LayoutTemplate.self, forKey: .template)
    }
}

/// Lo que Studio · Video decide sobre las cámaras.
struct StudioVideoSettings: Codable, Equatable {
    var followSpeaker = true            // cortes automáticos a quien habla (apagado: la plantilla fija del proyecto)
    var minHold = 2.5                   // segundos mínimos en una cámara antes de cambiar (para no «picar»)
    var cuts: [CameraCut] = []          // tramos fijados a mano
    /// Multicámara: cómo se pasa de una cámara a otra (nil = corte seco). Solo fundido o zoom suave tienen sentido aquí.
    var switchTransition: Transition?
    var isDefault: Bool { followSpeaker && abs(minHold - 2.5) < 1e-9 && cuts.isEmpty && switchTransition == nil }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followSpeaker = try c.decodeIfPresent(Bool.self, forKey: .followSpeaker) ?? true
        minHold = try c.decodeIfPresent(Double.self, forKey: .minHold) ?? 2.5
        cuts = try c.decodeIfPresent([CameraCut].self, forKey: .cuts) ?? []
        switchTransition = try c.decodeIfPresent(Transition.self, forKey: .switchTransition)
    }
    /// El tramo a mano que cubre `t` (tiempo del episodio), si hay.
    func cut(at t: Double) -> CameraCut? { cuts.first { t >= $0.start && t < $0.end } }

    /// Multicámara en vivo: cortar a `lane` en el segundo `t` (tecla 1–4 o clic en el ángulo). El tramo que cubría `t`
    /// termina ahí; el nuevo dura hasta el siguiente corte a mano o hasta `duration`. Devuelve el corte creado.
    @discardableResult
    mutating func liveCut(to lane: Int, at t: Double, duration: Double) -> CameraCut {
        for i in cuts.indices where cuts[i].start < t && cuts[i].end > t { cuts[i].end = t }
        cuts.removeAll { abs($0.start - t) < 0.05 }
        let next = cuts.map(\.start).filter { $0 > t + 0.05 }.min() ?? duration
        let c = CameraCut(start: t, end: max(t + 0.1, next), lane: lane, template: nil)
        cuts.append(c)
        cuts.removeAll { $0.end - $0.start < 0.05 }
        cuts.sort { $0.start < $1.start }
        return c
    }
}

// MARK: - Revisión compartida

/// Un comentario dejado desde el enlace de revisión: `t` es el segundo del archivo revisado (video final, con intro).
struct ReviewComment: Codable, Equatable, Identifiable {
    var id: Int
    var t: Double
    var author: String
    var text: String
    var resolved: Bool
}

/// El enlace de revisión de este episodio y la última lectura de sus comentarios.
struct ReviewLink: Codable, Equatable {
    var token: String
    var url: String
    var sentAt: Date
    var introDuration: Double = 0        // el archivo revisado llevaba esta intro: para pasar `t` al episodio
    var keepPairs: [[Double]] = []       // y estos tramos [[inicio, fin], …]
    var comments: [ReviewComment] = []
    var fetchedAt: Date?
    init(token: String, url: String, sentAt: Date, introDuration: Double = 0, keep: [EditEngine.Span] = []) {
        self.token = token; self.url = url; self.sentAt = sentAt; self.introDuration = introDuration
        keepPairs = keep.map { [$0.start, $0.end] }
    }
    var keep: [EditEngine.Span] { keepPairs.compactMap { $0.count == 2 ? (start: $0[0], end: $0[1]) : nil } }
    /// Segundo del episodio de un comentario (lo que marca la línea de tiempo).
    func timelineTime(_ c: ReviewComment) -> Double {
        keep.isEmpty ? max(0, c.t - introDuration) : EditEngine.toTimeline(max(0, c.t - introDuration), keep: keep)
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
        case "sponsor": return String(localized: "PATROCINA")
        case "banner": return String(localized: "AHORA")
        case "segment": return String(localized: "SEGMENTO")
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

/// Una captura candidata a portada: un segundo del episodio donde todas las personas se ven bien.
struct CoverCandidate: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double                    // segundo del episodio (timeline)
    var score: Double                   // 0…1: cuánto sonríen, ojos abiertos, nitidez
    var allSmiling: Bool                // todas las personas con cara sonríen en este cuadro
    var faces: Int                      // caras encontradas (sumando las pistas)
    var file: String                    // JPEG en la caché del proyecto
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
        sensitive = try c.decodeIfPresent([SensitiveMark].self, forKey: .sensitive) ?? []
        sensitiveCustom = try c.decodeIfPresent([String].self, forKey: .sensitiveCustom) ?? []
        sensitiveScanned = try c.decodeIfPresent(Bool.self, forKey: .sensitiveScanned) ?? false
        transcribedLanes = try c.decodeIfPresent([Int].self, forKey: .transcribedLanes) ?? []
        wordsSynced = try c.decodeIfPresent(Bool.self, forKey: .wordsSynced) ?? false
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
        matchVoices = try c.decodeIfPresent(Bool.self, forKey: .matchVoices) ?? false
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade)
        conversationPan = try c.decodeIfPresent(Bool.self, forKey: .conversationPan) ?? false
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
        studioVideo = try c.decodeIfPresent(StudioVideoSettings.self, forKey: .studioVideo) ?? StudioVideoSettings()
        review = try c.decodeIfPresent(ReviewLink.self, forKey: .review)
        sfxLibrary = try c.decodeIfPresent([String].self, forKey: .sfxLibrary) ?? []
        sfxNames = try c.decodeIfPresent([String: String].self, forKey: .sfxNames) ?? [:]
        reels = try c.decodeIfPresent([Reel].self, forKey: .reels) ?? []
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
        aiAnalyzedAt = try c.decodeIfPresent(Date.self, forKey: .aiAnalyzedAt)
        coverTime = try c.decodeIfPresent(Double.self, forKey: .coverTime)
        coverCandidates = try c.decodeIfPresent([CoverCandidate].self, forKey: .coverCandidates) ?? []
        coverScannedAt = try c.decodeIfPresent(Date.self, forKey: .coverScannedAt)
        logoFile = try c.decodeIfPresent(String.self, forKey: .logoFile)
        backgroundFile = try c.decodeIfPresent(String.self, forKey: .backgroundFile)
        postpodSlug = try c.decodeIfPresent(String.self, forKey: .postpodSlug)
    }

    /// Studio · Video: si el clip `id` se solapa con otro de la pista de música, los cruza (fades curvos del largo
    /// del solape). Si ya no se solapan, los fades que había puesto un cruce se quitan.
    mutating func crossfadeOverlaps(touching id: Int) {
        guard let i = audioLane.firstIndex(where: { $0.id == id }) else { return }
        for j in audioLane.indices where j != i {
            let a = audioLane[i].tlStart < audioLane[j].tlStart ? i : j
            let b = a == i ? j : i
            let overlap = audioLane[a].tlEnd - audioLane[b].tlStart
            if overlap > 0.05, overlap < min(audioLane[a].tlEnd - audioLane[a].tlStart, audioLane[b].tlEnd - audioLane[b].tlStart) {
                audioLane[a].fadeOut = overlap; audioLane[a].crossfade = true
                audioLane[b].fadeIn = overlap; audioLane[b].crossfade = true
            } else if audioLane[a].crossfade, audioLane[b].crossfade, overlap <= 0.05, abs(audioLane[a].fadeOut - audioLane[b].fadeIn) < 0.01 {
                // Se separaron: el cruce ya no existe
                audioLane[a].fadeOut = 0; audioLane[b].fadeIn = 0
            }
        }
    }

    /// Cruza dos clips: adelanta el segundo para que se solapen `seconds` y pone fades curvos.
    mutating func crossfade(_ firstId: Int, with secondId: Int, seconds: Double) {
        guard let a = audioLane.firstIndex(where: { $0.id == firstId }), let b = audioLane.firstIndex(where: { $0.id == secondId }) else { return }
        audioLane[b].tlStart = max(audioLane[a].tlStart + 0.5, audioLane[a].tlEnd - seconds)
        crossfadeOverlaps(touching: secondId)
    }

    /// Panorama de conversación: cada persona un poco a un lado, en el orden en que va en pantalla (izquierda →
    /// derecha), sin pasar de ±0,3 para que en un altavoz mono no se pierda nadie. Una sola persona queda al centro.
    static func conversationPans(count n: Int) -> [Double] {
        guard n >= 2 else { return [Double](repeating: 0, count: n) }
        let spread = min(0.3, 0.2 + 0.05 * Double(n - 2))
        return (0..<n).map { -spread + 2 * spread * Double($0) / Double(n - 1) }
    }
    /// Pone los panoramas de conversación en las personas según su orden en pantalla.
    mutating func applyConversationPans() {
        let order = lanesOnScreen.map(\.id)
        let pans = Self.conversationPans(count: order.count)
        for (i, id) in order.enumerated() {
            if let li = lanes.firstIndex(where: { $0.id == id }) { lanes[li].pan = (pans[i] * 100).rounded() / 100 }
        }
    }

    /// Studio · Video tocó algo que el nivel simple no sabe expresar (keyframes, transiciones, cámaras a mano).
    var videoTunedInStudio: Bool {
        overlays.contains(where: \.tunedInStudio) || brolls.contains { $0.transitionIn != nil || $0.grade?.isEmpty == false || $0.speed != 1 || $0.speedEnd != nil }
            || !studioVideo.isDefault || grade?.isEmpty == false || lanes.contains { $0.grade?.isEmpty == false || $0.mask != nil }
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
            return Reel(title: title.isEmpty ? String(localized: "Momento \(i + 1)") : title,
                        reason: String(localized: "Momento marcado en postPod"), start: start, end: end)
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

        return [("clasico", String(localized: "Clásico"), clasico),
                ("tiktok", String(localized: "TikTok"), tiktok),
                ("comic", String(localized: "Cómic"), comic),
                ("caja", String(localized: "Caja negra"), caja),
                ("minimal", String(localized: "Discreto"), minimal)]
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


extension Project {
    /// Las palabras para subtítulos y transcripción, con las palabras sensibles ya cambiadas.
    var captionWords: [Word] {
        let marks = sensitive.filter { $0.replace && !$0.ignored && !$0.replacement.isEmpty }
        guard !marks.isEmpty else { return words }
        let byId = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        return words.map { w in
            // Por id (persona + tiempo exacto); si no, la misma palabra de la misma persona a menos de 0,6 s
            // (el texto propio de un reel se escribió de nuevo y sus tiempos no son idénticos a los del episodio).
            guard let m = byId[SensitiveMark.makeId(lane: w.lane, s: w.s)]
                    ?? marks.first(where: { $0.lane == w.lane && abs($0.s - w.s) < 0.6 && plain($0.word) == plain(w.w) })
            else { return w }
            var out = w
            // Conserva mayúscula inicial y puntuación final de la palabra original
            let trimmed = w.w.trimmingCharacters(in: .whitespaces)
            let tail = trimmed.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
            var rep = m.replacement
            if let f = trimmed.first, f.isUppercase, let r = rep.first { rep = String(r).uppercased() + rep.dropFirst() }
            out.w = rep + String(tail)
            return out
        }
    }

    /// Tramos (tiempo del episodio) que llevan pitido, por persona.
    var bleeps: [(lane: Int, start: Double, end: Double)] {
        sensitive.filter { $0.bleep && !$0.ignored }.map { ($0.lane, $0.s, $0.e) }
    }
}
