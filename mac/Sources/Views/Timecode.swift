import SwiftUI

/// Tiempo en horas:minutos:segundos, siempre con el mismo formato (0:04:51.3).
enum Timecode {
    static func string(_ t: Double, tenths: Bool = true) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600, m = (Int(total) % 3600) / 60, s = Int(total) % 60
        let d = Int((total - Double(Int(total))) * 10)
        return tenths ? String(format: "%d:%02d:%02d.%d", h, m, s, d) : String(format: "%d:%02d:%02d", h, m, s)
    }

    /// Acepta "1:02:03", "2:03", "123", "2:03.5", "1h2m3s". Devuelve segundos o nil si no se entiende.
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        if s.contains("h") || s.contains("m") || s.contains("s") {
            var total = 0.0, num = ""
            for ch in s {
                if ch.isNumber || ch == "." { num.append(ch); continue }
                guard let v = Double(num) else { return nil }
                switch ch { case "h": total += v * 3600; case "m": total += v * 60; case "s": total += v; default: return nil }
                num = ""
            }
            if let v = Double(num) { total += v }
            return total
        }
        s = s.replacingOccurrences(of: " ", with: "")
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3, let last = Double(parts.last ?? "") else { return nil }
        var total = last
        if parts.count >= 2 { guard let m = Double(parts[parts.count - 2]) else { return nil }; total += m * 60 }
        if parts.count == 3 { guard let h = Double(parts[0]) else { return nil }; total += h * 3600 }
        return total
    }
}

/// Campo para escribir un tiempo exacto (h:mm:ss o mm:ss). Se aplica al dar Enter o al salir del campo.
struct TimecodeField: View {
    @Binding var seconds: Double
    var range: ClosedRange<Double> = 0...(24 * 3600)
    var onCommit: ((Double) -> Void)? = nil
    @State private var text = ""
    @State private var bad = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("h:mm:ss", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            .frame(width: 92)
            .multilineTextAlignment(.center)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(bad ? Color.orange : .clear))
            .onAppear { text = Timecode.string(seconds) }
            .onChange(of: seconds) { _, v in if !focused { text = Timecode.string(v) } }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit { commit() }
            .help("Escribe el tiempo exacto: 1:02:03, 2:03, 2:03.5 o 123 (segundos)")
    }

    private func commit() {
        guard let v = Timecode.parse(text) else { bad = true; text = Timecode.string(seconds); return }
        bad = false
        let clamped = min(range.upperBound, max(range.lowerBound, v))
        seconds = clamped
        text = Timecode.string(clamped)
        onCommit?(clamped)
    }
}

/// Reloj grande del video: dónde está parado y corriendo cuando reproduce. Clic para escribir un tiempo e ir ahí.
struct BigClock: View {
    @ObservedObject var session: ProjectSession
    @State private var editing = false
    @State private var typed = 0.0

    var body: some View {
        HStack(spacing: 10) {
            if editing {
                TimecodeField(seconds: $typed, range: 0...max(0, session.project.duration)) { v in
                    session.seek(timeline: v, play: false)
                    editing = false
                }
                Button("Ir") { editing = false }.controlSize(.small)
                Button("Cancelar") { editing = false }.controlSize(.small)
            } else {
                SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(Timecode.string(session.playheadTimeline))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Text("/ \(Timecode.string(session.project.duration, tenths: false))")
                    .font(.callout.monospacedDigit()).foregroundStyle(Theme.secondary)
                Button { typed = session.playheadTimeline; editing = true } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.borderless).help("Escribir un tiempo e ir ahí")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
