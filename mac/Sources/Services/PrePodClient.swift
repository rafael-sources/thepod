import Foundation

/// Talks to prePod's /api/mac endpoints to publish a finished episode using what prePod
/// already has configured: VPS hosting + RSS feed (Spotify / Apple) and YouTube OAuth.
actor PrePodClient {
    static let shared = PrePodClient()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct PodcastRef: Decodable, Identifiable, Hashable { let slug: String; let name: String; var id: String { slug } }
    struct EpisodeRef: Decodable, Identifiable, Hashable {
        let id: Int
        let episode_number: Int?
        let title: String?
        let status: String?
        var label: String { "\(episode_number.map { "Ep \($0) · " } ?? "")\(title ?? "Sin título")" }
    }
    struct Platform: Decodable, Hashable { let platform: String; let status: String; let external_url: String? }
    struct Link: Decodable, Hashable { let platform: String; let url: String }
    struct EpisodeStatus: Decodable, Hashable {
        let title: String?; let number: Int?; let status: String?; let media_url: String?; let links: [Link]
    }
    struct YouTubeStatus: Decodable, Hashable { let connected: Bool; let channel_name: String }
    struct PublishStatus: Decodable, Hashable {
        let feed_url: String?
        let hosting_configured: Bool
        let distribution: [Platform]
        let youtube: YouTubeStatus
        let episode: EpisodeStatus?
    }

    // MARK: Settings

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "prepodURL") ?? "https://prepod.castmedia.space" }
        set { UserDefaults.standard.set(newValue, forKey: "prepodURL") }
    }
    static var username: String {
        get { UserDefaults.standard.string(forKey: "prepodUser") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "prepodUser") }
    }
    static var isConfigured: Bool { !username.isEmpty && Keychain.get("prepod-password") != nil }

    // Session cookie handled by hand: prePod sets it for the parent domain (.castmedia.space)
    // and a private HTTPCookieStorage doesn't reliably keep it, so every request after login
    // arrived without session ("no autenticado").
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()
    private var cookies: [String: String] = [:]
    private var loggedIn = false

    // MARK: HTTP

    private func url(_ path: String) throws -> URL {
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let u = URL(string: base + path) else { throw Failure(message: "La URL de prePod no es válida") }
        return u
    }

    func send(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil,
                      contentType: String = "application/octet-stream", retry: Bool = true) async throws -> Data {
        if !loggedIn && path != "/api/auth/login" { try await login() }
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        if !cookies.isEmpty {
            req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        if let http, let headers = http.allHeaderFields as? [String: String], let u = http.url {
            for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: u) { cookies[c.name] = c.value }
        }
        let code = http?.statusCode ?? 0
        if code == 401, retry, path != "/api/auth/login" {
            loggedIn = false
            return try await send(method, path, json: json, body: body, contentType: contentType, retry: false)
        }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure(message: msg ?? "prePod respondió \(code)")
        }
        return data
    }

    /// Sube un archivo como formulario (multipart), igual que el navegador en prePod web.
    func upload(_ path: String, field: String, file: URL, fields: [String: String] = [:], method: String = "POST") async throws -> Data {
        let boundary = "thepod-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n")
        add("Content-Type: application/octet-stream\r\n\r\n")
        body.append(try Data(contentsOf: file))
        add("\r\n--\(boundary)--\r\n")
        return try await send(method, path, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    func login() async throws {
        guard let password = Keychain.get("prepod-password"), !Self.username.isEmpty else {
            throw Failure(message: "Configura tu usuario y contraseña de prePod en Ajustes.")
        }
        _ = try await send("POST", "/api/auth/login", json: ["username": Self.username, "password": password], retry: false)
        loggedIn = true
    }

    func resetSession() { loggedIn = false; cookies = [:]; adminCache = nil }

    private var adminCache: Bool?
    /// Si la cuenta es administradora (prePod `/api/auth/me`). Ante cualquier duda, no.
    /// El usuario de verdad de la cuenta (si se entró con el correo, devuelve el usuario).
    func canonicalUsername() async -> String? {
        guard let d = try? await send("GET", "/api/auth/me"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["username"] as? String
    }

    func isAdmin() async -> Bool {
        if let a = adminCache { return a }
        guard let d = try? await send("GET", "/api/auth/me"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        let a = (o["is_admin"] as? Bool) ?? false
        adminCache = a
        return a
    }

    /// Crea (o encuentra) la sala de grabación de prodPod para un episodio. Devuelve el número de sesión.
    func sendToProdPod(slug: String, episodeId: Int) async throws -> Int {
        let d = try await send("POST", "/api/podcasts/\(slug)/episodes/\(episodeId)/send-to-prodpod", json: [:])
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sid = (o["prodpod_session_id"] as? Int) ?? Int("\(o["prodpod_session_id"] ?? "")") else {
            throw Failure(message: "prodPod no devolvió la sala del episodio")
        }
        return sid
    }

    // MARK: Reads

    func podcasts() async throws -> [PodcastRef] {
        try JSONDecoder().decode([PodcastRef].self, from: await send("GET", "/api/podcasts"))
    }

    func episodes(slug: String) async throws -> [EpisodeRef] {
        try JSONDecoder().decode([EpisodeRef].self, from: await send("GET", "/api/podcasts/\(slug)/episodes"))
    }

    func status(slug: String, episodeId: Int) async throws -> PublishStatus {
        try JSONDecoder().decode(PublishStatus.self,
                                 from: await send("GET", "/api/mac/podcasts/\(slug)/publish-status?episode_id=\(episodeId)"))
    }

    // MARK: Upload + publish

    /// Chunked upload (8 MB parts). Returns the upload_id to publish with.
    func upload(file: URL, progress: @Sendable (Double) -> Void) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw Failure(message: "El archivo exportado está vacío") }
        let created = try await send("POST", "/api/mac/uploads", json: ["filename": file.lastPathComponent, "size": size])
        guard let id = (try JSONSerialization.jsonObject(with: created) as? [String: Any])?["upload_id"] as? String else {
            throw Failure(message: "prePod no devolvió upload_id")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunk = 8 * 1024 * 1024
        var index = 0
        var sent: Int64 = 0
        while let data = try handle.read(upToCount: chunk), !data.isEmpty {
            try Task.checkCancellation()
            var attempt = 0
            while true {
                do {
                    _ = try await send("PUT", "/api/mac/uploads/\(id)/chunk?index=\(index)", body: data)
                    break
                } catch {
                    attempt += 1
                    if attempt >= 3 { throw error }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            index += 1
            sent += Int64(data.count)
            progress(Double(sent) / Double(size))
        }
        _ = try await send("POST", "/api/mac/uploads/\(id)/finish")
        return id
    }

    func publishAudio(slug: String, episodeId: Int, uploadId: String) async throws -> String {
        try jobId(await send("POST", "/api/mac/publish/audio",
                             json: ["slug": slug, "episode_id": episodeId, "upload_id": uploadId]))
    }

    func publishYouTube(slug: String, episodeId: Int, uploadId: String, title: String,
                        description: String, privacy: String) async throws -> String {
        try jobId(await send("POST", "/api/mac/publish/youtube",
                             json: ["slug": slug, "episode_id": episodeId, "upload_id": uploadId,
                                    "title": String(title.prefix(100)), "description": String(description.prefix(5000)),
                                    "privacy": privacy]))
    }

    /// Polls a job until done. Returns the result dictionary.
    func wait(job: String, progress: @Sendable (Double) -> Void) async throws -> [String: String] {
        while true {
            try Task.checkCancellation()
            let obj = (try JSONSerialization.jsonObject(with: await send("GET", "/api/mac/jobs/\(job)")) as? [String: Any]) ?? [:]
            if let p = (obj["progress"] as? NSNumber)?.doubleValue { progress(p) }
            switch obj["status"] as? String {
            case "done":
                let r = obj["result"] as? [String: Any] ?? [:]
                return r.compactMapValues { v in (v as? String) ?? (v as? NSNumber)?.stringValue }
            case "error": throw Failure(message: obj["error"] as? String ?? "prePod no pudo publicar")
            default: try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func jobId(_ data: Data) throws -> String {
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["job_id"] as? String else {
            throw Failure(message: "prePod no devolvió job_id")
        }
        return id
    }
}


/// Lo que puede hacer la cuenta en la interfaz (por ahora: si es administradora).
@MainActor final class AccountRole: ObservableObject {
    static let shared = AccountRole()
    @Published private(set) var isAdmin = false
    func refresh() { Task { isAdmin = await PrePodClient.shared.isAdmin() } }
    func clear() { isAdmin = false }
}
