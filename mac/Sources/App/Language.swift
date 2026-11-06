import SwiftUI
import AppKit

/// App language: System, Español or English. Text keys are the Spanish in the code; the English lives in
/// `Resources/en.lproj/Localizable.strings`. Changing it writes `AppleLanguages` and relaunches the app: that way every
/// screen comes up in the new language without odd cases (it's what Final Cut or Logic do).
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

    /// The language the app is running in now (es or en).
    static var running: String {
        let code = Bundle.main.preferredLocalizations.first ?? "es"
        return code.hasPrefix("en") ? "en" : "es"
    }

    /// Locale for on-screen dates and numbers: that of the language the app runs in.
    static var locale: Locale { Locale(identifier: running == "en" ? "en_US" : "es") }

    /// Saves the choice and sets `AppleLanguages` accordingly. Returns true if a relaunch is needed.
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

    /// Quits the app and reopens it (half a second later, once it has exited).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Settings section: pick the language; if it changes, notifies and relaunches.
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
