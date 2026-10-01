import SwiftUI
import AVKit

struct ProjectView: View {
    @ObservedObject var session: ProjectSession
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
                .background(Color.black.opacity(0.25))
            Divider()
            VStack(spacing: 0) {
                Group {
                    switch session.step {
                    case .overview: OverviewStep(session: session)
                    case .fix: FixStep(session: session)
                    case .captions: CaptionsStep(session: session)
                    case .sounds: SoundsStep(session: session)
                    case .reels: ReelsStep(session: session)
                    case .export: ExportStep(session: session)
                    case .publish: PublishStep(session: session)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                EpisodeTimeline(session: session)
                if let job = session.job {
                    JobBar(job: job) { session.cancelJob() }
                }
            }
        }
        .alert("Algo salió mal", isPresented: Binding(get: { session.errorMessage != nil },
                                                      set: { if !$0 { session.errorMessage = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(session.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                app.close()
            } label: {
                Label("Mis episodios", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .padding(.bottom, 14)
            .padding(.top, 28)

            Text(session.project.name)
                .font(.headline)
                .lineLimit(3)
                .padding(.bottom, 4)
            Text("\(EditEngine.clock(session.project.duration)) · \(session.project.lanes.count) \(session.project.lanes.count == 1 ? "persona" : "personas")")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 18)

            ForEach(Step.allCases) { step in
                Button {
                    session.step = step
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(session.step == step ? Theme.accent : Theme.panelStrong)
                                .frame(width: 26, height: 26)
                            if done(step) && session.step != step {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.good)
                            } else {
                                Text("\(step.number)").font(.caption.bold())
                                    .foregroundStyle(session.step == step ? .black : .white)
                            }
                        }
                        Text(step.title).font(.body.weight(session.step == step ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.vertical, 8).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(session.step == step ? Theme.panelStrong : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.exportsFolder(for: session.project.id)])
            } label: {
                Label("Carpeta de exportados", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
    }

    private func done(_ step: Step) -> Bool {
        let p = session.project
        switch step {
        case .overview: return true
        case .fix: return p.fix.lastRun != nil
        case .captions: return p.isTranscribed
        case .sounds: return !p.audioLane.isEmpty
        case .reels: return p.reels.contains { $0.exportedFile != nil }
        case .export: return !session.lastExports.isEmpty
        case .publish: return p.episode.publishedAudioURL != nil || p.episode.publishedYouTubeURL != nil
        }
    }
}

// MARK: - Shared pieces

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct PreviewPane: View {
    @ObservedObject var session: ProjectSession
    var allowedFormats: [ExportFormat] = [.landscape, .vertical, .square]
    @State private var marked = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                PlayerView(player: session.player)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if session.built == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Preparando vista previa…").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            TrackInspector(session: session)
            HStack {
                Button {
                    session.markMoment()
                    marked = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { marked = false }
                } label: {
                    Label(marked ? "Momento marcado · lo ves en Reels" : "Marcar momento", systemImage: marked ? "checkmark" : "bookmark.fill")
                }
                .help("Marca este punto para hacer un reel, como la tecla M en postPod web")
                .disabled(session.built == nil)
                Spacer()
            }
            .frame(maxWidth: 520)
            if allowedFormats.count > 1 {
                Picker("Vista", selection: Binding(get: { session.previewFormat },
                                                    set: { session.setPreview(format: $0, window: session.previewWindow, layout: session.previewLayout) })) {
                    ForEach(allowedFormats) { f in
                        Label(f == .landscape ? "16:9" : f == .vertical ? "9:16" : "1:1", systemImage: f.symbol).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
            }
        }
    }
}

/// Panel bajo el video con lo editable de la pista elegida en el timeline (persona o música/efecto).
struct TrackInspector: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        if let sel = session.selectedTrack {
            VStack(alignment: .leading, spacing: 8) {
                switch sel {
                case .lane(let id):
                    if let i = session.project.lanes.firstIndex(where: { $0.id == id }) { laneBody(i) }
                case .sound(let id):
                    if let i = session.project.audioLane.firstIndex(where: { $0.id == id }) { soundBody(i) }
                }
            }
            .padding(12)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        }
    }

    private func header(_ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.headline)
            Spacer()
            Button { session.selectedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
        }
    }

    private func fadeRow(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...8, step: 0.25)
            Text(value.wrappedValue == 0 ? "no" : String(format: "%.2g s", value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
    }

    private func volumeRow(value: Binding<Double>, max: Double) -> some View {
        HStack(spacing: 8) {
            Text("Volumen").frame(width: 72, alignment: .leading)
            Button { value.wrappedValue = value.wrappedValue == 0 ? 1 : 0 } label: {
                Image(systemName: value.wrappedValue == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless).help(value.wrappedValue == 0 ? "Activar" : "Silenciar")
            Slider(value: value, in: 0...max)
            Text("\(Int(value.wrappedValue * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func laneBody(_ i: Int) -> some View {
        let lane = session.project.lanes[i]
        header(session.project.laneName(lane.id), "person.fill")
        volumeRow(value: $session.project.lanes[i].volume, max: 2)
        fadeRow(label: "Fade entrada", value: $session.project.lanes[i].fadeIn)
        fadeRow(label: "Fade salida", value: $session.project.lanes[i].fadeOut)
        HStack(spacing: 6) {
            Text("Desfase").frame(width: 72, alignment: .leading)
            Button("−0.5") { session.setLaneOffset(lane.id, lane.offset - 0.5) }
            Button("−0.1") { session.setLaneOffset(lane.id, lane.offset - 0.1) }
            Text(String(format: "%+.2f s", lane.offset)).monospacedDigit().frame(width: 70)
            Button("+0.1") { session.setLaneOffset(lane.id, lane.offset + 0.1) }
            Button("+0.5") { session.setLaneOffset(lane.id, lane.offset + 0.5) }
            Spacer()
            Toggle("Espejo", isOn: Binding(get: { session.project.laneMirror[lane.id] ?? false },
                                           set: { session.project.laneMirror[lane.id] = $0 }))
                .toggleStyle(.checkbox)
        }
        .font(.callout).controlSize(.small)
        Text("El desfase mueve el inicio de su grabación (no puede ser negativo: si va adelantada, atrasa a los demás). Los cortes se aplican igual a todas las pistas.")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }

    @ViewBuilder
    private func soundBody(_ i: Int) -> some View {
        let clip = session.project.audioLane[i]
        let name = session.project.mediaItem(clip.mediaId).map { (($0.originalName as NSString).deletingPathExtension) } ?? "Sonido"
        header("\(name) · \(EditEngine.clock(clip.tlStart))", "music.note")
        volumeRow(value: $session.project.audioLane[i].volume, max: 1.5)
        fadeRow(label: "Fade entrada", value: $session.project.audioLane[i].fadeIn)
        fadeRow(label: "Fade salida", value: $session.project.audioLane[i].fadeOut)
        HStack(spacing: 6) {
            Text("Mover").frame(width: 72, alignment: .leading)
            Button("Al inicio") { session.moveSound(clip.id, to: 0) }
            Button("−1 s") { session.moveSound(clip.id, to: clip.tlStart - 1) }
            Button("Aquí") { session.moveSound(clip.id, to: session.playheadTimeline) }.help("Donde está el video ahora")
            Button("+1 s") { session.moveSound(clip.id, to: clip.tlStart + 1) }
            Button("Al final") { session.moveSound(clip.id, to: session.project.duration - max(0, clip.srcOut - clip.srcIn)) }
            Spacer()
            Button(role: .destructive) { session.project.audioLane.removeAll { $0.id == clip.id }; session.selectedTrack = nil } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Quitar")
        }
        .font(.callout).controlSize(.small)
        Text(String(format: "Dura %.0f s. Los cortes del episodio también se aplican a la música.", clip.srcOut - clip.srcIn))
            .font(.caption2).foregroundStyle(Theme.secondary)
    }
}

struct JobBar: View {
    let job: JobState
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            if let f = job.fraction {
                ProgressView(value: f).frame(width: 220)
                Text("\(Int(f * 100))%").monospacedDigit().foregroundStyle(Theme.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.callout.bold())
                if !job.detail.isEmpty { Text(job.detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            Spacer()
            Button("Cancelar", action: cancel)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

struct StepHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(disabled)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}

extension Color {
    init(hex: String) {
        let c = TextRenderer.color(hex) ?? .white
        self.init(nsColor: c)
    }
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
