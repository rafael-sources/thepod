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

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: String(localized: "CFBundleShortVersionString")) as? String ?? "0" }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: String(localized: "CFBundleVersion")) as? String ?? "0" }

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
            throw PrePodClient.Failure(message: String(localized: "La dirección de thePod no es válida"))
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
            throw PrePodClient.Failure(message: String(localized: "Configura tu cuenta en Ajustes para buscar actualizaciones."))
        }
        let (_, resp) = try await session.data(for: try request("POST", "/api/login", json: ["username": PrePodClient.username, "password": pw]))
        absorb(resp)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw PrePodClient.Failure(message: String(localized: "thePod no aceptó tu usuario o contraseña"))
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
                        state = .failed(code == 404 ? String(localized: "El servidor de thePod todavía no tiene publicada la versión para Mac.")
                                                    : String(localized: "thePod respondió \(code)"))
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
        // Descarga con una sesión propia y su delegado: con la descarga «async» de URLSession el avance no
        // llegaba y la barra saltaba de 0 a 100. Si el servidor no dice el tamaño, se usa el de la ficha.
        let progress = UpdateProgress(expected: rel.size ?? 0) { [weak self] f in Task { @MainActor in self?.state = .downloading(f) } }
        let (tmp, resp) = try await progress.run(req, configuration: session.configuration)
        absorb(resp)
        let file = tmp
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw PrePodClient.Failure(message: String(localized: "No se pudo bajar la actualización"))
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("thePod-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: file, to: dest)
        // Comprobar que llegó entera (se lee por partes, sin cargar todo en memoria)
        if let expected = rel.sha256, !expected.isEmpty {
            let h = try FileHandle(forReadingFrom: dest)
            defer { try? h.close() }
            var hasher = SHA256()
            while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.lowercased() else {
                try? FileManager.default.removeItem(at: dest)
                throw PrePodClient.Failure(message: String(localized: "La actualización llegó incompleta. Intenta de nuevo."))
            }
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
                throw PrePodClient.Failure(message: String(localized: "El instalador no trae thePod.app"))
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
        guard p.terminationStatus == 0 else { throw PrePodClient.Failure(message: String(localized: "\(tool) falló: \(text)")) }
        return text
    }

    /// Cierra thePod, reemplaza la app instalada por la nueva y la vuelve a abrir.
    func restartAndInstall() {
        guard let newApp = stagedApp else { return }
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        // Nunca borra la app instalada antes de tener la nueva copiada y completa al lado.
        // Si algo falla, deja la que había y la vuelve a abrir. Todo queda en ~/Library/Logs/thePod-actualizacion.log
        let t = target.path, n = target.path + ".nueva", o = target.path + ".anterior"
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/thePod-actualizacion.log").path
        let script = """
        exec >>'\(log)' 2>&1
        echo String(localized: "== $(date) actualizando")
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf '\(n)' '\(o)'
        if /usr/bin/ditto '\(newApp.path)' '\(n)' && [ -x '\(n)/Contents/MacOS/thePod' ]; then
          /usr/bin/xattr -dr com.apple.quarantine '\(n)' 2>/dev/null
          if mv '\(t)' '\(o)' && mv '\(n)' '\(t)'; then
            rm -rf '\(o)'; echo "ok"
          else
            echo String(localized: "no se pudo reemplazar; se deja la anterior")
            [ -d '\(t)' ] || mv '\(o)' '\(t)'
            rm -rf '\(n)'
          fi
        else
          echo String(localized: "no se pudo copiar la nueva; se deja la anterior")
          rm -rf '\(n)'
        fi
        rm -rf '\(newApp.deletingLastPathComponent().path)'
        /usr/bin/open '\(t)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", String(localized: "nohup /bin/sh -c \"$0\" >/dev/null 2>&1 &"), script]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }
}

private final class UpdateProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double?) -> Void
    let expected: Int64
    private var last = Date.distantPast
    private var file: URL?
    private var cont: CheckedContinuation<(URL, URLResponse), Error>?

    init(expected: Int64, _ report: @escaping @Sendable (Double?) -> Void) {
        self.expected = expected
        self.report = report
    }

    /// Baja `req` y devuelve el archivo (ya movido a un lugar propio) y la respuesta.
    func run(_ req: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        let s = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            cont = c
            s.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(last) > 0.15 else { return }
        last = Date()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        report(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("thePod-dl-\(UUID().uuidString).part")
        if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { file = dest }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { cont = nil }
        if let error { cont?.resume(throwing: error); return }
        guard let file, let resp = task.response else {
            cont?.resume(throwing: PrePodClient.Failure(message: String(localized: "No se pudo bajar la actualización")))
            return
        }
        report(1)
        cont?.resume(returning: (file, resp))
    }
}
