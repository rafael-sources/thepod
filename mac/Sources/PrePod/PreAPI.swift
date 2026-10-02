import Foundation

// Sección "pre" de thePod: lo mismo que prePod web, leído y guardado directo en prePod.

enum EpisodeStatus: String, CaseIterable, Identifiable, Codable {
    case idea, planning, scripted, recorded, published, archived
    var id: String { rawValue }
    var title: String {
        switch self {
        case .idea: return "Idea"
        case .planning: return "Planificando"
        case .scripted: return "Con guion"
        case .recorded: return "Grabado"
        case .published: return "Publicado"
        case .archived: return "Archivado"
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
    var aiSummary: String?

    var statusValue: EpisodeStatus { EpisodeStatus(rawValue: status) ?? .idea }
    var label: String { "\(episodeNumber.map { "Ep \($0) · " } ?? "")\(title)" }
    /// Fecha programada legible (acepta "2026-10-02" o "2026-10-02T19:00…").
    var whenText: String? {
        guard let raw = scheduledAt ?? scheduledDate, raw.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "es"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(raw.prefix(10))) else { return raw }
        let out = DateFormatter(); out.locale = Locale(identifier: "es"); out.dateFormat = "EEE d MMM"
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
    // Teleprompter (0.11): quién lo lee (usuario del conductor o nombre del invitado), cuándo, velocidad y tamaño
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
        case .intro: return "Intro"
        case .segment: return "Segmento"
        case .interview: return "Entrevista"
        case .sponsor: return "Sponsor"
        case .break: return "Pausa"
        case .outro: return "Cierre"
        case .custom: return "Otro"
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

    var roleTitle: String { ["host": "Conductor", "co-host": "Co-conductor", "guest": "Invitado"][role] ?? role }
    var rsvpTitle: String { ["pending": "Sin responder", "yes": "Confirmado", "no": "No viene", "maybe": "Tal vez"][rsvpStatus] ?? rsvpStatus }
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

    // Episodios
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

    // Guion
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

    // Invitados
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
    /// Envía la invitación por correo. Devuelve (ok, mensaje para mostrar).
    func sendRSVP(_ slug: String, _ id: Int) async throws -> (Bool, String) {
        let data = try await send("POST", ep(slug) + "/guests/\(id)/send-rsvp")
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if obj["ok"] as? Bool == true { return (true, "Invitación enviada") }
        if obj["reason"] as? String == "no_smtp" { return (false, "prePod no tiene correo configurado; copia el link de confirmación") }
        return (false, (obj["error"] as? String) ?? "No se pudo enviar")
    }
}

// MARK: - Ideas, plantillas, landing, notas, correos

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

    // prePod guarda show_* como 0/1
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

    // Plantillas
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
    /// Crea el episodio con una plantilla elegida (nil = sin plantilla).
    func createEpisode(_ slug: String, title: String, templateId: Int?) async throws -> PreEpisode {
        try dj(PreEpisode.self, await send("POST", pp(slug) + "/episodes",
                                          json: ["title": title, "template_id": templateId.map { $0 as Any } ?? NSNull()]))
    }

    // Sponsor por bloque
    func setBlockSponsor(_ slug: String, _ blockId: Int, sponsorId: Int?) async throws {
        _ = try await send("PUT", pp(slug) + "/blocks/\(blockId)/sponsor", json: ["sponsor_id": sponsorId.map { $0 as Any } ?? NSNull()])
    }

    // Notas del episodio, links y correos
    func showNotes(_ slug: String, _ epId: Int) async throws -> ShowNotes { try dj(ShowNotes.self, await send("GET", pp(slug) + "/episodes/\(epId)/show-notes")) }
    func syncNotes(_ slug: String, _ epId: Int) async throws { _ = try await send("POST", pp(slug) + "/episodes/\(epId)/sync-notes") }
    func links(_ slug: String, _ epId: Int) async throws -> [EpisodeLink] { try dj([EpisodeLink].self, await send("GET", pp(slug) + "/episodes/\(epId)/links")) }
    func setLink(_ slug: String, _ epId: Int, platform: String, url: String) async throws {
        _ = try await send("POST", pp(slug) + "/episodes/\(epId)/links", json: ["platform": platform, "url": url])
    }
    func deleteLink(_ slug: String, _ epId: Int, platform: String) async throws { _ = try await send("DELETE", pp(slug) + "/episodes/\(epId)/links/\(platform)") }
    /// Correo de preparación a todos los invitados con correo. Devuelve (enviados, total, detalle).
    func sendPreRecording(_ slug: String, _ epId: Int) async throws -> (Int, Int, String) {
        let d = try await send("POST", pp(slug) + "/episodes/\(epId)/send-pre-recording", json: [:])
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let results = (o["results"] as? [[String: Any]]) ?? []
        let noSMTP = results.contains { ($0["reason"] as? String) == "no_smtp" }
        return ((o["sent"] as? Int) ?? 0, (o["total"] as? Int) ?? results.count,
                noSMTP ? "prePod no tiene configurado el envío de correos." : "")
    }

    // Landing y equipo
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
