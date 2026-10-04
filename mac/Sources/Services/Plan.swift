import Foundation

/// El plan de la cuenta (Gratis o Completo), tal como lo dice el servidor.
/// Se guarda en la Mac para poder aplicarlo también sin internet.
/// Gratis: 2 episodios en total, grabaciones de hasta 15 minutos y video hasta 720p.
enum Plan {
    private static var d: UserDefaults { .standard }

    /// "gratis", "completo" o "" (sin cuenta conectada o todavía no se sabe).
    static var id: String { d.string(forKey: "planId") ?? "" }
    static var name: String { d.string(forKey: "planName") ?? "" }
    static var isFree: Bool { id == "gratis" }
    static var maxHeight: Int? { positive("planMaxHeight") }
    static var maxRecordSeconds: Int? { positive("planMaxRecordSeconds") }
    static var maxEpisodes: Int? { positive("planMaxEpisodes") }
    static var episodesUsed: Int { d.integer(forKey: "planEpisodesUsed") }
    static var episodesLeft: Int? { maxEpisodes.map { max(0, $0 - episodesUsed) } }

    private static func positive(_ key: String) -> Int? {
        let v = d.integer(forKey: key)
        return v > 0 ? v : nil
    }

    /// Guarda lo que mandó el servidor (`plan` de /api/auth/me).
    static func update(_ o: [String: Any]?) {
        guard let o else { return }
        d.set(o["plan"] as? String ?? "", forKey: "planId")
        d.set(o["name"] as? String ?? "", forKey: "planName")
        d.set(o["max_height"] as? Int ?? 0, forKey: "planMaxHeight")
        d.set(o["max_record_seconds"] as? Int ?? 0, forKey: "planMaxRecordSeconds")
        d.set(o["max_episodes"] as? Int ?? 0, forKey: "planMaxEpisodes")
        d.set(o["episodes_used"] as? Int ?? 0, forKey: "planEpisodesUsed")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func clear() {
        for k in ["planId", "planName", "planMaxHeight", "planMaxRecordSeconds", "planMaxEpisodes", "planEpisodesUsed"] {
            d.removeObject(forKey: k)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("thePodPlanChanged")

    /// «Plan Gratis · 1 de 2 episodios · hasta 720p» / «Plan Completo» / nil sin cuenta.
    static var summary: String? {
        if isFree, let max = maxEpisodes {
            return "Plan \(name) · \(episodesUsed) de \(max) episodios · grabaciones de hasta \((maxRecordSeconds ?? 900) / 60) min · video hasta \(maxHeight ?? 720)p"
        }
        return name.isEmpty ? nil : "Plan \(name)"
    }

    /// Mensaje cuando ya no quedan episodios.
    static var noEpisodesMessage: String {
        "El plan \(name.isEmpty ? "Gratis" : name) incluye \(maxEpisodes ?? 2) episodios y ya los usaste. Pásate al plan Completo para seguir."
    }
}
