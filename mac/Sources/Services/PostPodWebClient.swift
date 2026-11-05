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
        var importing: Int? = nil          // pistas que todavía están llegando desde prodPod (nil = listo)
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

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Notas y momentos de un episodio de la Mac con la IA del servidor. Se hace una sola vez por episodio:
    /// si ya se hizo, el servidor devuelve lo mismo (sin volver a gastar). Espera hasta ~5 minutos.
    func aiMoments(ref: String, text: String, language: String = "es") async throws -> [String: Any] {
        let d = try await send("POST", "/api/ai/mac/analyze", json: ["ref": ref, "text": text, "language": language])
        var o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let path = "/api/ai/mac/" + (ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref)
        for _ in 0..<75 {
            switch o["status"] as? String {
            case "done":
                return (o["result"] as? [String: Any]) ?? [:]
            case "error":
                throw Failure(message: "La IA no pudo leer el episodio. Prueba de nuevo en un rato.")
            default:
                try await Task.sleep(nanoseconds: 4_000_000_000)
                let r = try await send("GET", path)
                o = (try? JSONSerialization.jsonObject(with: r) as? [String: Any]) ?? [:]
            }
        }
        throw Failure(message: "La IA está tardando más de lo normal. Vuelve a tocar el botón en unos minutos: no se cobra de nuevo.")
    }

    // MARK: Revisión compartida

    /// Sube una versión (MP3/M4A/MP4) y devuelve el enlace público.
    func uploadReview(slug: String, file: URL, title: String) async throws -> (token: String, url: String) {
        if !loggedIn { try await login() }
        let boundary = "thepod-\(UUID().uuidString)"
        var req = try request("POST", "/api/projects/\(slug)/review")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("title", title)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: file))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        req.timeoutInterval = 1800
        let (data, resp) = try await session.data(for: req)
        absorb(resp)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Failure(message: Self.errorMessage(data, code: code)) }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = j["token"] as? String, let url = j["url"] as? String else {
            throw Failure(message: "postPod no devolvió el enlace")
        }
        return (token, url)
    }

    func reviewComments(slug: String, token: String) async throws -> [ReviewComment] {
        let data = try await send("GET", "/api/projects/\(slug)/review/\(token)/comments")
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((j?["comments"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let id = c["id"] as? Int, let t = c["t"] as? Double, let text = c["text"] as? String else { return nil }
            return ReviewComment(id: id, t: t, author: c["author"] as? String ?? "", text: text, resolved: c["resolved"] as? Bool ?? false)
        }
    }

    func resolveReview(slug: String, token: String, id: Int, resolved: Bool) async throws {
        _ = try await send("POST", "/api/projects/\(slug)/review/\(token)/comments/\(id)/resolve", json: ["resolved": resolved])
    }

    func revokeReview(slug: String, token: String) async throws {
        _ = try await send("DELETE", "/api/projects/\(slug)/review/\(token)")
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
            // «Episodio en proceso»: prodPod todavía está mandando pistas. Una marca de más de 6 h es un envío cortado.
            var importing: Int?
            if let imp = m["importing"] as? [String: Any] {
                let started = (imp["started_at"] as? String).flatMap { iso.date(from: $0) ?? Self.isoFrac.date(from: $0) }
                if started.map({ Date().timeIntervalSince($0) < 6 * 3600 }) ?? true {
                    importing = (imp["expected"] as? Int) ?? 0
                }
            }
            return WebProject(slug: slug,
                              name: (m["name"] as? String) ?? slug,
                              createdAt: created,
                              owner: m["owner_username"] as? String,
                              podcastName: (source?["podcast_name"] as? String) ?? (source?["podcast_title"] as? String),
                              episodeNumber: number,
                              importing: importing)
        }
    }

    // MARK: Bundle: generate with progress + resumable download

    enum Phase: Sendable {
        case preparing(Double?)            // postPod armando el paquete (fracción si el servidor la da)
        case downloading(Int64, Int64)     // bytes recibidos, total
        case reconnecting                  // se cortó: reintentando desde donde quedó
    }

    struct BundleInfo {
        let state: String                  // idle | building | ready | error
        let progress: Double?
        let size: Int64
        let version: String                // cambia cuando el paquete se regenera
        let error: String?
    }

    private struct LegacyServer: Error {}

    /// Carpeta donde quedan las descargas a medias para poder reanudarlas.
    nonisolated static var partialFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("postPod/descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct PartialMeta: Codable { var version: String; var size: Int64; var etag: String? }

    nonisolated private static func partURL(_ slug: String) -> URL { partialFolder.appendingPathComponent("\(slug).part") }
    nonisolated private static func metaURL(_ slug: String) -> URL { partialFolder.appendingPathComponent("\(slug).json") }

    /// Si hay una descarga a medias de este proyecto: (bytes que ya están, total).
    nonisolated static func partial(slug: String) -> (got: Int64, total: Int64)? {
        guard let data = try? Data(contentsOf: metaURL(slug)),
              let meta = try? JSONDecoder().decode(PartialMeta.self, from: data),
              let got = (try? FileManager.default.attributesOfItem(atPath: partURL(slug).path)[.size] as? NSNumber)?.int64Value,
              got > 0 else { return nil }
        return (got, meta.size)
    }

    nonisolated static func discardPartial(slug: String) {
        try? FileManager.default.removeItem(at: partURL(slug))
        try? FileManager.default.removeItem(at: metaURL(slug))
    }

    private func bundlePath(_ slug: String) -> String {
        "/api/projects/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)"
    }

    private func bundleCall(_ method: String, _ slug: String) async throws -> BundleInfo {
        if !loggedIn { try await login() }
        for attempt in 0..<2 {
            let (data, resp) = try await session.data(for: try request(method, bundlePath(slug) + "/bundle"))
            absorb(resp)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, attempt == 0 { loggedIn = false; try await login(); continue }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let obj, let state = obj["state"] as? String {
                return BundleInfo(state: state,
                                  progress: (obj["progress"] as? NSNumber)?.doubleValue,
                                  size: (obj["size"] as? NSNumber)?.int64Value ?? 0,
                                  version: (obj["version"] as? String) ?? "",
                                  error: obj["error"] as? String)
            }
            if (code == 404 || code == 405), obj?["error"] == nil { throw LegacyServer() }   // postPod sin la API nueva
            throw Failure(message: Self.errorMessage(data, code: code))
        }
        throw Failure(message: "postPod no aceptó la sesión")
    }

    /// Pide a postPod el paquete del proyecto, informa cuánto lleva armado, y lo descarga
    /// pudiendo reanudar (tras un corte de red o si la app se cerró). Devuelve un .zip que el llamador borra.
    func downloadBundle(slug: String, progress: @escaping @Sendable (Phase) -> Void) async throws -> URL {
        var info: BundleInfo
        do {
            info = try await bundleCall("POST", slug)
        } catch is LegacyServer {
            return try await legacyDownload(slug: slug, progress: progress)
        }
        while info.state != "ready" {
            if info.state == "error" { throw Failure(message: info.error ?? "postPod no pudo preparar el paquete") }
            progress(.preparing(info.progress))
            try await Task.sleep(nanoseconds: 1_000_000_000)
            info = try await bundleCall("GET", slug)
        }

        let part = Self.partURL(slug), metaURL = Self.metaURL(slug)
        var meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(PartialMeta.self, from: $0) }
        if meta?.version != info.version || meta?.size != info.size {      // el paquete cambió: empezar de cero
            Self.discardPartial(slug: slug)
            meta = PartialMeta(version: info.version, size: info.size, etag: nil)
        }
        try JSONEncoder().encode(meta!).write(to: metaURL)

        var failures = 0
        while true {
            let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
            if info.size > 0, have >= info.size { break }
            var req = try request("GET", bundlePath(slug) + "/bundle/download")
            if have > 0 {
                req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
                if let etag = meta?.etag { req.setValue(etag, forHTTPHeaderField: "If-Range") }
            }
            do {
                let result = try await StreamingDownload.run(request: req, config: session.configuration, file: part,
                                                             offset: have, expected: info.size) { got, total in
                    progress(.downloading(got, total))
                }
                absorb(result.response)
                if result.status == 401 { loggedIn = false; try await login(); continue }
                guard result.status == 200 || result.status == 206 else {
                    throw Failure(message: Self.errorMessage(result.errorBody, code: result.status))
                }
                if let etag = result.response.value(forHTTPHeaderField: "ETag"), meta?.etag != etag {
                    meta?.etag = etag
                    try? JSONEncoder().encode(meta!).write(to: metaURL)
                }
                if info.size <= 0 { break }                                  // sin tamaño conocido: terminó el cuerpo
            } catch let e as URLError where e.code != .cancelled && failures < 20 {
                failures += 1
                progress(.reconnecting)
                try await Task.sleep(nanoseconds: UInt64(min(30, 2 * failures)) * 1_000_000_000)
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postpod-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(slug)_bundle.zip")
        try FileManager.default.moveItem(at: part, to: dest)
        try? FileManager.default.removeItem(at: metaURL)
        return dest
    }

    /// postPod sin la API nueva: una sola petición que arma y envía (sin % ni reanudar).
    private func legacyDownload(slug: String, progress: @escaping @Sendable (Phase) -> Void) async throws -> URL {
        let path = bundlePath(slug) + "/export-bundle"
        for attempt in 0..<2 {
            progress(.preparing(nil))
            let delegate = DownloadProgress { _, got, total in
                progress(got == 0 ? .preparing(nil) : .downloading(got, total))
            }
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

/// Descarga que escribe directo al archivo parcial: continúa con Range (206) o empieza de cero (200).
private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let status: Int; let response: HTTPURLResponse; let errorBody: Data }

    private let file: URL
    private let offset: Int64
    private let expected: Int64
    private let report: @Sendable (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var status = 0
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var last = Date.distantPast
    private var continuation: CheckedContinuation<Result, Error>?

    private init(file: URL, offset: Int64, expected: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.file = file; self.offset = offset; self.expected = expected; self.report = report
    }

    static func run(request: URLRequest, config: URLSessionConfiguration, file: URL, offset: Int64, expected: Int64,
                    report: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Result {
        let d = StreamingDownload(file: file, offset: offset, expected: expected, report: report)
        let s = URLSession(configuration: config, delegate: d, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        let task = s.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                d.continuation = cont
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        self.response = http
        status = http?.statusCode ?? 0
        let fm = FileManager.default
        if status == 206 {
            if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
            written = offset
            total = expected > 0 ? expected : offset + max(0, response.expectedContentLength)
        } else if status == 200 {
            fm.createFile(atPath: file.path, contents: nil)                  // respuesta completa: desde cero
            handle = try? FileHandle(forWritingTo: file)
            written = 0
            total = response.expectedContentLength > 0 ? response.expectedContentLength : expected
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { errorBody.append(data); return }
        try? handle.write(contentsOf: data)
        written += Int64(data.count)
        if Date().timeIntervalSince(last) > 0.25 {
            last = Date()
            report(written, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            report(written, total)
            continuation?.resume(returning: Result(status: status, response: response, errorBody: errorBody))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
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
