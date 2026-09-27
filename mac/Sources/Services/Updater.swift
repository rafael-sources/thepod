import Foundation
import AppKit
import CryptoKit

/// Actualizaciones desde thePod: pregunta a thepod.castmedia.space qué versión está publicada,
/// baja el instalador, comprueba que llegó entero (sha256), y reemplaza la app al reiniciar.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Decodable, Equatable {
        let version: String
        let build: String
        let size: Int64?
        let sha256: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double?)
        case ready(Release)                 // descargada y lista: falta reiniciar
        case failed(String)
    }

    @Published var state: State = .idle

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "thepodURL") ?? "https://thepod.castmedia.space" }
        set { UserDefaults.standard.set(newValue, forKey: "thepodURL") }
    }
    static var checkOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "buscarActualizaciones") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "buscarActualizaciones") }
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    private var cookies: [String: String] = [:]
    private var stagedApp: URL?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    // MARK: HTTP (misma cuenta de thePod)

    private func request(_ method: String, _ path: String, json: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: Self.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + path) else {
            throw PrePodClient.Failure(message: "La dirección de thePod no es válida")
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if !cookies.isEmpty { r.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        return r
    }

    private func absorb(_ resp: URLResponse) {
        guard let http = resp as? HTTPURLResponse, let u = http.url,
              let headers = http.allHeaderFields as? [String: String] else { return }
        for c in HTTPCookie.cookies(withResponseHeaderFields: headers, for: u) { cookies[c.name] = c.value }
    }

    private func login() async throws {
        guard let pw = Keychain.get("prepod-password"), !PrePodClient.username.isEmpty else {
            throw PrePodClient.Failure(message: "Configura tu cuenta en Ajustes para buscar actualizaciones.")
        }
        let (_, resp) = try await session.data(for: try request("POST", "/api/login", json: ["username": PrePodClient.username, "password": pw]))
        absorb(resp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw PrePodClient.Failure(message: "thePod no aceptó tu usuario o contraseña")
        }
    }

    // MARK: Buscar

    /// `quiet`: al abrir la app no molesta si no hay nada nuevo o si falla la conexión.
    func check(quiet: Bool = false) {
        if case .downloading = state { return }
        if case .ready = state { return }
        state = .checking
        Task {
            do {
                try await login()
                let (data, resp) = try await session.data(for: try request("GET", "/api/descargas/thepod-mac"))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    // 404 = el servidor todavía no publica la app de Mac: no es lo mismo que "estás al día".
                    if quiet { state = .idle } else {
                        state = .failed(code == 404 ? "El servidor de thePod todavía no tiene publicada la versión para Mac."
                                                    : "thePod respondió \(code)")
                    }
                    return
                }
                let rel = try JSONDecoder().decode(Release.self, from: data)
                state = Self.isNewer(rel) ? .available(rel) : (quiet ? .idle : .upToDate)
            } catch {
                state = quiet ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    /// Compara primero la versión (1.2.10 > 1.2.9) y, si es igual, el número de compilación.
    static func isNewer(_ r: Release) -> Bool {
        let a = r.version.split(separator: ".").map { Int($0) ?? 0 }
        let b = currentVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return (Int(r.build) ?? 0) > (Int(currentBuild) ?? 0)
    }

    // MARK: Bajar e instalar

    func download(_ rel: Release) {
        state = .downloading(0)
        Task {
            do {
                let dmg = try await fetchDMG(rel)
                let app = try await Self.extractApp(from: dmg)
                try? FileManager.default.removeItem(at: dmg)
                stagedApp = app
                state = .ready(rel)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchDMG(_ rel: Release) async throws -> URL {
        var req = try request("GET", "/descargas/thepod-mac")
        req.timeoutInterval = 600
        let (bytes, resp) = try await session.bytes(for: req)
        absorb(resp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PrePodClient.Failure(message: "No se pudo bajar la actualización") }
        let total = rel.size ?? resp.expectedContentLength
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("thePod-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var got: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); hasher.update(data: buffer)
                got += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.3 {
                    lastReport = Date()
                    state = .downloading(total > 0 ? Double(got) / Double(total) : nil)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); hasher.update(data: buffer) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = rel.sha256, !expected.isEmpty, expected.lowercased() != digest {
            try? FileManager.default.removeItem(at: dest)
            throw PrePodClient.Failure(message: "La actualización llegó incompleta. Intenta de nuevo.")
        }
        return dest
    }

    /// Monta el .dmg sin mostrarlo, copia thePod.app a una carpeta temporal y lo desmonta.
    nonisolated static func extractApp(from dmg: URL) async throws -> URL {
        try await Task.detached {
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("thePod-mnt-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let src = mount.appendingPathComponent("thePod.app")
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw PrePodClient.Failure(message: "El instalador no trae thePod.app")
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("thePod-new-\(UUID().uuidString)/thePod.app")
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [src.path, dest.path])
            return dest
        }.value
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw PrePodClient.Failure(message: "\(tool) falló: \(text)") }
        return text
    }

    /// Cierra thePod, reemplaza la app instalada por la nueva y la vuelve a abrir.
    func restartAndInstall() {
        guard let newApp = stagedApp else { return }
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf '\(target.path)'
        /usr/bin/ditto '\(newApp.path)' '\(target.path)'
        /usr/bin/xattr -dr com.apple.quarantine '\(target.path)' 2>/dev/null
        rm -rf '\(newApp.deletingLastPathComponent().path)'
        /usr/bin/open '\(target.path)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh -c \"$0\" >/dev/null 2>&1 &", script]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }
}
