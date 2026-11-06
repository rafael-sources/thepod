import Foundation
import AppKit
import CryptoKit

/// Updates from thePod: asks thepod.castmedia.space which version is published,
/// downloads the installer, checks it arrived intact (sha256), and replaces the app on restart.
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
        case ready(Release)                 // downloaded and ready: restart pending
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

    // MARK: HTTP (same thePod account)

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

    // MARK: Check

    /// `quiet`: on app launch it doesn't bother if there's nothing new or the connection fails.
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
                    // 404 = the server doesn't publish the Mac app yet: not the same as "you're up to date".
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

    /// Compares the version first (1.2.10 > 1.2.9) and, if equal, the build number.
    static func isNewer(_ r: Release) -> Bool {
        let a = r.version.split(separator: ".").map { Int($0) ?? 0 }
        let b = currentVersion.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return (Int(r.build) ?? 0) > (Int(currentBuild) ?? 0)
    }

    // MARK: Download and install

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
        // Downloads with its own session and delegate: with URLSession's «async» download the progress didn't
        // arrive and the bar jumped from 0 to 100. If the server doesn't give the size, the manifest's is used.
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
        // Check it arrived intact (read in parts, without loading everything into memory)
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

    /// Mounts the .dmg without showing it, copies thePod.app to a temp folder and unmounts it.
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

    /// Quits thePod, replaces the installed app with the new one and reopens it.
    func restartAndInstall() {
        guard let newApp = stagedApp else { return }
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        // Never deletes the installed app before the new one is copied complete alongside.
        // If something fails, it keeps the old one and reopens it. Everything goes to ~/Library/Logs/thePod-actualizacion.log
        let t = target.path, n = target.path + ".nueva", o = target.path + ".anterior"
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/thePod-actualizacion.log").path
        let script = """
        exec >>'\(log)' 2>&1
        echo "== $(date) actualizando"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf '\(n)' '\(o)'
        if /usr/bin/ditto '\(newApp.path)' '\(n)' && [ -x '\(n)/Contents/MacOS/thePod' ]; then
          /usr/bin/xattr -dr com.apple.quarantine '\(n)' 2>/dev/null
          if mv '\(t)' '\(o)' && mv '\(n)' '\(t)'; then
            rm -rf '\(o)'; echo "ok"
          else
            echo "no se pudo reemplazar; se deja la anterior"
            [ -d '\(t)' ] || mv '\(o)' '\(t)'
            rm -rf '\(n)'
          fi
        else
          echo "no se pudo copiar la nueva; se deja la anterior"
          rm -rf '\(n)'
        fi
        rm -rf '\(newApp.deletingLastPathComponent().path)'
        /usr/bin/open '\(t)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh -c \"$0\" >/dev/null 2>&1 &", script]
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

    /// Downloads `req` and returns the file (already moved to its own place) and the response.
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
