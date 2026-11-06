import Foundation

/// Projects live in ~/Movies/postPod/<slug>/ with a project.json plus media/ and exports/.
enum ProjectStore {
    static var libraryURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let url = movies.appendingPathComponent("postPod", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(for slug: String) -> URL {
        libraryURL.appendingPathComponent(slug, isDirectory: true)
    }

    static func url(_ relative: String, in slug: String) -> URL {
        folder(for: slug).appendingPathComponent(relative)
    }

    static func exportsFolder(for slug: String) -> URL {
        let u = folder(for: slug).appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func cacheFolder(for slug: String) -> URL {
        let u = folder(for: slug).appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func save(_ project: Project) throws {
        let folder = folder(for: project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder.encode(project)
        try data.write(to: folder.appendingPathComponent("project.json"), options: .atomic)
    }

    static func load(slug: String) throws -> Project {
        let data = try Data(contentsOf: folder(for: slug).appendingPathComponent("project.json"))
        return try decoder.decode(Project.self, from: data)
    }

    static func listProjects() -> [Project] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            guard fm.fileExists(atPath: url.appendingPathComponent("project.json").path) else { return nil }
            return try? load(slug: url.lastPathComponent)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(slug: String) throws {
        try FileManager.default.trashItem(at: folder(for: slug), resultingItemURL: nil)
    }

    static func uniqueSlug(for name: String) -> String {
        let base = slugify(name)
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(for: slug).path) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    static func slugify(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var lastDash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 { out = String(out.prefix(60)) }
        return out.isEmpty ? "proyecto" : out
    }
}
