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
