import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("postPod")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                        Text("De tu grabación a episodio, reels y subtítulos. Con pocos clics.")
                            .font(.title3)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    SettingsLink {
                        Label("Ajustes", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                dropZone

                WebProjectsSection()

                if !app.projects.isEmpty {
                    Text("Tus episodios")
                        .font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(app.projects) { p in
                            ProjectCard(project: p)
                                .onTapGesture { app.open(p) }
                                .contextMenu {
                                    Button("Abrir") { app.open(p) }
                                    Button("Mostrar en Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.folder(for: p.id)])
                                    }
                                    Divider()
                                    Button("Mover a la papelera", role: .destructive) { app.delete(p) }
                                }
                        }
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.reload(); app.loadWebProjects() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.reload() }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            if let job = app.importJob {
                VStack(spacing: 14) {
                    ProgressView(value: job.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 420)
                    Text(job.title).font(.title3.bold())
                    Text(job.detail).foregroundStyle(Theme.secondary)
                    Text("Los videos WebM se convierten una sola vez; luego todo va rápido.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Button("Cancelar") { app.cancelImport() }
                }
            } else {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.accent)
                Text("Arrastra aquí tu grabación")
                    .font(.title2.bold())
                Text("El paquete que descargas de postPod, la carpeta con las pistas de cada persona, o los videos sueltos.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 520)
                Button {
                    Panels.chooseImport { app.importItems($0) }
                } label: {
                    Label("Elegir archivos…", systemImage: "folder")
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20).fill(targeted ? Theme.accent.opacity(0.12) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(targeted ? Theme.accent : Theme.stroke))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadFileURL() { urls.append(url) }
                }
                await MainActor.run { app.importItems(urls) }
            }
            return true
        }
    }
}

struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mic.and.signal.meter.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                Spacer()
                if project.fix.lastRun != nil {
                    Label("Arreglado", systemImage: "checkmark.seal.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.good)
                }
            }
            Text(project.name)
                .font(.headline)
                .lineLimit(2)
            Text(project.lanes.map { project.laneName($0.id) }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            HStack {
                Label(EditEngine.clock(project.duration), systemImage: "clock")
                Spacer()
                Text(project.createdAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(Theme.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        .contentShape(Rectangle())
    }
}

extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}

/// "En postPod web": the projects this account can see online, downloadable in one click.
struct WebProjectsSection: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("En postPod web").font(.title2.bold())
                Spacer()
                if app.webState == .loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await PostPodWebClient.shared.resetSession() }
                    app.loadWebProjects()
                } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .disabled(app.webState == .loading)
            }
            switch app.webState {
            case .notConfigured:
                Card {
                    Text("Conecta tu cuenta para ver aquí tus episodios de postPod y traerlos sin descargar nada a mano.")
                        .foregroundStyle(Theme.secondary)
                    SettingsLink { Label("Abrir Ajustes", systemImage: "gearshape") }
                }
            case .failed(let msg):
                Card {
                    Label("No pude conectar con postPod", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg).font(.callout).foregroundStyle(Theme.secondary)
                }
            case .loaded where app.webProjects.isEmpty:
                Text("No hay proyectos de postPod visibles para tu cuenta.").foregroundStyle(Theme.secondary)
            default:
                VStack(spacing: 8) {
                    ForEach(app.webProjects) { w in row(w) }
                }
            }
        }
    }

    private func row(_ w: PostPodWebClient.WebProject) -> some View {
        let local = app.localProject(forWeb: w.slug)
        let busy = app.webDownloading == w.slug
        return HStack(spacing: 14) {
            Image(systemName: "cloud.fill").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(w.name).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    if let d = w.createdAt { Text(d, style: .date) }
                    if let o = w.owner { Label(o, systemImage: "person") }
                    if local != nil { Label("Ya está en esta Mac", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good) }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if let local {
                Button("Abrir") { app.open(local) }.buttonStyle(.borderedProminent)
                Button("Traer de nuevo") { app.importFromWeb(w) }
                    .buttonStyle(.bordered)
                    .disabled(app.importJob != nil)
                    .help("Descarga otra copia desde postPod (la actual no se borra)")
            } else {
                Button { app.importFromWeb(w) } label: {
                    Label("Traer a la Mac", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.importJob != nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }
}
