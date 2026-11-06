import Foundation
import Security

/// Finds the best moments for Reels/TikTok/Shorts.
/// With a Claude API key → asks Claude (same idea as postPod web's ai_engine). Without one → local heuristic.
enum ClipSuggester {
    struct Suggestion { var title: String; var reason: String; var start: Double; var end: Double }

    static func suggest(project: Project, count: Int = 6) async throws -> (clips: [Suggestion], usedAI: Bool, summary: String?) {
        if let key = Keychain.apiKey, !key.isEmpty {
            let result = try await askClaude(project: project, key: key)
            let snapped = result.clips.map { snap($0, words: project.words, duration: project.duration) }
            return (snapped, true, result.summary)
        }
        return (heuristic(project: project, count: count), false, nil)
    }

    // MARK: Claude

    static var model: String { UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-sonnet-5" }

    private static let systemPrompt = """
    Eres un editor experto en contenido de podcasts para redes sociales (Reels, TikTok, Shorts).
    Recibes la transcripción de un episodio con marcas de tiempo [MM:SS] y el nombre de quien habla.
    Elige los fragmentos con más potencial viral: una idea completa, un gancho fuerte al inicio,
    humor, una opinión polémica, una anécdota o un consejo útil. Cada clip debe entenderse solo,
    sin contexto previo, y durar entre 25 y 75 segundos.

    Devuelve ÚNICAMENTE este JSON:
    {
      "summary": "<resumen del episodio en 2 frases>",
      "clips": [
        {"start": "MM:SS", "end": "MM:SS", "title": "<título corto y llamativo, máx 8 palabras>",
         "reason": "<por qué funciona en redes, 1 frase>"}
      ]
    }
    Entre 3 y 8 clips, ordenados del mejor al peor. Sin texto fuera del JSON.
    """

    private static func askClaude(project: Project, key: String) async throws -> (clips: [Suggestion], summary: String?) {
        var transcript = EditEngine.transcriptForAI(project)
        if transcript.count > 180_000 { transcript = String(transcript.prefix(180_000)) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "system": systemPrompt,
            "messages": [["role": "user", "content": String(localized: "Episodio: \(project.name)\nIdioma: \(project.language)\n\nTranscripción:\n\(transcript)")]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw msg(String(localized: "Sin respuesta de Claude")) }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(localized: "HTTP \(http.statusCode)")
            throw msg(String(localized: "Claude respondió con un error: \(detail)"))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw msg(String(localized: "Respuesta de Claude inesperada")) }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw msg(String(localized: "Claude no devolvió un JSON válido"))
        }
        let clips = (json["clips"] as? [[String: Any]] ?? []).compactMap { c -> Suggestion? in
            guard let s = (c["start"] as? String).flatMap(parseClock), let e = (c["end"] as? String).flatMap(parseClock), e > s + 5 else { return nil }
            return Suggestion(title: c["title"] as? String ?? String(localized: "Clip"), reason: c["reason"] as? String ?? "", start: s, end: e)
        }
        return (clips, json["summary"] as? String)
    }

    static func parseClock(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    // MARK: Heuristic

    /// Sentence-aligned windows of 30–60 s scored by speech density, questions/exclamations and back-and-forth.
    static func heuristic(project: Project, count: Int) -> [Suggestion] {
        let words = project.words.sorted { $0.s < $1.s }
        guard words.count > 30 else { return [] }
        var starts: [Int] = [0]
        for i in 1..<words.count {
            let prev = words[i - 1]
            if words[i].s - prev.e > 0.6 || ".?!".contains(prev.w.last ?? " ") || prev.lane != words[i].lane { starts.append(i) }
        }
        struct Cand { var a: Int; var b: Int; var score: Double }
        var cands: [Cand] = []
        for si in starts {
            let t0 = words[si].s
            var j = si
            while j + 1 < words.count, words[j + 1].e - t0 < 60 { j += 1 }
            // end on a sentence boundary if possible
            var end = j
            while end > si, words[end].e - t0 > 30, !(".?!".contains(words[end].w.last ?? " ")) { end -= 1 }
            if words[end].e - t0 < 25 { end = j }
            let dur = words[end].e - t0
            guard dur >= 20 else { continue }
            let slice = words[si...end]
            let density = Double(slice.count) / dur
            let punch = Double(slice.filter { "?!".contains($0.w.last ?? " ") }.count)
            var changes = 0
            for k in slice.indices.dropFirst() where words[k].lane != words[k - 1].lane { changes += 1 }
            let hookBonus = words[si].w.first?.isUppercase == true ? 0.2 : 0
            let score = density * (1 + 0.08 * punch) * (1 + 0.05 * Double(min(changes, 6))) + hookBonus
            cands.append(Cand(a: si, b: end, score: score))
        }
        cands.sort { $0.score > $1.score }
        var chosen: [Cand] = []
        for c in cands where chosen.count < count {
            let s = words[c.a].s, e = words[c.b].e
            if chosen.contains(where: { !(e < words[$0.a].s - 5 || s > words[$0.b].e + 5) }) { continue }
            chosen.append(c)
        }
        return chosen.enumerated().map { (i, c) in
            let firstWords = words[c.a...min(c.b, c.a + 7)].map(\.w).joined(separator: " ")
            let s = snap(Suggestion(title: firstWords.prefix(1).uppercased() + firstWords.dropFirst() + "…",
                                    reason: String(localized: "Momento \(i + 1): mucha conversación y ritmo alto"),
                                    start: words[c.a].s, end: words[c.b].e),
                         words: words, duration: project.duration)
            return s
        }.sorted { $0.start < $1.start }
    }

    /// Nudge boundaries so a clip never starts or ends mid-word.
    static func snap(_ s: Suggestion, words: [Word], duration: Double) -> Suggestion {
        var out = s
        if let w = words.last(where: { $0.s <= s.start + 0.3 }) { out.start = max(0, min(s.start, w.s) - 0.15) }
        if let w = words.first(where: { $0.e >= s.end - 0.3 }) { out.end = min(duration, max(s.end, w.e) + 0.35) }
        return out
    }

    private static func msg(_ s: String) -> NSError { NSError(domain: "claude", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

enum Keychain {

    /// One-time move of settings saved under the app's previous identifier.
    /// Una sola vez: trae los ajustes guardados con los identificadores anteriores de la app
    /// (postPod → thePod). La cuenta y los proyectos viven en carpetas que no cambian.
    static func migrateLegacy() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migradoAThePod") else { return }
        for legacy in ["space.aitism" + ".postpod", "com.example" + ".postpodapp"] {
            guard let old = d.persistentDomain(forName: legacy) else { continue }
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            d.removePersistentDomain(forName: legacy)
        }
        d.set(true, forKey: "migradoAThePod")
    }

    static var apiKey: String? {
        get { get("anthropic-api-key") }
        set { set(newValue, for: "anthropic-api-key") }
    }

    // Sin cuenta de Apple Developer la app va firmada "ad hoc" y su firma cambia en cada versión.
    // El llavero de macOS ata cada dato a la firma exacta de la app que lo guardó (partition list),
    // así que con cada versión nueva volvía a pedir la clave de la Mac, aunque se eligiera "Permitir siempre".
    // Por eso la cuenta se guarda en un archivo propio de postPod, legible solo por tu usuario (0600),
    // en ~/Library/Application Support/postPod/cuenta.dat. No es cifrado fuerte: lo protege el acceso a tu usuario.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    private static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("postPod", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("cuenta.dat")
    }

    private static let mask = Array("postPod·thePod·aitism".utf8)
    private static func scramble(_ d: Data) -> Data {
        Data(d.enumerated().map { $0.element ^ mask[$0.offset % mask.count] })
    }

    private static func loadAll() -> [String: String] {
        if let cache { return cache }
        var dict: [String: String] = [:]
        if let raw = try? Data(contentsOf: storeURL),
           let obj = try? JSONSerialization.jsonObject(with: scramble(raw)) as? [String: String] {
            dict = obj
        }
        cache = dict
        return dict
    }

    private static func saveAll(_ dict: [String: String]) {
        cache = dict
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let url = storeURL
        try? scramble(data).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadAll()[account]
    }

    static func set(_ value: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = loadAll()
        if let value, !value.isEmpty { dict[account] = value } else { dict.removeValue(forKey: account) }
        saveAll(dict)
    }
}
