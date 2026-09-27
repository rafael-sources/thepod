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
                Text("El paquete .zip que descargas de postPod, la carpeta con las pistas de cada persona, o los videos sueltos.")
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
