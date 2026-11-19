import Foundation
import Security

/// Finds the best moments for Reels/TikTok/Shorts by analyzing the transcript on the Mac.
enum ClipSuggester {
    struct Suggestion { var title: String; var reason: String; var start: Double; var end: Double }

    static func suggest(project: Project, count: Int = 6) -> [Suggestion] {
        heuristic(project: project, count: count)
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

}

enum Keychain {

    /// One-time move of settings saved under the app's previous identifier.
    /// One time only: brings over settings saved with the app's previous identifiers
    /// (postPod → thePod). The account and the projects live in folders that don't change.
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

    // Without an Apple Developer account the app is signed "ad hoc" and its signature changes with every version.
    // The macOS keychain ties each item to the exact signature of the app that saved it (partition list),
    // so with every new version it asked for the Mac's password again, even if "Always Allow" was chosen.
    // That's why the account is saved in postPod's own file, readable only by your user (0600),
    // in ~/Library/Application Support/postPod/cuenta.dat. It's not strong encryption: access to your user protects it.
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
