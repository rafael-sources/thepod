import Foundation

// thePod's "pre" section: the same as prePod web, read from and saved directly to prePod.

enum EpisodeStatus: String, CaseIterable, Identifiable, Codable {
    case idea, planning, scripted, recorded, published, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: return String(localized: "Idea")
        case .planning: return String(localized: "Planificando")
        case .scripted: return String(localized: "Con guion")
        case .recorded: return String(localized: "Grabado")
        case .published: return String(localized: "Publicado")
        case .archived: return String(localized: "Archivado")
        }
    }
    var symbol: String {
        switch self {
        case .idea: return "lightbulb"
        case .planning: return "list.bullet.clipboard"
        case .scripted: return "text.page"
        case .recorded: return "mic.fill"
        case .published: return "paperplane.fill"
        case .archived: return "archivebox"
        }
    }
}

struct PrePodcast: Decodable, Identifiable, Hashable {
    let slug: String
    let name: String
    var description: String?
    var tagline: String?
    var colorPrimary: String?
    var colorAccent: String?
    var id: String { slug }
}

struct PreEpisode: Decodable, Identifiable, Hashable {
    let id: Int
    var episodeNumber: Int?
    var title: String
    var description: String?
    var status: String
    var scheduledDate: String?
    var scheduledAt: String?
    var durationEstimate: Double?

    var statusValue: EpisodeStatus { EpisodeStatus(rawValue: status) ?? .idea }
    var label: String { "\(episodeNumber.map { "Ep \($0) · " } ?? "")\(title)" }
    /// Human-readable scheduled date (accepts "2026-10-02" or "2026-10-02T19:00…").
    var whenText: String? {
        guard let raw = scheduledAt ?? scheduledDate, raw.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(raw.prefix(10))) else { return raw }
        let out = DateFormatter(); out.locale = AppLanguage.locale; out.dateFormat = "EEE d MMM"
        var s = out.string(from: d)
        if raw.count >= 16, raw.dropFirst(10).first == "T" { s += " · " + raw.dropFirst(11).prefix(5) }
        return s
    }
}

struct ScriptSection: Decodable, Identifiable, Hashable {
    let id: Int
    var position: Int
    var speaker: String
    var content: String
    var estimatedDuration: Double?
    var notes: String
    // Teleprompter (0.11): who reads it (host username or guest name), when, speed and size
    var tpEnabled: Bool?
    var tpOffsetSeconds: Double?
    var tpSpeed: String?
    var tpSize: String?
    var tpSpeaker: String?
    var tpAfterPrev: Bool?
    var tpGapSeconds: Double?
}

enum BlockKind: String, CaseIterable, Identifiable {
    case intro, segment, interview, sponsor, `break`, outro, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .intro: return String(localized: "Intro")
        case .segment: return String(localized: "Segmento")
        case .interview: return String(localized: "Entrevista")
        case .sponsor: return String(localized: "Sponsor")
        case .break: return String(localized: "Pausa")
        case .outro: return String(localized: "Cierre")
        case .custom: return String(localized: "Otro")
        }
    }
}

struct RundownBlock: Decodable, Identifiable, Hashable {
    let id: Int
    var position: Int
    var kind: String
    var title: String
    var durationEstimate: Double?
    var notes: String
    var sponsorId: Int?
}

struct PreGuest: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var email: String
    var role: String
    var bio: String
    var rsvpStatus: String
    var rsvpUrl: String?
    var socialInstagram: String?
    var socialTwitter: String?

    var roleTitle: String { ["host": String(localized: "Conductor"), "co-host": String(localized: "Co-conductor"), "guest": String(localized: "Invitado")][role] ?? role }
    var rsvpTitle: String { ["pending": String(localized: "Sin responder"), "yes": String(localized: "Confirmado"), "no": String(localized: "No viene"), "maybe": String(localized: "Tal vez")][rsvpStatus] ?? rsvpStatus }
}

extension PrePodClient {
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(T.self, from: data)
    }
    private func ep(_ slug: String) -> String { "/api/podcasts/\(slug)" }

    func prePodcasts() async throws -> [PrePodcast] {
        try decode([PrePodcast].self, await send("GET", "/api/podcasts"))
    }

    /// Creates a new podcast in prePod (same as «+ Nuevo podcast» on the web) and returns its slug.
    func createPrePodcast(name: String) async throws -> String {
        let d = try await send("POST", "/api/podcasts", json: ["name": name])
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let slug = o["slug"] as? String else {
            throw NSError(domain: "prePod", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "prePod no devolvió el podcast creado")])
        }
        return slug
    }

    // Episodes
    func preEpisodes(_ slug: String) async throws -> [PreEpisode] {
        try decode([PreEpisode].self, await send("GET", ep(slug) + "/episodes"))
    }
    func createEpisode(_ slug: String, title: String) async throws -> PreEpisode {
        try decode(PreEpisode.self, await send("POST", ep(slug) + "/episodes", json: ["title": title]))
    }
    func updateEpisode(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws -> PreEpisode {
        try decode(PreEpisode.self, await send("PUT", ep(slug) + "/episodes/\(id)", json: fields))
    }
    func deleteEpisode(_ slug: String, _ id: Int) async throws {
        _ = try await send("DELETE", ep(slug) + "/episodes/\(id)")
    }

    // Script
    func script(_ slug: String, _ epId: Int) async throws -> [ScriptSection] {
        try decode([ScriptSection].self, await send("GET", ep(slug) + "/episodes/\(epId)/script"))
    }
    func addSection(_ slug: String, _ epId: Int, speaker: String = "", content: String = "") async throws -> ScriptSection {
        try decode(ScriptSection.self, await send("POST", ep(slug) + "/episodes/\(epId)/script",
                                                 json: ["speaker": speaker, "content": content]))
    }
    func updateSection(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws {
        _ = try await send("PUT", ep(slug) + "/script-sections/\(id)", json: fields)
    }
    func deleteSection(_ slug: String, _ id: Int) async throws {
        _ = try await send("DELETE", ep(slug) + "/script-sections/\(id)")
    }

    // Rundown
    func blocks(_ slug: String, _ epId: Int) async throws -> [RundownBlock] {
        try decode([RundownBlock].self, await send("GET", ep(slug) + "/episodes/\(epId)/blocks"))
    }
    func addBlock(_ slug: String, _ epId: Int, kind: BlockKind, title: String) async throws -> RundownBlock {
        try decode(RundownBlock.self, await send("POST", ep(slug) + "/episodes/\(epId)/blocks",
                                                 json: ["kind": kind.rawValue, "title": title]))
    }
    func updateBlock(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws {
        _ = try await send("PUT", ep(slug) + "/blocks/\(id)", json: fields)
    }
    func reorderBlocks(_ slug: String, _ epId: Int, order: [Int]) async throws -> [RundownBlock] {
        try decode([RundownBlock].self, await send("POST", ep(slug) + "/episodes/\(epId)/blocks/reorder", json: ["order": order]))
    }
    func deleteBlock(_ slug: String, _ id: Int) async throws {
        _ = try await send("DELETE", ep(slug) + "/blocks/\(id)")
    }

    // Guests
    func guests(_ slug: String, _ epId: Int) async throws -> [PreGuest] {
        try decode([PreGuest].self, await send("GET", ep(slug) + "/episodes/\(epId)/guests"))
    }
    func addGuest(_ slug: String, _ epId: Int, name: String, email: String, role: String) async throws -> PreGuest {
        try decode(PreGuest.self, await send("POST", ep(slug) + "/episodes/\(epId)/guests",
                                             json: ["name": name, "email": email, "role": role]))
    }
    func updateGuest(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws {
        _ = try await send("PUT", ep(slug) + "/guests/\(id)", json: fields)
    }
    func deleteGuest(_ slug: String, _ id: Int) async throws {
        _ = try await send("DELETE", ep(slug) + "/guests/\(id)")
    }
    /// Sends the invitation by email. Returns (ok, message to show).
    func sendRSVP(_ slug: String, _ id: Int) async throws -> (Bool, String) {
        let data = try await send("POST", ep(slug) + "/guests/\(id)/send-rsvp")
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if obj["ok"] as? Bool == true { return (true, String(localized: "Invitación enviada")) }
        if obj["reason"] as? String == "no_smtp" { return (false, String(localized: "prePod no tiene correo configurado; copia el link de confirmación")) }
        return (false, (obj["error"] as? String) ?? String(localized: "No se pudo enviar"))
    }
}

// MARK: - Ideas, templates, landing, notes, emails

struct EpisodeIdea: Decodable, Identifiable, Hashable {
    let id: Int
    var content: String
    var author: String
    var status: String
    var votes: Int
    var votedByMe: Bool
}

struct ShowTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var description: String?
    var isDefault: Bool
    var blockCount: Int?
    var sectionCount: Int?
}

struct TemplateDetail: Decodable {
    var id: Int
    var name: String
    var description: String?
    var isDefault: Bool
    var blocks: [RundownBlock]
    var sections: [ScriptSection]
}

struct LandingConfig: Decodable {
    var template: String?
    var showEpisodes: Bool?
    var showTeam: Bool?
    var ownerName: String?
    var ownerEmail: String?
    var language: String?
    var socialYoutube: String?
    var socialSpotify: String?
    var socialApplePodcasts: String?
    var socialInstagram: String?
    var socialTiktok: String?
    var socialTwitter: String?

    // prePod stores show_* as 0/1
    enum CodingKeys: String, CodingKey {
        case template, showEpisodes, showTeam, ownerName, ownerEmail, language, socialYoutube, socialSpotify,
             socialApplePodcasts, socialInstagram, socialTiktok, socialTwitter
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func flag(_ k: CodingKeys) -> Bool? {
            if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i != 0 }
            return nil
        }
        template = try? c.decodeIfPresent(String.self, forKey: .template)
        showEpisodes = flag(.showEpisodes); showTeam = flag(.showTeam)
        ownerName = try? c.decodeIfPresent(String.self, forKey: .ownerName)
        ownerEmail = try? c.decodeIfPresent(String.self, forKey: .ownerEmail)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        socialYoutube = try? c.decodeIfPresent(String.self, forKey: .socialYoutube)
        socialSpotify = try? c.decodeIfPresent(String.self, forKey: .socialSpotify)
        socialApplePodcasts = try? c.decodeIfPresent(String.self, forKey: .socialApplePodcasts)
        socialInstagram = try? c.decodeIfPresent(String.self, forKey: .socialInstagram)
        socialTiktok = try? c.decodeIfPresent(String.self, forKey: .socialTiktok)
        socialTwitter = try? c.decodeIfPresent(String.self, forKey: .socialTwitter)
    }
}

struct TeamMember: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var role: String?
    var bio: String?
    var imageUrl: String?
    var socialInstagram: String?
    var socialTwitter: String?
    var socialWebsite: String?
}

struct ShowNotes: Decodable {
    var text: String
}

struct EpisodeLink: Decodable, Identifiable, Hashable {
    let id: Int
    var platform: String
    var url: String
}

extension PrePodClient {
    private func dj<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        let j = JSONDecoder(); j.keyDecodingStrategy = .convertFromSnakeCase
        return try j.decode(T.self, from: d)
    }
    private func pp(_ slug: String) -> String { "/api/podcasts/\(slug)" }

    // Ideas
    func ideas(_ slug: String, _ epId: Int) async throws -> [EpisodeIdea] { try dj([EpisodeIdea].self, await send("GET", pp(slug) + "/episodes/\(epId)/ideas")) }
    func addIdea(_ slug: String, _ epId: Int, _ text: String) async throws -> EpisodeIdea {
        try dj(EpisodeIdea.self, await send("POST", pp(slug) + "/episodes/\(epId)/ideas", json: ["content": text]))
    }
    func setIdeaStatus(_ slug: String, _ id: Int, _ status: String) async throws { _ = try await send("PUT", pp(slug) + "/ideas/\(id)", json: ["status": status]) }
    func deleteIdea(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pp(slug) + "/ideas/\(id)") }
    func vote(_ slug: String, _ id: Int, on: Bool) async throws { _ = try await send(on ? "POST" : "DELETE", pp(slug) + "/ideas/\(id)/vote") }

    // Templates
    func templates(_ slug: String) async throws -> [ShowTemplate] { try dj([ShowTemplate].self, await send("GET", pp(slug) + "/templates")) }
    func template(_ slug: String, _ id: Int) async throws -> TemplateDetail { try dj(TemplateDetail.self, await send("GET", pp(slug) + "/templates/\(id)")) }
    func addTemplate(_ slug: String, name: String) async throws -> ShowTemplate {
        try dj(ShowTemplate.self, await send("POST", pp(slug) + "/templates", json: ["name": name]))
    }
    func updateTemplate(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws { _ = try await send("PATCH", pp(slug) + "/templates/\(id)", json: fields) }
    func deleteTemplate(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pp(slug) + "/templates/\(id)") }
    func addTemplateBlock(_ slug: String, _ tid: Int, kind: BlockKind) async throws -> RundownBlock {
        try dj(RundownBlock.self, await send("POST", pp(slug) + "/templates/\(tid)/blocks", json: ["kind": kind.rawValue, "title": kind.title]))
    }
    func updateTemplateBlock(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws { _ = try await send("PUT", pp(slug) + "/template-blocks/\(id)", json: fields) }
    func reorderTemplateBlocks(_ slug: String, _ tid: Int, _ order: [Int]) async throws -> [RundownBlock] {
        try dj([RundownBlock].self, await send("POST", pp(slug) + "/templates/\(tid)/blocks/reorder", json: ["order": order]))
    }
    func deleteTemplateBlock(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pp(slug) + "/template-blocks/\(id)") }
    func addTemplateSection(_ slug: String, _ tid: Int) async throws -> ScriptSection {
        try dj(ScriptSection.self, await send("POST", pp(slug) + "/templates/\(tid)/sections", json: ["speaker": "", "content": ""]))
    }
    func updateTemplateSection(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws { _ = try await send("PUT", pp(slug) + "/template-sections/\(id)", json: fields) }
    func deleteTemplateSection(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pp(slug) + "/template-sections/\(id)") }
    /// Creates the episode with a chosen template (nil = no template).
    func createEpisode(_ slug: String, title: String, templateId: Int?) async throws -> PreEpisode {
        try dj(PreEpisode.self, await send("POST", pp(slug) + "/episodes",
                                          json: ["title": title, "template_id": templateId.map { $0 as Any } ?? NSNull()]))
    }

    // Sponsor per block
    func setBlockSponsor(_ slug: String, _ blockId: Int, sponsorId: Int?) async throws {
        _ = try await send("PUT", pp(slug) + "/blocks/\(blockId)/sponsor", json: ["sponsor_id": sponsorId.map { $0 as Any } ?? NSNull()])
    }

    // Episode notes, links and emails
    func showNotes(_ slug: String, _ epId: Int) async throws -> ShowNotes { try dj(ShowNotes.self, await send("GET", pp(slug) + "/episodes/\(epId)/show-notes")) }
    func links(_ slug: String, _ epId: Int) async throws -> [EpisodeLink] { try dj([EpisodeLink].self, await send("GET", pp(slug) + "/episodes/\(epId)/links")) }
    func setLink(_ slug: String, _ epId: Int, platform: String, url: String) async throws {
        _ = try await send("POST", pp(slug) + "/episodes/\(epId)/links", json: ["platform": platform, "url": url])
    }
    func deleteLink(_ slug: String, _ epId: Int, platform: String) async throws { _ = try await send("DELETE", pp(slug) + "/episodes/\(epId)/links/\(platform)") }
    /// Prep email to every guest with an email. Returns (sent, total, detail).
    func sendPreRecording(_ slug: String, _ epId: Int) async throws -> (Int, Int, String) {
        let d = try await send("POST", pp(slug) + "/episodes/\(epId)/send-pre-recording", json: [:])
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let results = (o["results"] as? [[String: Any]]) ?? []
        let noSMTP = results.contains { ($0["reason"] as? String) == "no_smtp" }
        return ((o["sent"] as? Int) ?? 0, (o["total"] as? Int) ?? results.count,
                noSMTP ? String(localized: "prePod no tiene configurado el envío de correos.") : "")
    }

    // Landing and team
    func landing(_ slug: String) async throws -> LandingConfig { try dj(LandingConfig.self, await send("GET", pp(slug) + "/landing")) }
    func updateLanding(_ slug: String, _ fields: [String: Any]) async throws { _ = try await send("PUT", pp(slug) + "/landing", json: fields) }
    func team(_ slug: String) async throws -> [TeamMember] { try dj([TeamMember].self, await send("GET", pp(slug) + "/team")) }
    func addTeamMember(_ slug: String, name: String) async throws -> TeamMember {
        try dj(TeamMember.self, await send("POST", pp(slug) + "/team", json: ["name": name]))
    }
    func updateTeamMember(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws { _ = try await send("PUT", pp(slug) + "/team/\(id)", json: fields) }
    func deleteTeamMember(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pp(slug) + "/team/\(id)") }
    func uploadTeamImage(_ slug: String, _ id: Int, file: URL) async throws { _ = try await upload(pp(slug) + "/team/\(id)/image", field: "file", file: file) }
}
