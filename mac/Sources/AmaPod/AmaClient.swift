import Foundation

/// amaPod web: eventos de preguntas del público. Misma cuenta que el resto de thePod.
actor AmaClient {
    static let shared = AmaClient()

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "amapodURL") ?? "https://amapod.castmedia.space" }
        set { UserDefaults.standard.set(newValue, forKey: "amapodURL") }
    }

    struct Event: Decodable, Identifiable, Hashable {
        let id: Int
        var title: String
        var description: String?
        var status: String                 // created | active | finished
        var chat_mode: String?             // free | moderated | off
        var livekit_room_name: String?
        var recording_file: String?
        var egress_id: String?
        var like_count: Int?
        var spectator_count: Int?
        var prodpod_session_id: Int?
        var created_at: String?
        var started_at: String?
        var finished_at: String?
    }

    struct Template: Decodable, Identifiable, Hashable {
        let id: Int
        var title: String
        var description: String?
        var chat_mode: String?
    }

    struct Person: Decodable, Identifiable, Hashable {
        let id: Int
        var display_name: String
        var status: String                 // pending | in_queue | on_air | done | rejected | left
        var queue_position: Int?
        var is_preconnected: Int?
        var is_censored: Int?
        var questions: [String]?
        var requested_at: String?
        var turn_started_at: String?
        var censored: Bool { (is_censored ?? 0) != 0 }
        var preconnected: Bool { (is_preconnected ?? 0) != 0 }
    }

    struct Message: Decodable, Identifiable, Hashable {
        let id: Int
        var sender_name: String
        var is_host: Int?
        var message: String
        var is_approved: Int?
        var pending: Bool?              // espera que el anfitrión lo apruebe (chat moderado)
        var can_block: Bool?            // es del público: se le puede no dejar escribir más
        var created_at: String?
        var isPending: Bool { pending ?? ((is_approved ?? 1) == 0) }
    }

    struct PublicInfo: Decodable { var like_count: Int?; var spectator_count: Int?; var participant_count: Int? }
    struct Token: Decodable { let token: String; let room_name: String }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    private var cookies: [String: String] = [:]
    private var loggedIn = false
    /// Olvida la sesión (al cerrar sesión o cambiar de cuenta).
    func resetSession() { loggedIn = false; cookies = [:]; wsURL = nil; }
    private var wsURL: String?

    private func send(_ method: String, _ path: String, json: Any? = nil, retry: Bool = true) async throws -> Data {
        if !loggedIn && path != "/api/auth/login" { try await login() }
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw PrePodClient.Failure(message: "La dirección de amaPod no es válida") }
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
            throw PrePodClient.Failure(message: msg ?? "amaPod respondió \(code)")
        }
        return data
    }

    func login() async throws {
        guard let pw = Keychain.get("prepod-password"), !PrePodClient.username.isEmpty else {
            throw PrePodClient.Failure(message: "Conecta tu cuenta en Ajustes.")
        }
        _ = try await send("POST", "/api/auth/login", json: ["username": PrePodClient.username, "password": pw], retry: false)
        loggedIn = true
    }

    private func decode<T: Decodable>(_ t: T.Type, _ method: String, _ path: String, json: Any? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(method, path, json: json))
    }

    // MARK: Eventos

    func events() async throws -> [Event] { try await decode([Event].self, "GET", "/api/events") }
    func event(_ id: Int) async throws -> Event { try await decode(Event.self, "GET", "/api/events/\(id)") }
    func create(title: String, description: String, chatMode: String) async throws -> Event {
        try await decode(Event.self, "POST", "/api/events", json: ["title": title, "description": description, "chat_mode": chatMode])
    }
    func update(_ id: Int, title: String, description: String, chatMode: String) async throws -> Event {
        try await decode(Event.self, "PUT", "/api/events/\(id)", json: ["title": title, "description": description, "chat_mode": chatMode])
    }
    func delete(_ id: Int) async throws { _ = try await send("DELETE", "/api/events/\(id)") }
    func start(_ id: Int) async throws -> Event { try await decode(Event.self, "POST", "/api/events/\(id)/start") }
    func finish(_ id: Int) async throws -> Event { try await decode(Event.self, "POST", "/api/events/\(id)/finish") }
    func templates() async throws -> [Template] { try await decode([Template].self, "GET", "/api/events/templates") }
    func fromTemplate(_ tid: Int) async throws -> Event { try await decode(Event.self, "POST", "/api/events/from-template/\(tid)") }
    func saveAsTemplate(_ id: Int) async throws { _ = try await send("POST", "/api/events/\(id)/clone-template") }
    func publicInfo(_ id: Int) async throws -> PublicInfo { try await decode(PublicInfo.self, "GET", "/api/events/\(id)/public-info") }

    // MARK: Sala

    func hostToken(_ id: Int) async throws -> Token { try await decode(Token.self, "GET", "/api/events/\(id)/host-token") }
    func livekitURL() async throws -> String {
        if let wsURL { return wsURL }
        let obj = try JSONSerialization.jsonObject(with: await send("GET", "/api/config/livekit")) as? [String: Any]
        guard let u = obj?["ws_url"] as? String, !u.isEmpty else { throw PrePodClient.Failure(message: "amaPod no dijo dónde está la sala") }
        wsURL = u
        return u
    }

    // MARK: Cola

    func queue(_ id: Int) async throws -> [Person] { try await decode([Person].self, "GET", "/api/events/\(id)/queue") }
    func requests(_ id: Int) async throws -> [Person] { try await decode([Person].self, "GET", "/api/events/\(id)/requests") }
    func approve(_ id: Int, _ pid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/approve/\(pid)") }
    func reject(_ id: Int, _ pid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/reject/\(pid)") }
    /// Pasa al siguiente de la cola. Devuelve quién quedó al aire (nil si la cola estaba vacía).
    func next(_ id: Int) async throws -> Person? {
        let d = try await send("POST", "/api/events/\(id)/next")
        return try? JSONDecoder().decode(Person.self, from: d)
    }
    func skip(_ id: Int, to pid: Int) async throws -> Person { try await decode(Person.self, "POST", "/api/events/\(id)/skip/\(pid)") }
    func reorder(_ id: Int, _ order: [Int]) async throws { _ = try await send("PUT", "/api/events/\(id)/reorder", json: ["order": order]) }
    func censor(_ id: Int, _ pid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/censor/\(pid)") }
    func uncensor(_ id: Int, _ pid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/uncensor/\(pid)") }
    func remove(_ id: Int, _ pid: Int) async throws { _ = try await send("DELETE", "/api/events/\(id)/remove/\(pid)") }

    // MARK: Chat

    func chat(_ id: Int) async throws -> [Message] { try await decode([Message].self, "GET", "/api/events/\(id)/chat") }
    func say(_ id: Int, _ text: String) async throws -> Message {
        try await decode(Message.self, "POST", "/api/events/\(id)/chat", json: ["message": text])
    }
    func deleteMessage(_ id: Int, _ mid: Int) async throws { _ = try await send("DELETE", "/api/events/\(id)/chat/\(mid)") }
    func approveMessage(_ id: Int, _ mid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/chat/\(mid)/approve") }
    /// No deja escribir más a quien escribió ese mensaje y borra todo lo suyo.
    func blockSender(_ id: Int, _ mid: Int) async throws { _ = try await send("POST", "/api/events/\(id)/chat/\(mid)/block") }

    // MARK: Grabación (en el servidor)

    func startRecording(_ id: Int) async throws { _ = try await send("POST", "/api/events/\(id)/recording/start") }
    func stopRecording(_ id: Int) async throws { _ = try await send("POST", "/api/events/\(id)/recording/stop") }
    func recordingActive(_ id: Int) async -> Bool {
        guard let d = try? await send("GET", "/api/events/\(id)/recording/status"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (o["is_recording"] as? Bool) ?? (o["recording"] as? Bool) ?? ((o["egress_id"] as? String)?.isEmpty == false)
    }

    // MARK: Links públicos

    static func joinLink(_ id: Int) -> String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/join/\(id)" }
    static func watchLink(_ id: Int) -> String { baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/watch/\(id)" }
}
