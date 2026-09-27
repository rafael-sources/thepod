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

    private func send(_ method: String, _ path: String, json: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        if !loggedIn && path != "/api/auth/login" { try await login() }
        let base = Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw PrePodClient.Failure(message: "La dirección de prodPod no es válida") }
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
            throw PrePodClient.Failure(message: msg ?? "prodPod respondió \(code)")
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

    func invite(_ id: Int, name: String = "Invitado") async throws -> Invite {
        try JSONDecoder().decode(Invite.self, from: await send("POST", "/api/sessions/\(id)/invite", json: ["display_name": name]))
    }
}
