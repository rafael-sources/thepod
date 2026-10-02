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
                    case .look: LookStep(session: session)
                    case .layers: LayersStep(session: session)
                    case .cintillos: CintillosStep(session: session)
                    case .sounds: SoundsStep(session: session)
                    case .brands: BrandsStep(session: session)
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
        .modifier(KeyShortcuts(session: session))
        .overlay(alignment: .bottom) {
            if let n = session.note {
                Text(n).font(.callout.weight(.semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent))
                    .padding(.bottom, 170)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.note)
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

            ForEach(Step.Group.allCases, id: \.self) { group in
                Text(group.rawValue)
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, group == .prepare ? 0 : 12).padding(.bottom, 2).padding(.horizontal, 8)
                ForEach(Step.allCases.filter { $0.group == group }) { step in
                    let active = session.step == step
                    Button {
                        session.step = step
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: step.symbol)
                                .font(.system(size: 14))
                                .foregroundStyle(active ? Theme.accent : .white)
                                .frame(width: 22)
                            Text(step.title).font(.body.weight(active ? .semibold : .regular))
                            Spacer()
                            if done(step) {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.good)
                            } else if let h = hint(step) {
                                Text(h).font(.caption2).foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.vertical, 7).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(active ? Theme.panelStrong : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            readiness
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
        case .look: return p.backgroundFile != nil || p.layout != .auto || p.intro != nil
        case .layers: return !p.overlays.isEmpty || !p.brolls.isEmpty
        case .cintillos: return !p.cintillos.isEmpty
        case .sounds: return !p.audioLane.isEmpty
        case .brands: return !p.sponsors.isEmpty || !p.cintillos.isEmpty
        case .reels: return p.reels.contains { $0.exportedFile != nil }
        case .export: return !session.lastExports.isEmpty
        case .publish: return p.episode.publishedAudioURL != nil || p.episode.publishedYouTubeURL != nil
        }
    }

    /// Pista corta a la derecha de una sección que todavía no está hecha.
    private func hint(_ step: Step) -> String? {
        let p = session.project
        switch step {
        case .captions: return p.isTranscribed ? nil : "sin transcribir"
        case .sounds: return p.audioLane.isEmpty ? nil : "\(p.audioLane.count)"
        case .layers: return p.overlays.isEmpty ? nil : "\(p.overlays.count)"
        case .cintillos: return p.cintillos.isEmpty ? nil : "\(p.cintillos.count)"
        case .brands: return p.sponsors.isEmpty ? nil : "\(p.sponsors.count)"
        default: return nil
        }
    }

    /// Cajita "Listo para exportar": qué falta antes de entregar.
    private var readiness: some View {
        let p = session.project
        let items: [(Bool, String, Bool)] = [   // (hecho, texto, opcional)
            (p.fix.lastRun != nil, "Sonido limpio", false),
            (p.isTranscribed, "Subtítulos", true),
            (p.backgroundFile != nil && p.logoFile != nil, "Fondo y logo del podcast", true),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            Text("LISTO PARA EXPORTAR").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) {
                    Image(systemName: it.0 ? "checkmark" : "circle").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(it.0 ? Theme.good : Theme.secondary)
                    Text(it.1 + (it.2 && !it.0 ? " (opcional)" : "")).font(.caption)
                        .foregroundStyle(it.0 || !it.2 ? .white : Theme.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .padding(.top, 14)
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
            HStack { BigClock(session: session); Spacer() }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                PlayerView(player: session.player)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                OverlayHandles(session: session)
                CaptionHandles(session: session)
                if session.built == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Preparando vista previa…").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .frame(minHeight: 260)
            // El panel de la pista puede ser alto (cintillos, capas): se desplaza y el video no se achica
            ScrollView { TrackInspector(session: session) }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
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
                case .sound, .reelSound:
                    if let b = session.soundBinding(sel) { soundBody(b, sel: sel) }
                case .overlay(let id):
                    OverlayEditor(session: session, id: id)
                case .broll(let id):
                    BRollEditor(session: session, id: id, reelId: nil)
                case .reelBRoll(let reelId, let id):
                    BRollEditor(session: session, id: id, reelId: reelId)
                case .cintillo, .reelCintillo:
                    CintilloEditor(session: session, sel: sel)
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
        if session.project.lanes.count > 1 {
            let onScreen = session.project.lanesOnScreen.map(\.id)
            HStack(spacing: 6) {
                Text("Posición").frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(get: { (onScreen.firstIndex(of: lane.id) ?? 0) + 1 },
                                              set: { session.setLanePosition(lane.id, $0) })) {
                    ForEach(1...onScreen.count, id: \.self) { n in Text("\(n)").tag(n) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                Text("1 = izquierda o arriba").font(.caption2).foregroundStyle(Theme.secondary)
            }
            .font(.callout).controlSize(.small)
        }
        Divider()
        HStack(spacing: 6) {
            Text("Voz").frame(width: 72, alignment: .leading)
            Button("Cálida") { setEQ(i, VoiceEQ.preset("warm")) }
            Button("Clara") { setEQ(i, VoiceEQ.preset("clear")) }
            Button("Quitar retumbe") { setEQ(i, VoiceEQ.preset("rumble")) }
            Button("Original") { setEQ(i, VoiceEQ()) }
        }
        .font(.callout).controlSize(.small)
        eqRow("Graves", $session.project.lanes[i].eq.low)
        eqRow("Medios", $session.project.lanes[i].eq.mid)
        eqRow("Agudos", $session.project.lanes[i].eq.high)
        if !session.eqApplied(laneId: lane.id) {
            HStack {
                Text("Cambios sin aplicar: el ecualizador procesa el audio de esta persona (unos segundos por minuto).")
                    .font(.caption2).foregroundStyle(.orange)
                Spacer()
                Button("Aplicar") { session.applyEQ(laneId: lane.id) }.controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(session.isBusy)
            }
        }
        Text("El desfase mueve el inicio de su grabación (no puede ser negativo: si va adelantada, atrasa a los demás). Los cortes se aplican igual a todas las pistas.")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }

    private func setEQ(_ i: Int, _ eq: VoiceEQ) { session.project.lanes[i].eq = eq }

    private func eqRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(value: value, in: -8...8, step: 0.5)
            Text(String(format: "%+.1f dB", value.wrappedValue)).monospacedDigit().frame(width: 60, alignment: .trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func soundBody(_ b: Binding<AudioLaneClip>, sel: ProjectSession.TrackSel) -> some View {
        let clip = b.wrappedValue
        let reel: Reel? = { if case .reelSound(let rid, _) = sel { return session.project.reels.first { $0.id == rid } }; return nil }()
        let name = session.project.mediaItem(clip.mediaId).map { (($0.originalName as NSString).deletingPathExtension) } ?? "Sonido"
        let lo = reel?.start ?? 0
        let hi = reel?.end ?? session.project.duration
        let len = clip.srcOut - clip.srcIn
        return Group {
        header((reel != nil ? "Música del reel · " : "") + "\(name) · \(EditEngine.clock(clip.tlStart))", "music.note")
        volumeRow(value: b.volume, max: 1.5)
        Toggle("Bajar sola cuando alguien habla", isOn: Binding(get: { clip.ducks }, set: { b.wrappedValue.duck = $0 }))
            .font(.callout)
        if clip.ducks {
            HStack(spacing: 8) {
                Text("Cuánto baja").frame(width: 72, alignment: .leading)
                Slider(value: b.duckDB, in: 6...24, step: 1)
                Text(String(format: "−%.0f dB", clip.duckDB)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .font(.callout)
        }
        Toggle(reel != nil ? "Repetir en bucle hasta el final del reel" : "Repetir en bucle hasta el final del episodio", isOn: b.loop)
            .font(.callout)
        fadeRow(label: "Fade entrada", value: b.fadeIn)
        fadeRow(label: "Fade salida", value: b.fadeOut)
        HStack(spacing: 6) {
            Text("Empieza").frame(width: 72, alignment: .leading)
            TimecodeField(seconds: b.tlStart, range: lo...max(lo, hi - 0.5))
            Button("Al inicio") { b.wrappedValue.tlStart = lo }
            Button("−1 s") { b.wrappedValue.tlStart = max(lo, clip.tlStart - 1) }
            Button("Aquí") { b.wrappedValue.tlStart = min(max(lo, session.playheadTimeline), max(lo, hi - 0.5)) }.help("Donde está el video ahora")
            Button("+1 s") { b.wrappedValue.tlStart = min(max(lo, hi - 0.5), clip.tlStart + 1) }
            Button("Al final") { b.wrappedValue.tlStart = max(lo, hi - max(0, len)) }
            Spacer()
            Button(role: .destructive) { session.removeSound(sel) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Quitar")
        }
        .font(.callout).controlSize(.small)
        let over = clip.tlStart + len - hi
        Text(String(format: "Dura %.0f s.", len)
             + (clip.loop ? " Se repite hasta el final y hace fade al terminar." : (over > 0.5 ? String(format: " Se corta al final (sobran %.0f s).", over) : ""))
             + (reel != nil ? " Solo suena en este reel." : " Los cortes del episodio también se aplican a la música.")
             + (reel == nil && (session.project.intro != nil || session.project.outro != nil) ? " Nunca suena dentro del intro ni del cierre: «Al inicio» es justo después del intro y «Al final» justo antes del cierre." : ""))
            .font(.caption2).foregroundStyle(Theme.secondary)
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
    var step: Step? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                if let step { HelpButton(step: step) }
            }
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
