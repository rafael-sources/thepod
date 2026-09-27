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
