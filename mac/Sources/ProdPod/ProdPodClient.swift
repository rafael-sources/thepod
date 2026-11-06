import Foundation

/// prodPod web: sesiones de grabación, invitaciones y el permiso para entrar a la sala.
/// Misma cuenta que prePod y postPod (usuario y contraseña de Ajustes).
actor ProdPodClient {
    static let shared = ProdPodClient()

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "prodpodURL") ?? "https://prodpod.castmedia.space" }
        set { UserDefaults.standard.set(newValue, forKey: "prodpodURL") }
    }

    struct Session: Decodable, Identifiable, Hashable {
        let id: Int
        let title: String
        var status: String?
        var created_by: String?
        var live_participants: [String]?
        var description: String?
        var source_slug: String?
        var source_episode_id: Int?
        var created_at: String?
        var finished_at: String?
        var shared_project_id: String?
        var limits: Limits?
    }

    /// Plan de quien creó la sala: cuánto puede durar la grabación y la resolución máxima (nil = sin límite).
    struct Limits: Decodable, Hashable {
        var plan: String?
        var plan_name: String?
        var max_record_seconds: Int?
        var max_height: Int?
        var episodes_left: Int?
    }

    struct Person: Decodable, Identifiable, Hashable {
        let id: Int
        var username: String?
        var display_name: String
        var role: String
        var status: String?
        var invite_url: String?
        var recording_quality: String?
        var roleTitle: String {
            ["host": String(localized: "Conductor"), "co-host": String(localized: "Conductor"), "guest": String(localized: "Invitado"), "director": String(localized: "Director")][role] ?? role
        }
    }

    struct JoinInfo: Decodable {
        let participant_id: Int
        let display_name: String
        let role: String
        let livekit_ws_url: String
        let livekit_token: String
        let room_name: String
    }

    struct Invite: Decodable { let id: Int; let invite_token: String; let invite_url: String }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()
    private var cookies: [String: String] = [:]
    private var loggedIn = false
    /// Olvida la sesión (al cerrar sesión o cambiar de cuenta).
    func resetSession() { loggedIn = false; cookies = [:]; }

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        if !loggedIn && path != "/api/auth/login" { try await login() }
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw PrePodClient.Failure(message: String(localized: "La dirección de prodPod no es válida")) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
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
            return try await send(method, path, json: json, retry: false)
        }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PrePodClient.Failure(message: msg ?? String(localized: "prodPod respondió \(code)"))
        }
        return data
    }

    func login() async throws {
        guard let pw = Keychain.get("prepod-password"), !PrePodClient.username.isEmpty else {
            throw PrePodClient.Failure(message: String(localized: "Conecta tu cuenta en Ajustes."))
        }
        _ = try await send("POST", "/api/auth/login", json: ["username": PrePodClient.username, "password": pw], retry: false)
        loggedIn = true
    }

    /// Formulario con un archivo (para la subida por partes). Devuelve el código y la respuesta.
    func multipart(_ path: String, fields: [String: String], fileField: String?, fileName: String, fileData: Data?,
                   retry: Bool = true) async throws -> (Int, [String: Any]) {
        if !loggedIn { try await login() }
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw PrePodClient.Failure(message: String(localized: "La dirección de prodPod no es válida")) }
        let boundary = "thepod-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields { add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n") }
        if let fileField, let fileData {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
            add("Content-Type: application/octet-stream\r\n\r\n")
            body.append(fileData)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !cookies.isEmpty { req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        let (data, resp) = try await session.upload(for: req, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            loggedIn = false
            return try await multipart(path, fields: fields, fileField: fileField, fileName: fileName, fileData: fileData, retry: false)
        }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (code, obj)
    }

    /// POST con JSON; devuelve la respuesta como diccionario.
    @discardableResult
    func postJSON(_ path: String, _ json: [String: Any] = [:]) async throws -> [String: Any] {
        let d = try await send("POST", path, json: json)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    func get(_ path: String) async throws -> Data { try await send("GET", path) }

    @discardableResult
    func send(method: String, path: String, json: [String: Any]? = nil) async throws -> Data {
        try await send(method, path, json: json)
    }

    /// Mide la subida: manda 2.5 MB que el servidor descarta. Devuelve Mbps.
    func uploadTest() async throws -> Double {
        if !loggedIn { try await login() }
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var req = URLRequest(url: URL(string: base + "/api/net-test")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !cookies.isEmpty { req.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        var blob = Data(count: 2_500_000)
        blob.withUnsafeMutableBytes { p in arc4random_buf(p.baseAddress!, p.count) }
        let t0 = Date()
        let (_, resp) = try await session.upload(for: req, from: blob)
        let secs = Date().timeIntervalSince(t0)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, secs > 0 else { throw PrePodClient.Failure(message: String(localized: "No se pudo medir la subida")) }
        return Double(blob.count * 8) / secs / 1_000_000
    }

    func sessions() async throws -> [Session] {
        try JSONDecoder().decode([Session].self, from: await send("GET", "/api/sessions"))
    }

    func createSession(title: String) async throws -> Session {
        try JSONDecoder().decode(Session.self, from: await send("POST", "/api/sessions", json: ["title": title]))
    }

    func deleteSession(_ id: Int) async throws { _ = try await send("DELETE", "/api/sessions/\(id)") }

    func join(_ id: Int) async throws -> JoinInfo {
        try JSONDecoder().decode(JoinInfo.self, from: await send("GET", "/api/sessions/\(id)/my-token"))
    }

    func leave(_ id: Int) async { _ = try? await send("POST", "/api/sessions/\(id)/leave") }

    // MARK: Director

    struct DirectorJoin: Decodable {
        let participant_id: Int
        let display_name: String
        let livekit_ws_url: String
        let livekit_token: String
    }

    func directorJoin(_ id: Int) async throws -> DirectorJoin {
        try JSONDecoder().decode(DirectorJoin.self, from: await send("GET", "/api/sessions/\(id)/director-token"))
    }

    /// Podcasts (shared_project_id) donde tu cuenta es director.
    func directorProjects() async throws -> Set<String> {
        let d = try await send("GET", "/api/director/my-podcasts")
        let list = (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
        return Set(list.compactMap { $0["shared_project_id"] as? String })
    }

    /// Sube una imagen para los cintillos; devuelve su file_path en el servidor.
    func uploadDirectorAsset(_ sid: Int, data: Data, name: String) async throws -> String {
        let (code, obj) = try await multipart("/api/sessions/\(sid)/director/assets", fields: [:], fileField: "file",
                                              fileName: name, fileData: data)
        guard (200..<300).contains(code), let fp = obj["file_path"] as? String else {
            throw PrePodClient.Failure(message: obj["error"] as? String ?? String(localized: "No se pudo subir la imagen (\(code))"))
        }
        return fp
    }

    func participants(_ id: Int) async throws -> [Person] {
        try JSONDecoder().decode([Person].self, from: await send("GET", "/api/sessions/\(id)/participants"))
    }

    func invite(_ id: Int, name: String = String(localized: "Invitado")) async throws -> Invite {
        try JSONDecoder().decode(Invite.self, from: await send("POST", "/api/sessions/\(id)/invite", json: ["display_name": name]))
    }
}
