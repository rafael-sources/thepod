import SwiftUI

/// Los atajos de teclado de la app, en una sola lista: la ventana «?» de Studio y el manual salen de aquí.
/// Valen cuando no se está escribiendo en un campo de texto.
struct Shortcut: Identifiable, Equatable {
    enum Scope: String, CaseIterable {
        case everywhere, studio, video, audio
        var name: String {
            switch self {
            case .everywhere: return String(localized: "En toda la app"); case .studio: return String(localized: "Studio")
            case .video: return String(localized: "Studio · Video"); case .audio: return String(localized: "Studio · Audio")
            }
        }
    }
    var id: String { keys + "·" + scope.rawValue }
    let keys: String
    let what: String
    let scope: Scope
}

enum StudioShortcuts {
    static let all: [Shortcut] = [
        Shortcut(keys: "Espacio · K", what: String(localized: "Reproducir / pausar"), scope: .everywhere),
        Shortcut(keys: "← →", what: String(localized: "Un segundo atrás / adelante (con ⇧, cinco)"), scope: .everywhere),
        Shortcut(keys: "J · L", what: String(localized: "Cinco segundos atrás / adelante"), scope: .everywhere),
        Shortcut(keys: "M", what: String(localized: "Marcar momento (reel de 60 s desde aquí)"), scope: .everywhere),
        Shortcut(keys: "I · O", what: String(localized: "Marcar inicio y fin de un reel"), scope: .everywhere),
        Shortcut(keys: "⌘Z · ⇧⌘Z", what: String(localized: "Deshacer / rehacer"), scope: .everywhere),
        Shortcut(keys: "Suprimir", what: String(localized: "Quitar el punto de volumen elegido"), scope: .everywhere),
        Shortcut(keys: "⌘O", what: String(localized: "Importar grabación"), scope: .everywhere),
        Shortcut(keys: "⌘E", what: String(localized: "Abrir Studio · Audio"), scope: .everywhere),
        Shortcut(keys: "⇧⌘E", what: String(localized: "Abrir Studio · Video"), scope: .everywhere),
        Shortcut(keys: "⇧⌘B", what: String(localized: "A/B: oír las voces sin cadena mientras suena"), scope: .studio),
        Shortcut(keys: "?", what: String(localized: "Esta lista de atajos"), scope: .studio),
        Shortcut(keys: "1 · 2 · 3 · 4", what: String(localized: "Multicámara: cortar a esa cámara en este segundo"), scope: .video),
        Shortcut(keys: "Clic derecho en Cámaras", what: String(localized: "Fijar una cámara o una plantilla en ese segundo"), scope: .video),
        Shortcut(keys: "Arrastrar un clip", what: String(localized: "Moverlo; con el imán al ritmo, se engancha a los beats"), scope: .video),
        Shortcut(keys: "Rombo junto a un control", what: String(localized: "Poner o quitar un keyframe en este segundo"), scope: .video),
        Shortcut(keys: "Doble clic en un carril", what: String(localized: "Borrar ese punto de automatización"), scope: .audio),
        Shortcut(keys: "⌥ clic en un fader", what: String(localized: "Volver ese fader a 0 dB"), scope: .audio),
    ]

    /// Teclas repetidas dentro del mismo ámbito (para la prueba automática).
    static var duplicates: [String] {
        var seen: Set<String> = [], dup: [String] = []
        for s in all {
            for k in s.keys.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) where !k.isEmpty {
                let key = "\(s.scope.rawValue):\(k)"
                if !seen.insert(key).inserted { dup.append(key) }
            }
        }
        return dup
    }
}

struct ShortcutsPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Atajos").font(.headline)
            ForEach(Shortcut.Scope.allCases, id: \.self) { scope in
                let items = StudioShortcuts.all.filter { $0.scope == scope }
                if !items.isEmpty {
                    Text(scope.name).font(.caption.bold()).foregroundStyle(Theme.secondary).padding(.top, 4)
                    ForEach(items) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Text(s.keys).font(.caption.monospaced()).frame(width: 150, alignment: .leading)
                            Text(s.what).font(.caption)
                        }
                    }
                }
            }
            Text("Valen cuando no estás escribiendo en un campo de texto.").font(.caption2).foregroundStyle(Theme.secondary).padding(.top, 4)
        }
        .padding(14).frame(width: 440)
    }
}
