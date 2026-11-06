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
    var sensitive: [SensitiveMark] = [] // sensitive words detected and what to do with each
    var sensitiveCustom: [String] = []  // custom words that are also searched
    var sensitiveScanned = false
    var transcribedLanes: [Int] = []    // lane ids already transcribed
    var wordsSynced = false             // the words were already aligned to the audio (SubtitleSync)

    var cuts: [Cut] = []
    var fix = FixSettings()
    var enhanceAudio: Bool = false      // true once enhanced audio files exist and are in use

    var captionStyle = CaptionStyle()
    var layout: LayoutTemplate = .auto
    var layoutOptions = LayoutOptions()  // settings for each layout (studio frame, speaker large…)
    var reelLayout: LayoutTemplate = .auto   // (old) now lives in reelLook.layout
    var reelLook = ReelLook()           // design and branding for all reels (each reel can have its own)
    var showBackground: Bool = true     // use the podcast's background image behind the video
    var intro: Bumper?                  // image (and music) before the video
    var colorLook: String = "none"      // none | warm | cool | cine | bw | vivid
    var matchColors = false             // match the cameras' color
    var matchVoices = false             // even voices by measurement: apply `Lane.matchGain`
    var grade: ColorGrade?              // Studio · Video: whole-track color (all cameras)
    var conversationPan = false         // conversation panning: each person slightly to one side, as on screen
    var laneColorGain: [Int: [Double]] = [:]   // lane id -> [r, g, b] (computed when matchColors is enabled)
    var exportHEVC = false              // lighter file (HEVC) instead of compatible (H.264)
    var normalizeLoudness = true        // adjust final volume to −16 LUFS
    var outro: Bumper?                  // image (and music) at the end
    var showNames: Bool = true
    var showLogo: Bool = true
    var laneCrop: [Int: Double] = [:]   // lane id -> horizontal crop center 0...1 for vertical
    var laneMirror: [Int: Bool] = [:]   // lane id -> mirror the video (horizontal)
    var laneBackground: [Int: VirtualBackground] = [:]   // lane id -> virtual background (remove that person's real background)
    var laneOrder: [Int] = []           // on-screen order (lane ids); empty = lane order

    var episode = EpisodeInfo()         // from prePod (via postPod's proyecto.json)
    var sponsors: [Sponsor] = []
    var segments: [Segment] = []        // script blocks with timing (prePod "blocks")
    var showSponsors: Bool = true
    var cintillos: [DirectorCintillo] = []   // lower thirds the director placed live (prodPod)
    var showCintillos: Bool = true
    var overlays: [VideoLayer] = []        // texts, images and stickers on top of the video
    var brolls: [BRollClip] = []           // b-roll: a video or image covering the screen for a while (the voice continues)
    var studioVideo = StudioVideoSettings() // Studio · Video: manual camera cuts and how it follows the speaker
    var review: ReviewLink?                 // shared review: link and fetched comments
    var sfxLibrary: [String] = []       // relative paths of sound effects available for this project
    var sfxNames: [String: String] = [:] // name of each sound in prodPod's soundboard
    var moments: [Moment] = []          // "Momentos" marked in postPod/prodPod → source of the reels
    var reels: [Reel] = []
    var aiSummary: String?
    var aiAnalyzedAt: Date?             // the AI already looked for notes and moments in this episode (done only once)
    var coverTime: Double?              // cover: chosen episode second (nil = the usual one: first reel or a quarter in)
    var coverCandidates: [CoverCandidate] = []   // captures found (the image stays in the project cache)
    var coverScannedAt: Date?

    var logoFile: String?               // relative to project folder
    var backgroundFile: String?
    var postpodSlug: String?            // postPod web project it was downloaded from

    var duration: Double {
        // The episode lasts as long as the people's recordings. Longer music is cut at the end
        // (it used to lengthen the episode and the music kept playing alone, without video, before the outro).
        let laneEnd = lanes.map { $0.duration }.max() ?? 0
        if laneEnd > 0 { return laneEnd }
        return audioLane.map { $0.tlEnd }.max() ?? 0
    }

    func mediaItem(_ id: Int) -> SourceMedia? { media.first { $0.id == id } }

    /// Lanes in on-screen order (left→right / top→bottom). Those not in `laneOrder` go at the end.
    var lanesOnScreen: [Lane] {
        let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        var out = laneOrder.compactMap { byId[$0] }
        for l in lanes where !out.contains(where: { $0.id == l.id }) { out.append(l) }
        return out
    }

    /// Does this lane have a camera (does any of its files carry video)?
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
    var eqAudioFile: String?            // audio with the person's equalizer applied
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

/// A point on a person's volume line: at episode second `t`, `db` more or less (0 = as is).
struct VolumePoint: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var db: Double
    static let minDB = -60.0, maxDB = 12.0
}

extension Lane {
    /// Volume line dB at second `t` (linear interpolation between points; flat outside them).
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
    /// Whether a person is audible, accounting for mute and solo.
    func laneAudible(_ lane: Lane) -> Bool {
        if lane.muted { return false }
        let anySolo = lanes.contains { $0.solo }
        return !anySolo || lane.solo
    }
}

/// Simple voice equalizer. All at 0 = no change.
struct VoiceEQ: Codable, Equatable {
    var low: Double = 0                 // bass (dB, ~120 Hz)
    var mid: Double = 0                 // mids (dB, ~1 kHz)
    var high: Double = 0                // treble (dB, ~6 kHz)
    var rumbleCut = false               // remove rumble (low cut at 120 Hz + less 250 Hz)
    var compress = false                // «Voz pareja»: gentle compressor (quiet goes up, loud doesn't hit)
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
    /// Short signature to name the processed file.
    var key: String { String(format: "l%+.1fm%+.1fh%+.1f%@%@%@", low, mid, high, rumbleCut ? "r" : "", compress ? "c" : "", deess ? "d" : "") }
    var ffmpegFilter: String {
        var f: [String] = []
        if rumbleCut { f += ["highpass=f=120", "equalizer=f=250:t=q:w=1:g=-3"] }
        if abs(low) >= 0.1 { f.append(String(format: "equalizer=f=120:t=q:w=0.8:g=%.1f", low)) }
        if abs(mid) >= 0.1 { f.append(String(format: "equalizer=f=1000:t=q:w=1:g=%.1f", mid)) }
        if abs(high) >= 0.1 { f.append(String(format: "equalizer=f=6000:t=q:w=0.8:g=%.1f", high)) }
        if deess { f.append("deesser=i=0.5:m=0.5:f=0.5") }
        if compress { f.append("acompressor=threshold=-20dB:ratio=3:attack=8:release=140:makeup=4dB:knee=4") }
        f.append("alimiter=limit=0.95:level=0")
        return f.joined(separator: ",")
    }
}

/// One band of the studio's parametric equalizer.
struct EQBand: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case highpass, lowshelf, peak, highshelf, lowpass }
    var id = UUID()
    var kind: Kind = .peak
    var freq: Double = 1000             // Hz
    var gain: Double = 0                // dB (doesn't apply to high/low-pass)
    var q: Double = 1.0                 // width (approx. octaves in AUNBandEQ)
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

/// An automation point: at episode second `t`, the parameter is `v`.
struct AutoPoint: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var t: Double
    var v: Double
}

/// A third-party (or system) Audio Unit plugin inserted in a person's chain.
struct PluginInsert: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var type: UInt32          // kAudioUnitType_Effect / MusicEffect
    var subtype: UInt32
    var manufacturer: UInt32
    var name: String
    var vendor: String = ""
    var enabled = true
    var state: Data?          // ClassInfo / fullState of the plugin (its parameters)
}

/// A person's full voice chain (the studio). The simple level (`VoiceEQ`) is a preset of this.
struct ChainSettings: Codable, Equatable {
    static let maxBands = 8
    var bands: [EQBand] = []
    /// Plugins after the compressor and before the limiter, in order.
    var plugins: [PluginInsert] = []
    /// Per-parameter automation (`comp.threshold`, `eq.<band id>.gain`, …): points in episode time.
    var automation: [String: [AutoPoint]] = [:]
    var compressorOn = false
    var threshold: Double = -20          // dB
    var ratio: Double = 3               // :1 (translated to the AU's «head room»)
    var attack: Double = 0.008          // s
    var release: Double = 0.14          // s
    var makeup: Double = 4              // dB
    var deesserOn = false
    var deesserAmount: Double = 0.5     // 0…1 (how much it lowers the S's)
    var limiterOn = true
    var gateOn = false
    var gateThreshold: Double = -45     // dB (gentle expansion below)

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

    // Automatable parameters (id → how to read and write it)
    static let compThreshold = "comp.threshold", compRatio = "comp.ratio", compMakeup = "comp.makeup"
    static let deesserAmount = "deesser.amount", gateThreshold = "gate.threshold"
    static func bandGain(_ b: EQBand) -> String { "eq.\(b.id.uuidString).gain" }
    static func bandFreq(_ b: EQBand) -> String { "eq.\(b.id.uuidString).freq" }

    /// Current value (without automation) of a parameter.
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

    /// A parameter's value at episode second `t`, following its automation (linear between points).
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

    /// The chain with every automated parameter set to its value at that second.
    func resolved(at t: Double) -> ChainSettings {
        var c = self
        for (param, _) in automation { if let v = value(of: param, at: t) { c.set(param, v) } }
        c.automation = [:]
        return c
    }

    var hasAutomation: Bool { automation.values.contains { !$0.isEmpty } }

    /// Writes a point (or moves the one within 0.25 s) and also sets the base value there.
    mutating func writePoint(_ param: String, t: Double, v: Double) {
        var pts = automation[param] ?? []
        if let i = pts.firstIndex(where: { abs($0.t - t) < 0.25 }) { pts[i].v = v } else { pts.append(AutoPoint(t: t, v: v)) }
        automation[param] = pts.sorted { $0.t < $1.t }
    }

    /// What the simple level describes, translated to the chain.
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

    /// If this chain is exactly what the simple level can express, returns that preset; otherwise nil.
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
    var fadeIn: Double = 0              // seconds of fade-in for this person's audio
    var fadeOut: Double = 0             // seconds of fade-out
    var eq = VoiceEQ()                  // 3-band equalizer (the simple level)
    var chain: ChainSettings?           // the full studio chain; nil = the one `eq` describes
    var muted: Bool = false             // M: this person is silent (preview and export)
    var solo: Bool = false              // S: only people with solo sound
    var volumePoints: [VolumePoint] = []   // drawn volume: points (episode time, dB); empty = flat
    var pan: Double = 0                 // pan: −1 left … 0 center … 1 right (set by «Panorama de conversación»)
    var noiseReduce: Bool = false       // noise-print reduction (spectral subtraction, no AI)
    var noiseAmount: Double = 0.6       // amount: 0.3 gentle · 0.6 normal · 0.9 strong
    var noiseProfile: [Float]?          // the print: mean magnitude per band of the quietest second
    var noiseProfileAt: Double?         // which episode second the print came from
    var declick: Bool = false           // remove clicks and mouth smacks
    var declickAmount: Double = 0.5     // sensitivity 0…1
    var measuredLUFS: Double?           // measured loudness of this voice (gated BS.1770), if measured
    var matchGain: Double = 0           // dB that match it with the others (set by «Voces parejas por medición»)
    var grade: ColorGrade?              // Studio · Video: this camera's color (the whole person)
    var mask: ShapeMask?                // Studio · Video: where that color applies (and what's darkened outside)

    /// The chain that plays: the studio's if it exists, otherwise the simple level's preset.
    var effectiveChain: ChainSettings { chain ?? ChainSettings.preset(eq) }
    /// The studio changed something the simple level can't express.
    var tunedInStudio: Bool { chain != nil && chain?.asSimple == nil }

    /// Saves a studio chain: if the simple level can express it, it goes to the preset (and the simple
    /// controls show it); if not, it stays as a studio chain and the simple one warns.
    static func store(_ c: ChainSettings, in lane: inout Lane) {
        if let simple = c.asSimple { lane.eq = simple; lane.chain = nil } else { lane.chain = c }
    }

    var duration: Double { offset + clips.reduce(0) { $0 + $1.length } }

    /// Timeline spans of each clip.
    /// With a negative offset the person sounds earlier: the beginning of their recording is skipped
    /// (what would fall before second 0 of the episode isn't used).
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

    /// The most it can be advanced: at least one second of their recording always remains.
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
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0   // projects from before there was per-clip volume
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
    var duck: Bool?                     // duck under the voice; nil = automatic (yes if longer than 8 s: music, not effects)
    var duckDB: Double = 12
    var loop: Bool = false              // loop until the end of the episode
    var crossfade: Bool = false         // Studio · Video: curved fades (equal power), to cross with another clip
    /// Studio · Video: speed (1 = normal). 0.5 = half (lasts twice as long), 2 = double. Pitch is preserved.
    var speed: Double = 1
    var ducks: Bool { duck ?? ((srcOut - srcIn) > 8) }
    /// How long it lasts in the episode (the source, stretched or compressed by speed)
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
    var photoFile: String?              // guest photo (from prePod), relative to the project

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
    /// Doubtful suggestion (filler that may be a valid word, repeated phrase, wordless sound):
    /// starts off and isn't removed until the person marks it.
    var suggested: Bool? = nil
    /// The person already looked at it (switched it on or off by hand). Kept when fixing again.
    var reviewed: Bool? = nil
    var length: Double { max(0, end - start) }
}

struct FixSettings: Codable, Equatable {
    var removeSilences = true
    var removeFillers = true
    var removeWordFillers = false       // "este", "o sea", "pues"... off by default
    var enhanceAudio = true
    var strongNoise = false             // (old versions) no longer used: see `noiseLevel`
    var noiseLevel = 2                  // how much the voice is cleaned: 1 natural · 2 normal · 3 maximum
    var gateOthers = true               // duck the track of whoever isn't speaking (the other's keys and noises)
    var gateDB: Double = 12             // how much it's lowered: 8 gentle, 12 normal, 18 strong
    var minSilence: Double = 0.8        // seconds of silence before we cut
    var keepPad: Double = 0.18          // breathing room kept around speech
    var roomTone = true                 // room tone: fills each person's dead gaps with their own ambience and smooths the cut joins
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
    var look: ReelLook?                 // this reel's own design (nil = the one for all reels)
    var cuts: [Cut] = []                // cuts for this reel only (removed phrases, silences), apart from the episode's
    var brolls: [BRollClip] = []        // b-roll for this reel only
    var music: [AudioLaneClip] = []     // the reel's own music (used when the reel doesn't carry the episode's)
    var cintillos: [DirectorCintillo] = []   // lower thirds for this reel only
    var words: [Word]?                  // the reel's own text (only this reel was re-listened); nil = the episode's
    var seen: Bool?                     // the person already looked at it in the preview (for the review before exporting)
    var hook: String?                   // hook title: large during the first seconds of the reel (nil = no title)
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

/// A person's virtual background: the person is separated from their real background (Apple Vision, on the Mac, offline)
/// and whatever is chosen is placed behind.
struct VirtualBackground: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case blur, podcast, color, image
        var name: String {
            switch self { case .blur: return String(localized: "Difuminado"); case .podcast: return String(localized: "Fondo del podcast"); case .color: return String(localized: "Color"); case .image: return String(localized: "Imagen") }
        }
    }
    var mode: Mode = .blur
    var blur: Double = 18               // blur: how much (6 gentle … 40 very blurry)
    var color: String = "#14141A"
    var imageFile: String?              // relative to the project folder
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .blur
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 18
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#14141A"
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
    }
}

/// How a reel looks: layout, its options and branding (background, logo, names), apart from the episode.
/// `logoFile` and `backgroundFile` are a logo and background for reels only; if empty the podcast's are used.
struct ReelLook: Codable, Equatable {
    var layout: LayoutTemplate = .auto
    var options = LayoutOptions()
    var showBackground: Bool = true
    var showLogo: Bool = true
    var showNames: Bool = true
    var logoFile: String?
    var backgroundFile: String?
    var music: Bool = true              // episode music and effects in the reel
    var captions: Bool = true           // subtitles in the reel
    var captionStyle: CaptionStyle?     // the reel's own subtitle style and position (nil = the episode's)
    var laneOrder: [Int]?               // own on-screen order (nil = the episode's)
    var gateOthers: Bool?               // mute whoever isn't speaking, own setting (nil = as in Limpiar sonido)
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
    /// The design that applies to a reel: its own if it has one, otherwise the one for all reels.
    func look(for reel: Reel?) -> ReelLook { reel?.look ?? reelLook }

    /// Copy of the project with a reel's look applied on top (for that reel's preview and export).
    /// With `reel` its own cuts are also included.
    func applying(_ look: ReelLook, reel: Reel? = nil) -> Project {
        var p = self
        if let reel {
            if let own = reel.words { p.words = own }   // the reel's own text (doesn't change the episode)
            p.cuts += reel.cuts
            p.brolls += reel.brolls
            if !reel.cintillos.isEmpty { p.cintillos += reel.cintillos; p.showCintillos = true }
            // Hook title: at the top, large, from the first sound of the reel
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
        if !look.music { p.audioLane = reel?.music ?? [] }   // without the episode's: the reel's own (if any)
        if let cs = look.captionStyle { p.captionStyle = cs }
        if !look.captions { p.captionStyle.enabled = false }
        return p
    }
}

/// Intro or outro: a still image for a few seconds, with optional music (relative to the project folder).
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

/// Layout settings. Each field has a default so old projects open the same.
struct LayoutOptions: Codable, Equatable {
    var soloStudio: Bool = false        // Speaker: a framed box over the podcast background (without cropping the video)
    var gridSpeakerBig: Bool = false    // Grid: speaker large on top, the others in small tiles below
    var pipFollowSpeaker: Bool = true   // Picture-in-picture: speaker large (otherwise, always the first person)
    var punchIn: Bool = false           // subtle zoom-in on each person when their voice energy rises
    var audiogram: Bool = true          // episodes without camera: waves following the speaker's voice
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
    /// Video size. With the Free plan the short side is 720 (1280×720, 720×1280, 720×720).
    private var planNote: String { (Plan.maxHeight ?? 1080) < 1080 ? String(localized: " (plan \(Plan.name))") : "" }

    /// 4K for YouTube: only while exporting (the preview stays at 1080) and only with a plan
    /// that includes the app. Enabled with `ExportFormat.$uhd.withValue(true) { … }`.
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

/// Layer on top of the video: a text, an image or a sticker (emoji), at a moment of the episode.
/// `start` is episode time (like lower thirds): if that span is cut, it shows in whatever remains next.
struct VideoLayer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, sticker }
    /// Text styles: large outlined title, text in a dark box, colored tag.
    enum Style: String, Codable, CaseIterable { case title, box, label
        var name: String { switch self { case .title: return String(localized: "Título"); case .box: return String(localized: "Caja"); case .label: return String(localized: "Etiqueta") } }
    }
    var id: Int
    var kind: Kind
    var start: Double
    var duration: Double = 5
    var text: String = ""
    var style: Style = .title
    var color: String = "#FFFFFF"       // title/box: text color · tag: background color
    var imageFile: String?              // relative to the project folder
    var x: Double = 0.5                 // center, 0 = left … 1 = right
    var y: Double = 0.5                 // center, 0 = top … 1 = bottom
    var scale: Double = 1               // size (1 = normal)
    var animate: Bool = true            // enters and leaves with a fade and a small bounce
    /// Studio · Video: position, size, rotation and opacity keyframes (nil = the layer is still, as the simple step placed it)
    var animation: LayerAnimation?
    /// Studio · Video: how it enters and leaves (nil = `animate`'s fade with a little bounce)
    var enter: TitleMotion?
    var exit: TitleMotion?

    var end: Double { start + duration }
    /// Touched in Studio: has keyframes or ins the simple step can't express.
    var tunedInStudio: Bool { !(animation?.isEmpty ?? true) || enter != nil || exit != nil }
    var title: String {
        switch kind {
        case .text: return text.isEmpty ? String(localized: "Texto") : text
        case .sticker: return text.isEmpty ? String(localized: "Sticker") : text
        case .image: return imageFile.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? String(localized: "Imagen")
        }
    }

    /// The 9 quick positions (row 0…2, column 0…2) → layer center.
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

/// How a title, sticker or image enters (or leaves): the animation runs on the already drawn layer.
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

/// B-roll: a video or image covering the screen from `start` (episode time) for `duration` seconds;
/// the podcast's voice continues underneath. The b-roll video has no sound of its own unless `volume` is raised.
struct BRollClip: Codable, Identifiable, Equatable {
    var id: Int
    var file: String                    // relative to the project folder (broll/…)
    var isVideo: Bool
    var start: Double
    var duration: Double = 6
    var srcIn: Double = 0               // from which second of the b-roll video
    var fill: Bool = true               // fill the screen (crops) or fit entirely with borders
    var volume: Double = 0              // b-roll sound (0 = muted)
    var placement: String = "full"      // full | pipLeft | pipRight (small window at bottom left or right)
    /// Studio · Video: how this clip enters (nil = the usual short fade)
    var transitionIn: Transition?
    /// Studio · Video: video speed (1 = normal). 0.25–1 slow motion, 1–4 fast. `duration` is still what it takes on screen.
    var speed: Double = 1
    /// Speed ramp: if set, the clip goes from `speed` at the start to `speedEnd` at the end (smoothly); nil = fixed speed.
    var speedEnd: Double?
    var grade: ColorGrade?              // Studio · Video: color for this clip only
    var end: Double { start + duration }
    static let maxSeconds = 10.0

    /// Speed at a 0–1 fraction of the clip (with the ramp, smoothly interpolated; without it, `speed`).
    func speed(at f: Double) -> Double {
        guard let e = speedEnd else { return max(0.1, speed) }
        let k = min(1, max(0, f)); let ease = k * k * (3 - 2 * k)
        return max(0.1, speed + (e - speed) * ease)
    }
    /// Ramp segments to build the mix: (seconds on screen, seconds of source) per chunk, in order.
    /// Without a ramp, a single segment. `screenLen` is what it takes on screen.
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
    /// Seconds of source the whole ramp consumes in `screenLen` seconds on screen.
    func sourceNeeded(screenLen: Double) -> Double { speedSegments(screenLen: screenLen).reduce(0) { $0 + $1.source } }        // a b-roll is a short support, not another video
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

/// A curve point: at which episode second, what value, and how to get to the next point.
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

/// A layer's animation: per parameter, its keyframes (episode time). Position in frame fractions
/// (0–1, like `VideoLayer.x/y`) so the same curve works in 16:9, 9:16 and 1:1; size as a factor; rotation in
/// degrees; opacity 0–1. A parameter without keyframes uses the layer's fixed value.
struct LayerAnimation: Codable, Equatable {
    static let x = "x", y = "y", scale = "scale", rotation = "rotation", opacity = "opacity"
    static let params = [x, y, scale, rotation, opacity]
    var tracks: [String: [Keyframe]] = [:]

    var isEmpty: Bool { tracks.values.allSatisfy(\.isEmpty) }
    func has(_ p: String) -> Bool { !(tracks[p] ?? []).isEmpty }

    /// The parameter's value at `t`, or nil if it has no keyframes.
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

    /// Sets (or moves) a keyframe at `t`; two keyframes less than 40 ms apart are considered the same.
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

    /// The same animation with times converted (e.g. from the episode to the final video).
    func mapped(_ f: (Double) -> Double?) -> LayerAnimation {
        var out = LayerAnimation()
        for (p, pts) in tracks {
            let m = pts.compactMap { k -> Keyframe? in f(k.t).map { var c = k; c.t = $0; return c } }
            if !m.isEmpty { out.tracks[p] = m }
        }
        return out
    }
}

/// A camera mask (Studio · Video): an ellipse or rectangle, in fractions of that person's box, with
/// a feathered edge. Inside the camera color applies; outside, the frame stays as is (or is darkened).
/// Follows motion with position and size keyframes (x, y, scale), by hand: no automatic tracking.
struct ShapeMask: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable {
        case ellipse, rect
        var name: String { self == .ellipse ? String(localized: "Elipse") : String(localized: "Rectángulo") }
    }
    var shape: Shape = .ellipse
    var x: Double = 0.5                 // center, fraction of the box (0 = left)
    var y: Double = 0.42                // center, fraction of the box (0 = top)
    var w: Double = 0.5                 // width, fraction of the box
    var h: Double = 0.7                 // height, fraction of the box
    var feather: Double = 24            // edge feather, px at 1080p
    var invert: Bool = false            // the color goes outside, not inside
    var dimOutside: Double = 0          // 0…1: darken what's outside
    var animation: LayerAnimation?      // x, y, scale in episode time
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
    /// Where the mask is at `t`: center and scale with keyframes if any.
    func placement(at t: Double) -> (x: Double, y: Double, scale: Double) {
        (animation?.value(LayerAnimation.x, at: t) ?? x, animation?.value(LayerAnimation.y, at: t) ?? y, animation?.value(LayerAnimation.scale, at: t) ?? 1)
    }
}

/// How a clip enters from what came before.
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

/// A camera span pinned by hand in Studio (episode time): within it, it beats «sigue a quien habla».
struct CameraCut: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var lane: Int?                      // the person shown large; nil = everyone, with the template
    var template: LayoutTemplate?       // template for this span only; nil = the project's
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

/// What Studio · Video decides about the cameras.
struct StudioVideoSettings: Codable, Equatable {
    var followSpeaker = true            // automatic cuts to the speaker (off: the project's fixed template)
    var minHold = 2.5                   // minimum seconds on a camera before switching (to avoid «flicking»)
    var cuts: [CameraCut] = []          // spans pinned by hand
    /// Multicam: how to go from one camera to another (nil = hard cut). Only fade or smooth zoom make sense here.
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
    /// The manual span covering `t` (episode time), if any.
    func cut(at t: Double) -> CameraCut? { cuts.first { t >= $0.start && t < $0.end } }

    /// Live multicam: cut to `lane` at second `t` (key 1–4 or click on the angle). The span that covered `t`
    /// ends there; the new one lasts until the next manual cut or until `duration`. Returns the created cut.
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

// MARK: - Shared review

/// A comment left from the review link: `t` is the second of the reviewed file (final video, with intro).
struct ReviewComment: Codable, Equatable, Identifiable {
    var id: Int
    var t: Double
    var author: String
    var text: String
    var resolved: Bool
}

/// This episode's review link and the last read of its comments.
struct ReviewLink: Codable, Equatable {
    var token: String
    var url: String
    var sentAt: Date
    var introDuration: Double = 0        // the reviewed file had this intro: to map `t` to the episode
    var keepPairs: [[Double]] = []       // and these spans [[start, end], …]
    var comments: [ReviewComment] = []
    var fetchedAt: Date?
    init(token: String, url: String, sentAt: Date, introDuration: Double = 0, keep: [EditEngine.Span] = []) {
        self.token = token; self.url = url; self.sentAt = sentAt; self.introDuration = introDuration
        keepPairs = keep.map { [$0.start, $0.end] }
    }
    var keep: [EditEngine.Span] { keepPairs.compactMap { $0.count == 2 ? (start: $0[0], end: $0[1]) : nil } }
    /// Episode second of a comment (what the timeline marks).
    func timelineTime(_ c: ReviewComment) -> Double {
        keep.isEmpty ? max(0, c.t - introDuration) : EditEngine.toTimeline(max(0, c.t - introDuration), keep: keep)
    }
}

/// News-style lower third the director launched during recording.
struct DirectorCintillo: Codable, Equatable, Identifiable {
    var id: Int
    var kind: String            // sponsor | banner | segment | comment
    var title: String
    var text: String
    var start: Double           // seconds since the recording started
    var duration: Double
    var logoFile: String?       // relative to the project folder
    // Since 0.10: lower thirds created in the app, with a style
    var style: String = "news"  // news (two bars) | clean (line and text) | sponsor (card with logo)
    var tag: String?            // bar label ("AHORA", "PATROCINA"…); nil = per `kind`; "" = no label
    var color: String?          // hex; nil = the podcast's color (or `kind`'s)
    var sound: Bool = true      // low whoosh on entering and leaving
    var fromDirector: Bool = false   // came from prodPod (the director launched it live)

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
        // Those saved before 0.10 were all from the director
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

/// A cover candidate capture: an episode second where everyone looks good.
struct CoverCandidate: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double                    // episode second (timeline)
    var score: Double                   // 0…1: how much they smile, eyes open, sharpness
    var allSmiling: Bool                // everyone with a face is smiling in this frame
    var faces: Int                      // faces found (summing the lanes)
    var file: String                    // JPEG in the project cache
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

    /// Studio · Video: if clip `id` overlaps another on the music track, crosses them (curved fades the length
    /// of the overlap). If they no longer overlap, fades a cross had set are removed.
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
                // They were separated: the cross no longer exists
                audioLane[a].fadeOut = 0; audioLane[b].fadeIn = 0
            }
        }
    }

    /// Crosses two clips: moves the second earlier so they overlap `seconds` and sets curved fades.
    mutating func crossfade(_ firstId: Int, with secondId: Int, seconds: Double) {
        guard let a = audioLane.firstIndex(where: { $0.id == firstId }), let b = audioLane.firstIndex(where: { $0.id == secondId }) else { return }
        audioLane[b].tlStart = max(audioLane[a].tlStart + 0.5, audioLane[a].tlEnd - seconds)
        crossfadeOverlaps(touching: secondId)
    }

    /// Conversation panning: each person slightly to one side, in on-screen order (left →
    /// right), never beyond ±0.3 so nobody gets lost on a mono speaker. A single person stays centered.
    static func conversationPans(count n: Int) -> [Double] {
        guard n >= 2 else { return [Double](repeating: 0, count: n) }
        let spread = min(0.3, 0.2 + 0.05 * Double(n - 2))
        return (0..<n).map { -spread + 2 * spread * Double($0) / Double(n - 1) }
    }
    /// Sets the conversation pans on the people according to their on-screen order.
    mutating func applyConversationPans() {
        let order = lanesOnScreen.map(\.id)
        let pans = Self.conversationPans(count: order.count)
        for (i, id) in order.enumerated() {
            if let li = lanes.firstIndex(where: { $0.id == id }) { lanes[li].pan = (pans[i] * 100).rounded() / 100 }
        }
    }

    /// Studio · Video touched something the simple level can't express (keyframes, transitions, manual cameras).
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
    var freeX: Double?                  // free position (center, 0…1 from the left); nil = use `position`
    var freeY: Double?                  // free position (center, 0…1 from the top)
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
    /// Words for subtitles and transcript, with sensitive words already replaced.
    var captionWords: [Word] {
        let marks = sensitive.filter { $0.replace && !$0.ignored && !$0.replacement.isEmpty }
        guard !marks.isEmpty else { return words }
        let byId = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func plain(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        return words.map { w in
            // By id (person + exact time); otherwise the same word from the same person within 0.6 s
            // (a reel's own text was written again and its timings aren't identical to the episode's).
            guard let m = byId[SensitiveMark.makeId(lane: w.lane, s: w.s)]
                    ?? marks.first(where: { $0.lane == w.lane && abs($0.s - w.s) < 0.6 && plain($0.word) == plain(w.w) })
            else { return w }
            var out = w
            // Keeps the original word's initial capital and final punctuation
            let trimmed = w.w.trimmingCharacters(in: .whitespaces)
            let tail = trimmed.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed()
            var rep = m.replacement
            if let f = trimmed.first, f.isUppercase, let r = rep.first { rep = String(r).uppercased() + rep.dropFirst() }
            out.w = rep + String(tail)
            return out
        }
    }

    /// Spans (episode time) that carry a beep, per person.
    var bleeps: [(lane: Int, start: Double, end: Double)] {
        sensitive.filter { $0.bleep && !$0.ignored }.map { ($0.lane, $0.s, $0.e) }
    }
}
