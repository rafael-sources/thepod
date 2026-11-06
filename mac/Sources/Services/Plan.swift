import Foundation

/// The account's plan (Free or Full), as the server says.
/// Saved on the Mac so it can also be applied offline.
/// Free: 2 episodes in total, recordings up to 15 minutes and video up to 720p.
enum Plan {
    private static var d: UserDefaults { .standard }

    /// "gratis", "completo" or "" (no account connected or not known yet).
    static var id: String { d.string(forKey: "planId") ?? "" }
    static var name: String { d.string(forKey: "planName") ?? "" }
    static var isFree: Bool { id == "gratis" }
    /// The Mac app comes with the Mac and Full plans. With Free or Web, the Free limits apply on the Mac.
    static var includesApp: Bool { id.isEmpty || d.bool(forKey: "planMac") }
    /// Video cap on the Mac: the plan's, or 720p if the plan doesn't include the app.
    static var maxHeight: Int? { includesApp ? positive("planMaxHeight") : 720 }
    static var maxRecordSeconds: Int? { positive("planMaxRecordSeconds") }
    static var maxEpisodes: Int? { positive("planMaxEpisodes") }
    static var episodesUsed: Int { d.integer(forKey: "planEpisodesUsed") }
    static var episodesLeft: Int? { maxEpisodes.map { max(0, $0 - episodesUsed) } }

    private static func positive(_ key: String) -> Int? {
        let v = d.integer(forKey: key)
        return v > 0 ? v : nil
    }

    /// Saves what the server sent (`plan` from /api/auth/me).
    static func update(_ o: [String: Any]?) {
        guard let o else { return }
        d.set(o["plan"] as? String ?? "", forKey: "planId")
        d.set(o["name"] as? String ?? "", forKey: "planName")
        d.set(o["max_height"] as? Int ?? 0, forKey: "planMaxHeight")
        d.set(o["max_record_seconds"] as? Int ?? 0, forKey: "planMaxRecordSeconds")
        d.set(o["max_episodes"] as? Int ?? 0, forKey: "planMaxEpisodes")
        d.set(o["episodes_used"] as? Int ?? 0, forKey: "planEpisodesUsed")
        d.set(o["mac"] as? Bool ?? true, forKey: "planMac")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        for k in ["planId", "planName", "planMaxHeight", "planMaxRecordSeconds", "planMaxEpisodes", "planEpisodesUsed", "planMac"] {
            d.removeObject(forKey: k)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("thePodPlanChanged")

    /// «Plan Gratis · 1 de 2 episodios · hasta 720p» / «Plan Completo» / nil without account.
    static var summary: String? {
        if isFree, let max = maxEpisodes {
            return String(localized: "Plan \(name) · \(episodesUsed) de \(max) episodios · grabaciones de hasta \((maxRecordSeconds ?? 900) / 60) min · video hasta \(maxHeight ?? 720)p")
        }
        if !name.isEmpty, !includesApp {
            return String(localized: "Plan \(name) · no incluye la app: aquí tienes 2 episodios de prueba en 720p")
        }
        return name.isEmpty ? nil : String(localized: "Plan \(name)")
    }

    /// Message when no episodes are left.
    static var noEpisodesMessage: String {
        String(localized: "El plan \(name.isEmpty ? "Gratis" : name) incluye \(maxEpisodes ?? 2) episodios y ya los usaste. Mejora tu plan para seguir.")
    }
}
