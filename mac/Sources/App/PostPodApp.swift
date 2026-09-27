import SwiftUI
import UniformTypeIdentifiers

@main
struct PostPodApp: App {
    @StateObject private var app = AppModel()

    init() {
        TextRenderer.registerBundledFonts()
        if SelfTest.isRequested {
            DispatchQueue.main.async { SelfTest.run() }
        }
    }

    var body: some Scene {
        WindowGroup("postPod") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar grabación…") { Panels.chooseImport { app.importItems($0) } }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if let session = app.session {
                ProjectView(session: session)
                    .id(session.project.id)
            } else {
                HomeView()
            }
        }
        .background(Theme.background)
        .alert("Algo salió mal", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.2)
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let panel = Color(white: 1, opacity: 0.05)
    static let panelStrong = Color(white: 1, opacity: 0.09)
    static let stroke = Color(white: 1, opacity: 0.1)
    static let secondary = Color(white: 1, opacity: 0.6)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.55)
}

enum Panels {
    static func chooseImport(_ done: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Elige tu grabación"
        panel.message = "El paquete .zip de postPod, la carpeta con las pistas, o los videos/audios sueltos"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .movie, .audio, .folder, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { done(panel.urls) }
    }
}
