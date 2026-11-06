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
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text("thePod")
                                .font(.system(size: 40, weight: .black, design: .rounded))
                            SectionSwitcher()
                        }
                        Text("Edición y publicación: de tu grabación a episodio, reels y subtítulos. Con pocos clics.")
                            .font(.title3)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    SettingsLink {
                        Label("Ajustes", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                if let job = app.importJob { importProgress(job) }

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

                WebProjectsSection()

                dropZone
            }
            .padding(36)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onAppear { app.reload(); if app.introDone { app.loadWebProjects() } }
        .onChange(of: app.introDone) { _, done in if done { app.loadWebProjects() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.reload() }
    }

    private func importProgress(_ job: JobState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(job.title).font(.headline)
                Spacer()
                Button("Cancelar") { app.cancelImport() }
            }
            if let f = job.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
            Text(job.detail).font(.callout).foregroundStyle(Theme.secondary)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.5)))
    }

    /// Opción secundaria: traer archivos sueltos o un paquete descargado a mano.
    private var dropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down").font(.title3).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("¿Tienes los archivos en tu Mac?").font(.callout.bold())
                Text("Arrastra aquí el paquete de postPod, la carpeta con las pistas o los videos sueltos.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Elegir archivos…") { Panels.chooseImport { app.importItems($0) } }
                .disabled(app.importJob != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Theme.accent.opacity(0.12) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
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
        list
            // Mientras haya un episodio en proceso, revisar cada 20 s si ya terminó
            .task(id: app.webProjects.contains { $0.importing != nil }) {
                guard app.webProjects.contains(where: { $0.importing != nil }) else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if Task.isCancelled { break }
                    app.loadWebProjects()
                }
            }
    }

    private var list: some View {
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

    /// Traer a la Mac. Mientras el episodio todavía está llegando desde prodPod no se puede (quedaría incompleto).
    private func bring(_ w: PostPodWebClient.WebProject) {
        guard w.importing == nil else { return }
        app.importFromWeb(w)
    }

    private func row(_ w: PostPodWebClient.WebProject) -> some View {
        let local = app.localProject(forWeb: w.slug)
        let busy = app.webDownloading == w.slug
        let partial = busy ? nil : PostPodWebClient.partial(slug: w.slug)
        return HStack(spacing: 14) {
            Image(systemName: "cloud.fill").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(w.name).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    if let d = w.createdAt { Text(d, style: .date) }
                    if let o = w.owner { Label(o, systemImage: "person") }
                    if local != nil { Label("Ya está en esta Mac", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good) }
                    if let n = w.importing {
                        Label(n > 0 ? String(localized: "Episodio en proceso · llegando \(n) \(n == 1 ? "pista" : "pistas") desde prodPod") : "Episodio en proceso en la web",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if let partial {
                        Label(partial.total > 0 ? String(localized: "Descarga a medias · \(Int(Double(partial.got) / Double(partial.total) * 100))%") : "Descarga a medias",
                              systemImage: "pause.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if w.importing != nil {
                // Todavía llegan pistas desde prodPod: no se puede traer hasta que esté listo en la web
                Label("Se puede traer cuando esté listo en la web", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.red)
                    .help("La lista se actualiza sola cada 20 segundos")
            } else if partial != nil {
                Button { bring(w) } label: {
                    Label("Reanudar", systemImage: "arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.importJob != nil)
                Button("Descartar") { PostPodWebClient.discardPartial(slug: w.slug); app.objectWillChange.send() }
                    .buttonStyle(.bordered)
                    .disabled(app.importJob != nil)
            } else if let local {
                Button("Abrir") { app.open(local) }.buttonStyle(.borderedProminent)
                Button("Traer de nuevo") { bring(w) }
                    .buttonStyle(.bordered)
                    .disabled(app.importJob != nil)
                    .help("Descarga otra copia desde postPod (la actual no se borra)")
            } else {
                Button { bring(w) } label: {
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
