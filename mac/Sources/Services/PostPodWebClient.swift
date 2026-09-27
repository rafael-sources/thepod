import Foundation

/// Lists the projects the user can see in postPod web and downloads their bundle
/// (GET /api/projects/<slug>/export-bundle). Same account as prePod (shared users + cookie).
actor PostPodWebClient {
    static let shared = PostPodWebClient()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct WebProject: Identifiable, Hashable {
        let slug: String
        let name: String
        let createdAt: Date?
        let owner: String?
        let podcastName: String?
        let episodeNumber: Int?
        var id: String { slug }
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "postpodURL") ?? "https://postpod.castmedia.space" }
        set { UserDefaults.standard.set(newValue, forKey: "postpodURL") }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        // The server zips the whole project before sending the first byte: allow a long wait.
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c)
    }()
    private var cookies: [String: String] = [:]
    private var loggedIn = false

    func resetSession() { loggedIn = false; cookies = [:] }

    private func url(_ path: String) throws -> URL {
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let u = URL(string: base + path) else { throw Failure(message: "La dirección de postPod no es válida") }
        return u
    }

    private func request(_ method: String, _ path: String, json: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if !cookies.isEmpty {
            req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func absorb(_ resp: URLResponse) {
        guard let http = resp as? HTTPURLResponse, let u = http.url,
              let headers = http.allHeaderFields as? [String: String] else { return }
        for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: u) { cookies[c.name] = c.value }
    }

    private static func errorMessage(_ data: Data, code: Int) -> String {
        let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        return msg ?? "postPod respondió \(code)"
    }

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        if !loggedIn && path != "/api/auth/login" { try await login() }
        let (data, resp) = try await session.data(for: try request(method, path, json: json))
        absorb(resp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry, path != "/api/auth/login" {
            loggedIn = false
            return try await send(method, path, json: json, retry: false)
        }
        guard (200..<300).contains(code) else { throw Failure(message: Self.errorMessage(data, code: code)) }
        return data
    }

    func login() async throws {
        guard let password = Keychain.get("prepod-password"), !PrePodClient.username.isEmpty else {
            throw Failure(message: "Configura tu usuario y contraseña en Ajustes.")
        }
        _ = try await send("POST", "/api/auth/login", json: ["username": PrePodClient.username, "password": password], retry: false)
        loggedIn = true
    }

    func projects() async throws -> [WebProject] {
        let data = try await send("GET", "/api/projects")
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure(message: "postPod devolvió una lista inesperada")
        }
        let iso = ISO8601DateFormatter()
        return arr.compactMap { m in
            guard let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { return nil }
            let source = m["source"] as? [String: Any]
            let created = (m["created_at"] as? String).flatMap { iso.date(from: $0) }
            let number = (source?["episode_number"] as? Int) ?? (source?["episode_number"] as? String).flatMap(Int.init)
            return WebProject(slug: slug,
                              name: (m["name"] as? String) ?? slug,
                              createdAt: created,
                              owner: m["owner_username"] as? String,
                              podcastName: (source?["podcast_name"] as? String) ?? (source?["podcast_title"] as? String),
                              episodeNumber: number)
        }
    }

    /// Asks postPod to build the bundle and downloads it. `progress(nil)` while the server is
    /// zipping (no bytes yet), then the received fraction. Returns a local .zip the caller owns.
    func downloadBundle(slug: String, progress: @escaping @Sendable (Double?, Int64, Int64) -> Void) async throws -> URL {
        if !loggedIn { try await login() }
        let path = "/api/projects/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)/export-bundle"
        for attempt in 0..<2 {
            progress(nil, 0, 0)
            let delegate = DownloadProgress(progress)
            let (returned, resp) = try await session.download(for: try request("GET", path), delegate: delegate)
            let tmp = FileManager.default.fileExists(atPath: returned.path) ? returned : (delegate.saved ?? returned)
            absorb(resp)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, attempt == 0 {
                try? FileManager.default.removeItem(at: tmp)
                loggedIn = false
                try await login()
                continue
            }
            guard (200..<300).contains(code) else {
                let body = (try? Data(contentsOf: tmp)) ?? Data()
                try? FileManager.default.removeItem(at: tmp)
                throw Failure(message: Self.errorMessage(body, code: code))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postpod-dl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(slug)_bundle.zip")
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        }
        throw Failure(message: "postPod no aceptó la sesión")
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double?, Int64, Int64) -> Void
    private var last = Date.distantPast
    init(_ report: @escaping @Sendable (Double?, Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(last) > 0.25 else { return }
        last = Date()
        let f = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        report(f, totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Keep our own copy in case the system removes `location` once this callback returns.
    var saved: URL?
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("postpod-dl-\(UUID().uuidString).part")
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { saved = dest }
    }
}
