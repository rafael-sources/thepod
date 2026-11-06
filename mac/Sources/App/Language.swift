import SwiftUI
import AppKit

/// Idioma de la app: Sistema, Español o English. Las claves de texto son el español del código; el inglés vive en
/// `Resources/en.lproj/Localizable.strings`. Cambiarlo escribe `AppleLanguages` y relanza la app: así todas las
/// pantallas salen en el idioma nuevo sin casos raros (es lo que hacen Final Cut o Logic).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, es, en
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return String(localized: "Igual que el sistema")
        case .es: return "Español"
        case .en: return "English"
        }
    }

    static let key = "idioma"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// El idioma con el que está corriendo la app ahora (es o en).
    static var running: String {
        let code = Bundle.main.preferredLocalizations.first ?? "es"
        return code.hasPrefix("en") ? "en" : "es"
    }

    /// Guarda la elección y deja `AppleLanguages` como toca. Devuelve true si hace falta relanzar.
    @discardableResult
    static func apply(_ lang: AppLanguage) -> Bool {
        let d = UserDefaults.standard
        d.set(lang.rawValue, forKey: key)
        switch lang {
        case .system: d.removeObject(forKey: "AppleLanguages")
        case .es: d.set(["es"], forKey: "AppleLanguages")
        case .en: d.set(["en"], forKey: "AppleLanguages")
        }
        d.synchronize()
        let wanted = lang == .system ? (Locale.preferredLanguages.first.map { $0.hasPrefix("en") ? "en" : "es" } ?? "es") : lang.rawValue
        return wanted != running
    }

    /// Cierra la app y la vuelve a abrir (medio segundo después, cuando ya salió).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Sección de Ajustes: elegir idioma; si cambia, avisa y relanza.
struct LanguageSettingsSection: View {
    @State private var choice = AppLanguage.current
    @State private var askRelaunch = false

    var body: some View {
        Section(String(localized: "Idioma")) {
            Picker(String(localized: "Idioma de thePod"), selection: $choice) {
                ForEach(AppLanguage.allCases) { l in Text(l.name).tag(l) }
            }
            .onChange(of: choice) { _, new in
                if AppLanguage.apply(new) { askRelaunch = true }
            }
            Text(String(localized: "Al cambiar de idioma la app se cierra y vuelve a abrir sola; tu trabajo queda guardado."))
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .alert(String(localized: "Cambiar de idioma"), isPresented: $askRelaunch) {
            Button(String(localized: "Reiniciar ahora")) { AppLanguage.relaunch() }
            Button(String(localized: "Más tarde"), role: .cancel) {}
        } message: { Text(String(localized: "thePod se cierra y vuelve a abrir en el idioma elegido.")) }
    }
}
