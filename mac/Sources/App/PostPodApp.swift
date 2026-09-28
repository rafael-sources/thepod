import SwiftUI
import UniformTypeIdentifiers

@main
struct PostPodApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    init() {
        Keychain.migrateLegacy()
        TextRenderer.registerBundledFonts()
        if SelfTest.isRequested {
            DispatchQueue.main.async { SelfTest.run() }
        }
    }

    var body: some Scene {
        WindowGroup("thePod") {
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
                Divider()
                OpenProbeButton()
            }
        }

        Window("Prueba de sala", id: "prueba-sala") {
            RoomProbeView()
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("introAlAbrir") private var introEnabled = true
    @State private var showIntro = !SelfTest.isRequested

    var body: some View {
        ZStack {
            content
            VStack { Spacer(); HStack { Spacer(); UpdateBanner() } }
            if showIntro && introEnabled {
                IntroView {
                    withAnimation(.easeOut(duration: 0.45)) { showIntro = false }
                    app.introDone = true
                    if Updater.checkOnLaunch { Updater.shared.check(quiet: true) }
                }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            if !(showIntro && introEnabled), Updater.checkOnLaunch, !SelfTest.isRequested { Updater.shared.check(quiet: true) }
        }
    }

    private var content: some View {
        Group {
            if app.section == .pre {
                PreHomeView()
            } else if app.section == .prod {
                ProdHomeView()
            } else if app.section == .ama {
                AmaHomeView()
            } else if let session = app.session {
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
    static let accent = Color(red: 0.957, green: 0.780, blue: 0.439)   // #F4C770, color de postPod en thePod
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
        panel.message = "El paquete de postPod, la carpeta con las pistas, o los videos y audios sueltos"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .movie, .audio, .folder, .mpeg4Movie, .quickTimeMovie]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { done(panel.urls) }
    }
}

/// Archivo → Prueba de sala… (abre la ventana de prueba de prodPod)
struct OpenProbeButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Prueba de sala…") { openWindow(id: "prueba-sala") }
    }
}
