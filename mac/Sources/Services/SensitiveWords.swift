import Foundation

/// Palabras que conviene no decir ni escribir en redes: groserías (se pitan) y temas que las plataformas
/// bajan de alcance o desmonetizan (se cambian en el subtítulo por el eufemismo que se usa en redes).
/// La lista es un punto de partida: el usuario agrega las suyas en la sección.
enum SensitiveWords {
    enum Category: String, Codable { case groseria, sensible }

    struct Entry {
        let stem: String            // sin acentos, minúsculas; `prefix` = cualquier palabra que empiece así
        let prefix: Bool
        let category: Category
        let replacement: String     // lo que se pone en el subtítulo
    }

    static let entries: [Entry] = [
        // Groserías (varias regiones). Se pitan y en el subtítulo se suavizan.
        .init(stem: "mierd", prefix: true, category: .groseria, replacement: "miércoles"),
        .init(stem: "coño", prefix: false, category: .groseria, replacement: "caramba"),
        .init(stem: "coñ", prefix: true, category: .groseria, replacement: "caramba"),
        .init(stem: "carajo", prefix: false, category: .groseria, replacement: "caray"),
        .init(stem: "joder", prefix: false, category: .groseria, replacement: "jolín"),
        .init(stem: "jodid", prefix: true, category: .groseria, replacement: "fastidiado"),
        .init(stem: "jodi", prefix: true, category: .groseria, replacement: "fastidiar"),
        .init(stem: "puta", prefix: true, category: .groseria, replacement: "p***"),
        .init(stem: "puto", prefix: true, category: .groseria, replacement: "p***"),
        .init(stem: "verga", prefix: true, category: .groseria, replacement: "v***"),
        .init(stem: "marico", prefix: true, category: .groseria, replacement: "m***"),
        .init(stem: "maricon", prefix: true, category: .groseria, replacement: "m***"),
        .init(stem: "pendej", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "cabron", prefix: true, category: .groseria, replacement: "c***"),
        .init(stem: "culo", prefix: false, category: .groseria, replacement: "trasero"),
        .init(stem: "ching", prefix: true, category: .groseria, replacement: "ch***"),
        .init(stem: "pinche", prefix: false, category: .groseria, replacement: "maldito"),
        .init(stem: "huevon", prefix: true, category: .groseria, replacement: "flojo"),
        .init(stem: "guevon", prefix: true, category: .groseria, replacement: "flojo"),
        .init(stem: "webon", prefix: true, category: .groseria, replacement: "flojo"),
        .init(stem: "weon", prefix: true, category: .groseria, replacement: "amigo"),
        .init(stem: "hijueput", prefix: true, category: .groseria, replacement: "h***"),
        .init(stem: String(localized: "hijo de put"), prefix: true, category: .groseria, replacement: "h***"),
        .init(stem: "gonorrea", prefix: false, category: .groseria, replacement: "g***"),
        .init(stem: "malparid", prefix: true, category: .groseria, replacement: "m***"),
        .init(stem: "bolud", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "pelotud", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "mamaguev", prefix: true, category: .groseria, replacement: "m***"),
        .init(stem: "mamahuev", prefix: true, category: .groseria, replacement: "m***"),
        .init(stem: "coñazo", prefix: false, category: .groseria, replacement: "golpe"),
        .init(stem: "cagad", prefix: true, category: .groseria, replacement: "embarrada"),
        .init(stem: "cagar", prefix: false, category: .groseria, replacement: "c***"),
        .init(stem: "cago", prefix: false, category: .groseria, replacement: "c***"),
        .init(stem: "pajuo", prefix: true, category: .groseria, replacement: "p***"),
        .init(stem: "polla", prefix: false, category: .groseria, replacement: "p***"),
        .init(stem: "gilipoll", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "hostia", prefix: true, category: .groseria, replacement: "ostras"),
        .init(stem: "cojones", prefix: false, category: .groseria, replacement: "narices"),
        .init(stem: "follar", prefix: false, category: .groseria, replacement: "f***"),
        .init(stem: "pija", prefix: false, category: .groseria, replacement: "p***"),
        .init(stem: "concha", prefix: false, category: .groseria, replacement: "c***"),
        .init(stem: "culia", prefix: true, category: .groseria, replacement: "c***"),
        .init(stem: "chucha", prefix: false, category: .groseria, replacement: "ch***"),
        .init(stem: "zorra", prefix: false, category: .groseria, replacement: "z***"),
        .init(stem: "perra", prefix: false, category: .groseria, replacement: "p***"),
        .init(stem: "bastardo", prefix: true, category: .groseria, replacement: "b***"),
        .init(stem: "idiota", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "imbecil", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "estupid", prefix: true, category: .groseria, replacement: "tonto"),
        .init(stem: "fuck", prefix: true, category: .groseria, replacement: "f***"),
        .init(stem: "shit", prefix: false, category: .groseria, replacement: "s***"),
        .init(stem: "bitch", prefix: false, category: .groseria, replacement: "b***"),

        // Temas sensibles (las redes bajan el alcance): no se pitan por defecto; se cambia el subtítulo
        // por la palabra que se usa en redes para decir lo mismo.
        .init(stem: "suicid", prefix: true, category: .sensible, replacement: "desvivirse"),
        .init(stem: "matar", prefix: true, category: .sensible, replacement: String(localized: "quitar la vida")),
        .init(stem: "mato", prefix: false, category: .sensible, replacement: String(localized: "le quitó la vida")),
        .init(stem: "mata", prefix: false, category: .sensible, replacement: "desvive"),
        .init(stem: "mataron", prefix: false, category: .sensible, replacement: "desvivieron"),
        .init(stem: "asesin", prefix: true, category: .sensible, replacement: "desvivir"),
        .init(stem: "muerte", prefix: false, category: .sensible, replacement: "partida"),
        .init(stem: "muerto", prefix: true, category: .sensible, replacement: "desvivido"),
        .init(stem: "muert", prefix: true, category: .sensible, replacement: "desvivido"),
        .init(stem: "morir", prefix: true, category: .sensible, replacement: "desvivir"),
        .init(stem: "murio", prefix: false, category: .sensible, replacement: String(localized: "se desvivió")),
        .init(stem: "violacion", prefix: true, category: .sensible, replacement: "abuso"),
        .init(stem: "violar", prefix: false, category: .sensible, replacement: "abusar"),
        .init(stem: "violad", prefix: true, category: .sensible, replacement: "abusado"),
        .init(stem: "sexo", prefix: false, category: .sensible, replacement: "intimidad"),
        .init(stem: "sexual", prefix: true, category: .sensible, replacement: "íntimo"),
        .init(stem: "porno", prefix: true, category: .sensible, replacement: String(localized: "contenido adulto")),
        .init(stem: "droga", prefix: true, category: .sensible, replacement: "sustancias"),
        .init(stem: "cocaina", prefix: false, category: .sensible, replacement: "sustancia"),
        .init(stem: "marihuana", prefix: false, category: .sensible, replacement: "hierba"),
        .init(stem: "heroina", prefix: false, category: .sensible, replacement: "sustancia"),
        .init(stem: "pistola", prefix: true, category: .sensible, replacement: "arma"),
        .init(stem: "disparo", prefix: true, category: .sensible, replacement: "detonación"),
        .init(stem: "disparar", prefix: true, category: .sensible, replacement: "accionar"),
        .init(stem: "bomba", prefix: true, category: .sensible, replacement: "explosivo"),
        .init(stem: "terroris", prefix: true, category: .sensible, replacement: "extremista"),
        .init(stem: "nazi", prefix: true, category: .sensible, replacement: "n*zi"),
        .init(stem: "abuso", prefix: true, category: .sensible, replacement: "maltrato"),
        .init(stem: "pedofil", prefix: true, category: .sensible, replacement: String(localized: "p*dófilo")),
        .init(stem: "secuestr", prefix: true, category: .sensible, replacement: "retención"),
        .init(stem: "sangre", prefix: false, category: .sensible, replacement: String(localized: "s*ngre")),
        .init(stem: "covid", prefix: false, category: .sensible, replacement: String(localized: "la pandemia")),
        .init(stem: "coronavirus", prefix: false, category: .sensible, replacement: String(localized: "la pandemia")),
        .init(stem: "depresion", prefix: false, category: .sensible, replacement: "bajón"),
        .init(stem: "ansiedad", prefix: false, category: .sensible, replacement: "nervios"),
        .init(stem: "alcohol", prefix: true, category: .sensible, replacement: "bebida"),
        .init(stem: "borrach", prefix: true, category: .sensible, replacement: "tomado"),
        .init(stem: "cigarr", prefix: true, category: .sensible, replacement: "tabaco"),
        .init(stem: "fumar", prefix: false, category: .sensible, replacement: String(localized: "f*mar")),
    ]

    /// Minúsculas, sin acentos ni signos.
    static func normalize(_ w: String) -> String {
        let folded = w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        return folded.lowercased().filter { $0.isLetter || $0 == " " }
    }

    /// Qué entrada coincide con una palabra (o nil). Las palabras propias del usuario cuentan como groserías.
    static func match(_ word: String, custom: [String]) -> (category: Category, replacement: String)? {
        let n = normalize(word).trimmingCharacters(in: .whitespaces)
        guard n.count >= 3 else { return nil }
        for c in custom {
            let cn = normalize(c).trimmingCharacters(in: .whitespaces)
            if !cn.isEmpty, n == cn || (cn.count >= 4 && n.hasPrefix(cn)) { return (.groseria, String(c.prefix(1)) + "***") }
        }
        for e in entries {
            if e.prefix ? n.hasPrefix(e.stem) : n == e.stem { return (e.category, e.replacement) }
        }
        return nil
    }

    /// Busca en la transcripción. Conserva lo que el usuario ya decidió (pitido, cambio) en las que siguen ahí.
    static func scan(_ project: Project) -> [SensitiveMark] {
        let previous = Dictionary(project.sensitive.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [SensitiveMark] = []
        for w in project.words.sorted(by: { $0.s < $1.s }) {
            guard let m = match(w.w, custom: project.sensitiveCustom) else { continue }
            let id = SensitiveMark.makeId(lane: w.lane, s: w.s)
            if let old = previous[id] {
                out.append(old)
            } else {
                out.append(SensitiveMark(id: id, word: w.w, lane: w.lane, s: w.s, e: max(w.s + 0.15, w.e),
                                         category: m.category, bleep: m.category == .groseria,
                                         replacement: m.replacement, replace: true))
            }
        }
        return out
    }
}

/// Una palabra detectada y qué hacer con ella.
struct SensitiveMark: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var word: String
    var lane: Int
    var s: Double
    var e: Double
    var category: SensitiveWords.Category
    var bleep: Bool                 // pitido encima (no se oye)
    var replacement: String         // con qué se cambia en el subtítulo
    var replace: Bool               // si se cambia el subtítulo
    var ignored: Bool = false       // el usuario dijo que esta está bien

    static func makeId(lane: Int, s: Double) -> String { String(localized: "\(lane)-\(Int((s * 100).rounded()))") }

    init(id: String, word: String, lane: Int, s: Double, e: Double, category: SensitiveWords.Category,
         bleep: Bool, replacement: String, replace: Bool) {
        self.id = id; self.word = word; self.lane = lane; self.s = s; self.e = e
        self.category = category; self.bleep = bleep; self.replacement = replacement; self.replace = replace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        word = try c.decode(String.self, forKey: .word)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 1
        s = try c.decode(Double.self, forKey: .s)
        e = try c.decode(Double.self, forKey: .e)
        category = try c.decodeIfPresent(SensitiveWords.Category.self, forKey: .category) ?? .groseria
        bleep = try c.decodeIfPresent(Bool.self, forKey: .bleep) ?? false
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        replace = try c.decodeIfPresent(Bool.self, forKey: .replace) ?? false
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
    }
}
