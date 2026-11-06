import SwiftUI

// Piezas visuales de la sección pre: colores por estado y por tipo de bloque, avatares, chips y fechas amables.

extension EpisodeStatus {
    var color: Color {
        switch self {
        case .idea: return Color(red: 0.98, green: 0.80, blue: 0.30)
        case .planning: return Color(red: 0.40, green: 0.62, blue: 1.00)
        case .scripted: return Color(red: 0.66, green: 0.52, blue: 1.00)
        case .recorded: return Color(red: 1.00, green: 0.45, blue: 0.45)
        case .published: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .archived: return Color(white: 0.55)
        }
    }
    /// Lo que significa la columna, en una línea.
    var hint: String {
        switch self {
        case .idea: return String(localized: "Por pensar")
        case .planning: return String(localized: "Armando el episodio")
        case .scripted: return String(localized: "Listo para grabar")
        case .recorded: return String(localized: "A edición (post)")
        case .published: return String(localized: "Ya está al aire")
        case .archived: return String(localized: "Guardados aparte")
        }
    }
}

extension BlockKind {
    var color: Color {
        switch self {
        case .intro: return Color(red: 0.40, green: 0.62, blue: 1.00)
        case .segment: return Color(red: 0.30, green: 0.78, blue: 0.80)
        case .interview: return Color(red: 0.98, green: 0.62, blue: 0.30)
        case .sponsor: return Color(red: 0.70, green: 0.45, blue: 1.00)
        case .break: return Color(white: 0.55)
        case .outro: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .custom: return Color(red: 0.95, green: 0.50, blue: 0.70)
        }
    }
    var symbol: String {
        switch self {
        case .intro: return "play.fill"
        case .segment: return "text.bubble.fill"
        case .interview: return "person.2.fill"
        case .sponsor: return "star.fill"
        case .break: return "pause.fill"
        case .outro: return "flag.checkered"
        case .custom: return "square.fill"
        }
    }
}

enum RSVP {
    static func color(_ s: String) -> Color {
        switch s {
        case "yes": return Theme.good
        case "maybe": return .orange
        case "no": return Color(red: 1, green: 0.42, blue: 0.42)
        default: return Color(white: 0.6)
        }
    }
    static func symbol(_ s: String) -> String {
        switch s {
        case "yes": return "checkmark.circle.fill"
        case "maybe": return "questionmark.circle.fill"
        case "no": return "xmark.circle.fill"
        default: return "clock.fill"
        }
    }
}

/// Círculo con iniciales y un color estable por nombre.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        ZStack {
            Circle().fill(Self.color(for: name).gradient)
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
    static func color(for s: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .cyan, .mint]
        let h = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}

/// Etiqueta redondeada de color.
struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .prePod
    var filled = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.bold()) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(filled ? Color.black : color)
        .background(Capsule().fill(filled ? color : color.opacity(0.16)))
    }
}

/// Explicación breve de una pantalla: título grande y una línea de ayuda.
struct PreHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var color: Color = .prePod
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.18))
                Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(color)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Estado vacío con una acción clara.
struct EmptyHint: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.prePod.opacity(0.8))
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

extension PreEpisode {
    /// Fecha de grabación como Date (acepta "2026-10-02" o "2026-10-02T19:00").
    var scheduled: Date? {
        guard let raw = scheduledAt ?? scheduledDate, raw.count >= 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if raw.count >= 16, raw.dropFirst(10).first == "T" {
            f.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let d = f.date(from: String(raw.prefix(16))) { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }

    /// "hoy", "mañana", "en 5 días", "hace 2 días".
    var relativeWhen: String? {
        guard let d = scheduled else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case 0: return "hoy"
        case 1: return "mañana"
        case -1: return "ayer"
        case 2...: return String(localized: "en \(days) días")
        default: return String(localized: "hace \(-days) días")
        }
    }

    /// Ya pasó la fecha y todavía no se grabó.
    var isLate: Bool {
        guard let d = scheduled else { return false }
        let st = statusValue
        return Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: Date())
            && (st == .idea || st == .planning || st == .scripted)
    }
}

extension Color {
    /// Color del podcast (si lo tiene en su branding) o el azul de prePod.
    static func podcast(_ hex: String?) -> Color {
        guard let hex, !hex.isEmpty, let ns = TextRenderer.color(hex)?.usingColorSpace(.sRGB) else { return .prePod }
        // Un color muy oscuro o muy claro no se lee sobre el fondo negro: se usa el azul de prePod
        let lum = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return (0.28...0.85).contains(lum) ? Color(nsColor: ns) : .prePod
    }
}

/// "1 bloque", "3 bloques".
func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
