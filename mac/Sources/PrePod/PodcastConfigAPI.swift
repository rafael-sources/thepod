import Foundation

// Configuración del podcast en prePod: datos, branding, equipo, sponsors, soundboard y distribución.

struct PodcastConfig: Decodable, Hashable {
    let slug: String
    var name: String
    var description: String?
    var tagline: String?
    var colorPrimary: String?
    var colorSecondary: String?
    var colorAccent: String?
    var colorBg: String?
    var colorText: String?
    var fontHeading: String?
    var fontBody: String?
    var logoUrl: String?
    var coverUrl: String?
    var backgroundUrl: String?
    var directors: [String]?
}

struct PodcastHosts: Decodable {
    var owner: String?
    var extraHosts: [String]
    var directors: [String]?
    var invitations: [String: Invitation]?
    struct Invitation: Decodable { var status: String? }
}

struct SuiteUser: Decodable, Identifiable, Hashable {
    let username: String
    var displayName: String?
    var id: String { username }
    var label: String { displayName.map { "\($0) (\(username))" } ?? username }
}

struct Sponsor2: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var copy: String
    var url: String
    var notes: String
    var isActive: Bool
    var logoUrl: String?
    var episodeCount: Int?
}

struct SoundItem: Decodable, Identifiable, Hashable {
    let id: Int
    var name: String
    var shortcutKey: String?
    var color: String?
    var url: String?
}

struct LibrarySound: Decodable, Identifiable, Hashable {
    let filename: String
    let name: String
    var id: String { filename }
}

struct DistributionInfo: Decodable {
    struct Platform: Decodable, Hashable {
        let platform: String
        var status: String
        var name: String?
        var submitUrl: String?
        var help: String?
        var externalUrl: String?
    }
    struct Validation: Decodable { var valid: Bool; var issues: [String]; var warnings: [String] }
    var platforms: [String: Platform]
    var feedUrl: String?
    var validation: Validation?
}

extension PrePodClient {
    private func dec<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        let j = JSONDecoder(); j.keyDecodingStrategy = .convertFromSnakeCase
        return try j.decode(T.self, from: d)
    }
    private func pc(_ slug: String) -> String { "/api/podcasts/\(slug)" }

    // General y branding
    func podcastConfig(_ slug: String) async throws -> PodcastConfig { try dec(PodcastConfig.self, await send("GET", pc(slug))) }
    func updatePodcast(_ slug: String, _ fields: [String: Any]) async throws -> PodcastConfig {
        try dec(PodcastConfig.self, await send("PUT", pc(slug), json: fields))
    }
    func fonts() async throws -> [String] {
        ((try JSONSerialization.jsonObject(with: await send("GET", "/api/config/fonts")) as? [String: Any])?["fonts"] as? [String]) ?? []
    }
    func uploadBranding(_ slug: String, kind: String, file: URL) async throws {
        _ = try await upload(pc(slug) + "/branding/\(kind)", field: "file", file: file)
    }
    func deleteBranding(_ slug: String, kind: String) async throws { _ = try await send("DELETE", pc(slug) + "/branding/\(kind)") }
    /// Imágenes y audios de prePod (necesitan la sesión).
    func media(_ path: String) async throws -> Data { try await send("GET", path) }

    // Equipo
    func hosts(_ slug: String) async throws -> PodcastHosts { try dec(PodcastHosts.self, await send("GET", pc(slug) + "/hosts")) }
    func setHosts(_ slug: String, _ list: [String]) async throws { _ = try await send("PUT", pc(slug) + "/hosts", json: ["extra_hosts": list]) }
    func inviteHost(_ slug: String, _ user: String) async throws { _ = try await send("POST", pc(slug) + "/invite-host", json: ["username": user]) }
    func addDirector(_ slug: String, _ user: String) async throws { _ = try await send("POST", pc(slug) + "/directors", json: ["username": user]) }
    func removeDirector(_ slug: String, _ user: String) async throws { _ = try await send("DELETE", pc(slug) + "/directors/\(user)") }
    func searchUsers(_ q: String) async throws -> [SuiteUser] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try dec([SuiteUser].self, await send("GET", "/api/podcasts/search-users?q=\(enc)"))
    }

    // Sponsors
    func sponsors(_ slug: String) async throws -> [Sponsor2] { try dec([Sponsor2].self, await send("GET", pc(slug) + "/sponsors")) }
    func addSponsor(_ slug: String, name: String) async throws -> Sponsor2 {
        try dec(Sponsor2.self, await send("POST", pc(slug) + "/sponsors", json: ["name": name]))
    }
    func updateSponsor(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws {
        _ = try await send("PATCH", pc(slug) + "/sponsors/\(id)", json: fields)
    }
    func deleteSponsor(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pc(slug) + "/sponsors/\(id)") }
    func uploadSponsorLogo(_ slug: String, _ id: Int, file: URL) async throws -> Sponsor2 {
        try dec(Sponsor2.self, await upload(pc(slug) + "/sponsors/\(id)/logo", field: "logo", file: file))
    }

    // Soundboard
    func sounds(_ slug: String) async throws -> [SoundItem] { try dec([SoundItem].self, await send("GET", pc(slug) + "/sounds")) }
    func addSound(_ slug: String, file: URL, name: String) async throws -> SoundItem {
        try dec(SoundItem.self, await upload(pc(slug) + "/sounds", field: "file", file: file, fields: ["name": name]))
    }
    func updateSound(_ slug: String, _ id: Int, _ fields: [String: Any]) async throws { _ = try await send("PUT", pc(slug) + "/sounds/\(id)", json: fields) }
    func deleteSound(_ slug: String, _ id: Int) async throws { _ = try await send("DELETE", pc(slug) + "/sounds/\(id)") }
    func soundLibrary() async throws -> [LibrarySound] {
        let obj = (try JSONSerialization.jsonObject(with: await send("GET", "/api/sound-library")) as? [String: Any]) ?? [:]
        let arr = (obj["sounds"] as? [[String: Any]]) ?? []
        return arr.compactMap { d in
            guard let f = d["filename"] as? String else { return nil }
            return LibrarySound(filename: f, name: (d["name"] as? String) ?? f)
        }
    }
    func importSounds(_ slug: String, _ files: [String]) async throws { _ = try await send("POST", pc(slug) + "/sounds/import", json: ["filenames": files]) }

    // Distribución
    func distribution(_ slug: String) async throws -> DistributionInfo { try dec(DistributionInfo.self, await send("GET", pc(slug) + "/distribution")) }
    func setDistribution(_ slug: String, platform: String, status: String, url: String) async throws {
        _ = try await send("POST", pc(slug) + "/distribution", json: ["platform": platform, "status": status, "external_url": url])
    }
}
