import SwiftUI
import AVFoundation

/// Studio · Video: the viewer with the selected layer, the inspector with keyframes and the tracks (texts, b-roll,
/// cameras, lower thirds, voices and music) on top of the simple level's template. Same project, same compositor.
struct VideoStudioView: View {
    @ObservedObject var session: ProjectSession
    @State private var selectedCut: UUID?
    @State private var zoom: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                viewer
                Divider()
                VideoInspector(session: session, selectedCut: $selectedCut)
                    .frame(width: 312)
            }
            .frame(height: 440)
            Divider()
            MulticamStrip(session: session, selectedCut: $selectedCut)
            Divider()
            VideoTracks(session: session, selectedCut: $selectedCut, zoom: $zoom)
        }
    }

    // MARK: Viewer

    private var viewer: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerView(player: session.player)
                OverlayHandles(session: session)
                CaptionHandles(session: session)
                if session.built == nil {
                    VStack(spacing: 8) { ProgressView(); Text("Preparando vista previa…").font(.caption).foregroundStyle(Theme.secondary) }
                }
            }
            .padding(14)
            Divider()
            HStack(spacing: 12) {
                Text("Formato").font(.caption).foregroundStyle(Theme.secondary)
                Picker("", selection: Binding(get: { session.previewFormat == .audio ? .landscape : session.previewFormat },
                                              set: { session.setPreview(format: $0) })) {
                    Text("16:9 YouTube").tag(ExportFormat.landscape)
                    Text("9:16 Reel").tag(ExportFormat.vertical)
                    Text("1:1").tag(ExportFormat.square)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                Spacer()
                if let ps = session.proxyStatus {
                    ProgressView().controlSize(.mini)
                    Text(ps).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Toggle("Proxys", isOn: Binding(get: { ProxyStore.enabled }, set: { session.setProxies($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                    .help("Copias livianas de las grabaciones de más de 1080p para que la vista previa vaya fluida. El export usa siempre los originales.")
                Toggle("Las cámaras siguen a quien habla", isOn: $session.project.studioVideo.followSpeaker)
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                    .help("Apagado: la plantilla del proyecto queda fija; solo cambian los tramos que fijes a mano")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

// MARK: - Inspector

struct VideoInspector: View {
    @ObservedObject var session: ProjectSession
    @Binding var selectedCut: UUID?
    @State private var colorScope: Int = 0        // 0 = the whole track; otherwise, the camera id
    @State private var matchRef: Int = 0
    @State private var askTemplateName = false
    @State private var templateName = ""
    @State private var templatesTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let cid = selectedCut, let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == cid }) {
                    cutInspector(i)
                } else if case .overlay(let id) = session.selectedTrack, let i = session.project.overlays.firstIndex(where: { $0.id == id }) {
                    overlayInspector(i)
                } else if case .broll(let id) = session.selectedTrack, let i = session.project.brolls.firstIndex(where: { $0.id == id }) {
                    brollInspector(i)
                } else if case .sound(let id) = session.selectedTrack, let i = session.project.audioLane.firstIndex(where: { $0.id == id }) {
                    soundInspector(i)
                } else {
                    camerasInspector
                }
            }
            .padding(14)
        }
    }

    private func header(_ title: String, _ sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(title).font(.headline).lineLimit(1) }
            Text(sub).font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    // Layer: position, size, rotation and opacity with keyframes
    private func overlayInspector(_ i: Int) -> some View {
        let o = session.project.overlays[i]
        let t = session.playheadTimeline
        return VStack(alignment: .leading, spacing: 10) {
            header(o.title, "\(o.kind == .text ? String(localized: "Texto") : o.kind == .sticker ? String(localized: "Sticker") : String(localized: "Imagen")) · \(EditEngine.clock(o.start)) → \(EditEngine.clock(o.end))", color: VideoTracks.textColor)
            KeyParamRow(session: session, index: i, param: LayerAnimation.x, label: String(localized: "Posición X"), range: -0.5...1.5, format: { String(format: "%.2f", $0) },
                        staticValue: Binding(get: { session.project.overlays[i].x }, set: { session.project.overlays[i].x = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.y, label: String(localized: "Posición Y"), range: -0.5...1.5, format: { String(format: "%.2f", $0) },
                        staticValue: Binding(get: { session.project.overlays[i].y }, set: { session.project.overlays[i].y = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.scale, label: String(localized: "Tamaño"), range: 0.2...4, format: { String(format: "%.0f %%", $0 * 100) },
                        staticValue: Binding(get: { session.project.overlays[i].scale }, set: { session.project.overlays[i].scale = $0 }))
            KeyParamRow(session: session, index: i, param: LayerAnimation.rotation, label: String(localized: "Giro"), range: -180...180, format: { String(format: "%.0f°", $0) }, staticValue: nil, fixed: 0)
            KeyParamRow(session: session, index: i, param: LayerAnimation.opacity, label: String(localized: "Opacidad"), range: 0...1, format: { String(format: "%.0f %%", $0 * 100) }, staticValue: nil, fixed: 1)
            Divider()
            if let a = o.animation, !a.isEmpty {
                HStack {
                    Text("Curva desde este punto").font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Picker("", selection: Binding<Keyframe.Ease>(
                        get: { keyframe(at: t, in: a)?.ease ?? .smooth },
                        set: { e in setEase(e, at: t, index: i) })) {
                        ForEach(Keyframe.Ease.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 110).disabled(keyframe(at: t, in: a) == nil)
                }
                Button("Quitar toda la animación", role: .destructive) { session.project.overlays[i].animation = nil }.controlSize(.small)
            }
            motionRow(String(localized: "Entrada"), Binding(get: { session.project.overlays[i].enter }, set: { session.project.overlays[i].enter = $0 }))
            motionRow(String(localized: "Salida"), Binding(get: { session.project.overlays[i].exit }, set: { session.project.overlays[i].exit = $0 }))
            if o.enter == nil && o.exit == nil {
                Toggle("Entra y sale con fundido", isOn: $session.project.overlays[i].animate).font(.caption)
            }
            if o.kind == .text { templateMenu(i) }
            Spacer(minLength: 8)
            Text("En «Textos y stickers» esta capa dirá «Ajustado en Studio» mientras tenga keyframes. Las posiciones son fracciones del cuadro: valen igual en 16:9, 9:16 y 1:1.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Title templates: named style, color, position, size, in and out; the podcast's travel with it.
    private func templateMenu(_ i: Int) -> some View {
        let slug = session.project.episode.prepodSlug
        let ofPodcast = slug.map { TitlePresets.all(podcast: $0) } ?? []
        let mine = TitlePresets.all()
        return HStack {
            Menu {
                Button(slug != nil ? String(localized: "Guardar en el podcast como plantilla…") : String(localized: "Guardar en esta Mac como plantilla…")) { askTemplateName = true }
                if !ofPodcast.isEmpty {
                    Divider(); Text("Del podcast")
                    ForEach(ofPodcast) { t in Button(t.name) { t.apply(to: &session.project.overlays[i]) } }
                }
                if !mine.isEmpty {
                    Divider(); Text("De esta Mac")
                    ForEach(mine) { t in Button(t.name) { t.apply(to: &session.project.overlays[i]) } }
                }
                if !ofPodcast.isEmpty || !mine.isEmpty {
                    Divider()
                    Menu("Borrar una plantilla") {
                        ForEach(ofPodcast) { t in Button(t.name + String(localized: " (podcast)"), role: .destructive) { TitlePresets.remove(t.id, podcast: slug); templatesTick += 1 } }
                        ForEach(mine) { t in Button(t.name + String(localized: " (esta Mac)"), role: .destructive) { TitlePresets.remove(t.id); templatesTick += 1 } }
                    }
                }
            } label: { Label("Plantillas de título", systemImage: "square.stack").font(.caption) }
            .menuStyle(.borderlessButton).fixedSize().id(templatesTick)
            Spacer()
        }
        .alert("Nombre de la plantilla", isPresented: $askTemplateName) {
            TextField("Nombre abajo a la izquierda", text: $templateName)
            Button("Guardar") {
                let n = templateName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { TitlePresets.add(name: n, from: session.project.overlays[i], podcast: slug); templatesTick += 1 }
                templateName = ""
            }
            Button("Cancelar", role: .cancel) { templateName = "" }
        } message: { Text(slug != nil
                          ? String(localized: "Guarda el estilo, el color, la posición, el tamaño, la entrada y la salida de este texto en el podcast (no el texto ni el momento): sirve en cualquier episodio y en cualquier Mac con tu cuenta.")
                          : String(localized: "Guarda el estilo, el color, la posición, el tamaño, la entrada y la salida de este texto en esta Mac. (Este episodio no está vinculado a un podcast de prePod.)")) }
    }

    /// A layer's in or out: type and duration.
    private func motionRow(_ label: String, _ m: Binding<TitleMotion?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Picker("", selection: Binding<TitleMotion.Kind?>(
                    get: { m.wrappedValue?.kind },
                    set: { k in m.wrappedValue = k.map { TitleMotion(kind: $0, duration: m.wrappedValue?.duration ?? 0.4) } })) {
                    Text("Simple (fundido)").tag(TitleMotion.Kind?.none)
                    ForEach(TitleMotion.Kind.allCases, id: \.self) { Text($0.name).tag(TitleMotion.Kind?.some($0)) }
                }.labelsHidden().frame(width: 150)
            }
            if let cur = m.wrappedValue {
                HStack {
                    Slider(value: Binding(get: { cur.duration }, set: { m.wrappedValue?.duration = $0 }), in: 0.1...2)
                    Text(String(format: "%.1f s", cur.duration)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func keyframe(at t: Double, in a: LayerAnimation) -> Keyframe? {
        for pts in a.tracks.values { if let k = pts.first(where: { abs($0.t - t) < 0.04 }) { return k } }
        return nil
    }
    private func setEase(_ e: Keyframe.Ease, at t: Double, index i: Int) {
        guard var a = session.project.overlays[i].animation else { return }
        for (p, pts) in a.tracks {
            var v = pts
            for j in v.indices where abs(v[j].t - t) < 0.04 { v[j].ease = e }
            a.tracks[p] = v
        }
        session.project.overlays[i].animation = a
    }

    // B-roll: how it enters
    private func brollInspector(_ i: Int) -> some View {
        let b = session.project.brolls[i]
        return VStack(alignment: .leading, spacing: 10) {
            header(b.title, String(localized: "B-roll · \(EditEngine.clock(b.start)) → \(EditEngine.clock(b.end))"), color: VideoTracks.brollColor)
            HStack {
                Text("Entra con").font(.caption)
                Spacer()
                Picker("", selection: Binding<Transition.Kind?>(
                    get: { b.transitionIn?.kind },
                    set: { k in session.project.brolls[i].transitionIn = k.map { Transition(kind: $0, duration: b.transitionIn?.duration ?? 0.6) } })) {
                    Text("Fundido corto (simple)").tag(Transition.Kind?.none)
                    ForEach(Transition.Kind.allCases, id: \.self) { Text($0.name).tag(Transition.Kind?.some($0)) }
                }.labelsHidden().frame(width: 170)
            }
            if let tr = b.transitionIn, tr.kind != .cut {
                HStack {
                    Text("Duración").font(.caption)
                    Slider(value: Binding(get: { tr.duration }, set: { session.project.brolls[i].transitionIn?.duration = $0 }), in: 0.1...2)
                    Text(String(format: "%.1f s", tr.duration)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            Divider()
            Picker("Dónde", selection: $session.project.brolls[i].placement) {
                Text("Toda la pantalla").tag("full"); Text("Ventanita izquierda").tag("pipLeft"); Text("Ventanita derecha").tag("pipRight")
            }.font(.caption)
            Toggle("Llenar la pantalla (recorta)", isOn: $session.project.brolls[i].fill).font(.caption)
            if b.isVideo {
                HStack { Text("Sonido").font(.caption); Slider(value: $session.project.brolls[i].volume, in: 0...1); Text(b.volume < 0.01 ? String(localized: "mudo") : String(format: "%.0f %%", b.volume * 100)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing) }
                SpeedRow(speed: $session.project.brolls[i].speed, range: 0.25...4, note: b.speedEnd == nil
                         ? String(localized: "Cámara lenta a la izquierda, acelerado a la derecha. Ocupa los mismos segundos en pantalla; el sonido mantiene su tono.")
                         : String(localized: "Velocidad al empezar el clip; abajo, al terminar. Entre las dos, una rampa suave."))
                HStack {
                    Toggle("Rampa", isOn: Binding(get: { b.speedEnd != nil }, set: { on in session.project.brolls[i].speedEnd = on ? (b.speed == 1 ? 2 : 1) : nil })).font(.caption).toggleStyle(.checkbox)
                    if b.speedEnd != nil {
                        SpeedRow(speed: Binding(get: { b.speedEnd ?? 1 }, set: { session.project.brolls[i].speedEnd = $0 }), range: 0.25...4, note: "")
                    }
                }
            }
            Divider()
            ColorPanel(grade: $session.project.brolls[i].grade, title: String(localized: "Color de este clip"))
            Spacer(minLength: 8)
            Text("La transición actúa sobre este clip al entrar; lo de abajo (cámaras o el b-roll anterior) sigue hasta que este lo tapa.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // Music or effect clip: fades, crossfade with the neighbor
    private func soundInspector(_ i: Int) -> some View {
        let c = session.project.audioLane[i]
        let name = session.project.mediaItem(c.mediaId)?.originalName ?? String(localized: "Música")
        let next = session.project.audioLane.filter { $0.id != c.id && $0.tlStart >= c.tlStart }.min { $0.tlStart < $1.tlStart }
        return VStack(alignment: .leading, spacing: 10) {
            header(name, "\(EditEngine.clock(c.tlStart)) → \(EditEngine.clock(c.tlEnd))", color: VideoTracks.musicColor)
            HStack { Text("Entra en").font(.caption); Slider(value: $session.project.audioLane[i].fadeIn, in: 0...5); Text(String(format: "%.1f s", c.fadeIn)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing) }
            HStack { Text("Sale en").font(.caption); Slider(value: $session.project.audioLane[i].fadeOut, in: 0...5); Text(String(format: "%.1f s", c.fadeOut)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing) }
            Toggle("Fades de igual potencia (para cruzar)", isOn: $session.project.audioLane[i].crossfade).font(.caption)
            HStack { Text("Volumen").font(.caption); Slider(value: $session.project.audioLane[i].volume, in: 0...1); Text(String(format: "%.0f %%", c.volume * 100)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing) }
            SpeedRow(speed: $session.project.audioLane[i].speed, range: 0.5...2, note: String(localized: "Estira o comprime la música sin cambiar el tono: a 0,5× dura el doble, a 2× la mitad."))
            Divider()
            if let n = next {
                let overlap = c.tlEnd - n.tlStart
                if overlap > 0.05 {
                    Label(String(format: String(localized: "Cruzado con el siguiente: %.1f s"), overlap), systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(Theme.accent)
                } else {
                    Button("Cruzar con el siguiente (1,2 s)") { session.project.crossfade(c.id, with: n.id, seconds: 1.2) }.controlSize(.small)
                        .help("Adelanta el siguiente clip para que se solapen 1,2 s y pone fades curvos en los dos")
                }
            }
            Spacer(minLength: 8)
            Text("Dos clips que se solapan en la pista se cruzan solos: el que termina baja y el que empieza sube, sin hueco en el medio.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // Manual camera span
    private func cutInspector(_ i: Int) -> some View {
        let c = session.project.studioVideo.cuts[i]
        return VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "Cámara a mano"), String(localized: "\(EditEngine.clock(c.start)) → \(EditEngine.clock(c.end)) · gana sobre quien habla"), color: Theme.accent)
            Picker("En grande", selection: Binding<Int?>(get: { c.lane }, set: { session.project.studioVideo.cuts[i].lane = $0 })) {
                Text("Todas (según la plantilla)").tag(Int?.none)
                ForEach(session.project.lanes) { l in Text(session.project.laneName(l.id)).tag(Int?.some(l.id)) }
            }.font(.caption)
            Picker("Plantilla", selection: Binding<LayoutTemplate?>(get: { c.template }, set: { session.project.studioVideo.cuts[i].template = $0 })) {
                Text("La del proyecto (\(session.project.layout.title))").tag(LayoutTemplate?.none)
                ForEach(LayoutTemplate.allCases.filter { $0 != .auto }) { Text($0.title).tag(LayoutTemplate?.some($0)) }
            }.font(.caption)
            HStack {
                Text("Desde").font(.caption)
                TextField("", value: Binding(get: { c.start }, set: { session.project.studioVideo.cuts[i].start = min($0, c.end - 0.5) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("Hasta").font(.caption)
                TextField("", value: Binding(get: { c.end }, set: { session.project.studioVideo.cuts[i].end = max($0, c.start + 0.5) }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("s").font(.caption).foregroundStyle(Theme.secondary)
            }
            Button("Quitar este tramo (vuelve el automático)", role: .destructive) {
                session.project.studioVideo.cuts.remove(at: i); selectedCut = nil
            }.controlSize(.small)
            Spacer(minLength: 8)
            Text("Los tramos a mano valen también para los reels que caigan dentro.").font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    /// Per-camera or whole-track color, and matching cameras using one as reference.
    private var colorSection: some View {
        let cams = session.project.lanes.filter { session.project.laneHasVideo($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Color").font(.caption.bold())
                Spacer()
                Picker("", selection: $colorScope) {
                    Text("Toda la pista").tag(0)
                    ForEach(cams) { l in Text(session.project.laneName(l.id)).tag(l.id) }
                }.labelsHidden().frame(width: 150)
            }
            if colorScope == 0 {
                ColorPanel(grade: $session.project.grade, title: String(localized: "Toda la pista (todas las cámaras y el b-roll)"))
            } else if let li = session.project.lanes.firstIndex(where: { $0.id == colorScope }) {
                ColorPanel(grade: $session.project.lanes[li].grade, title: String(localized: "Cámara · \(session.project.laneName(colorScope))"))
                MaskPanel(session: session, laneIndex: li)
            }
            if cams.count > 1 {
                Divider()
                Text("Igualar cámaras").font(.caption.bold())
                HStack {
                    Text("Referencia").font(.caption)
                    Picker("", selection: $matchRef) {
                        ForEach(cams) { l in Text(session.project.laneName(l.id)).tag(l.id) }
                    }.labelsHidden().frame(width: 130)
                    Button("Igualar") { session.matchCameraColors(reference: matchRef == 0 ? cams.first?.id : matchRef) }
                        .controlSize(.small).disabled(session.isBusy)
                }
                Text("Compara el brillo y el balance de color del centro del cuadro de cada cámara y acerca las demás a la de referencia (exposición y ganancia por canal). Se puede retocar después en cada cámara.")
                    .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if matchRef == 0 { matchRef = cams.first?.id ?? 0 } }
    }

    // Nothing selected: how it decides the cameras
    private var camerasInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(String(localized: "Cámaras"), String(localized: "cómo se decide qué se ve"), color: EpisodeTimeline.palette[0])
            Toggle("Seguir a quien habla", isOn: $session.project.studioVideo.followSpeaker).font(.caption)
            HStack {
                Text("Permanencia mínima").font(.caption)
                Slider(value: $session.project.studioVideo.minHold, in: 0.8...8, step: 0.1).disabled(!session.project.studioVideo.followSpeaker)
                Text(String(format: "%.1f s", session.project.studioVideo.minHold)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
            Text("Con menos de este tiempo en una cámara no se cambia, para no «picar» en conversaciones rápidas.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Al cambiar").font(.caption)
                Spacer()
                Picker("", selection: Binding<Transition.Kind>(
                    get: { session.project.studioVideo.switchTransition?.kind ?? .cut },
                    set: { k in session.project.studioVideo.switchTransition = k == .cut ? nil : Transition(kind: k, duration: session.project.studioVideo.switchTransition?.duration ?? 0.2) })) {
                    Text("Corte").tag(Transition.Kind.cut)
                    Text("Fundido").tag(Transition.Kind.fade)
                    Text("Zoom suave").tag(Transition.Kind.zoom)
                }.labelsHidden().frame(width: 120)
            }
            if let tr = session.project.studioVideo.switchTransition {
                HStack {
                    Text("Duración").font(.caption)
                    Slider(value: Binding(get: { tr.duration }, set: { session.project.studioVideo.switchTransition?.duration = $0 }), in: 0.1...1)
                    Text(String(format: "%.1f s", tr.duration)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            Divider()
            colorSection
            Divider()
            Text("Clic en un clip para editarlo. En la pista Cámaras, clic derecho para fijar una cámara en ese segundo; arrastra sus bordes para alargar el tramo.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if session.project.videoTunedInStudio {
                Label("Este episodio tiene ajustes de Studio · Video", systemImage: "sparkles").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// A parameter row with its keyframe diamond: filled = there's a keyframe at this second; outlined = the parameter
/// is animated but not here; empty = still. Moving the control with the parameter animated writes a keyframe here.
struct KeyParamRow: View {
    @ObservedObject var session: ProjectSession
    let index: Int
    let param: String
    let label: String
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let staticValue: Binding<Double>?
    var fixed: Double = 0

    private var anim: LayerAnimation { session.project.overlays[index].animation ?? LayerAnimation() }
    private var t: Double { session.playheadTimeline }
    private var animated: Bool { anim.has(param) }
    private var hasKeyHere: Bool { (anim.tracks[param] ?? []).contains { abs($0.t - t) < 0.04 } }
    private var current: Double { anim.value(param, at: t) ?? staticValue?.wrappedValue ?? fixed }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                var a = anim
                if hasKeyHere, let k = (a.tracks[param] ?? []).first(where: { abs($0.t - t) < 0.04 }) { a.remove(param, id: k.id) }
                else { a.write(param, t: t, v: current) }
                session.project.overlays[index].animation = a.isEmpty ? nil : a
            } label: {
                Image(systemName: hasKeyHere ? "diamond.fill" : "diamond").font(.caption).foregroundStyle(animated ? Theme.accent : Theme.secondary)
            }
            .buttonStyle(.plain).frame(width: 18)
            .help(hasKeyHere ? String(localized: "Quitar el keyframe de este segundo") : String(localized: "Poner un keyframe aquí con el valor actual"))
            Text(label).font(.caption).frame(width: 72, alignment: .leading)
            Slider(value: Binding(get: { current }, set: { v in
                if animated {
                    var a = anim; a.write(param, t: t, v: v); session.project.overlays[index].animation = a
                } else if let s = staticValue { s.wrappedValue = v }
                else { var a = anim; a.write(param, t: t, v: v); session.project.overlays[index].animation = a }
            }), in: range)
            Text(format(current)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
        }
    }
}

// MARK: - Tracks

struct VideoTracks: View {
    @ObservedObject var session: ProjectSession
    @Binding var selectedCut: UUID?
    @Binding var zoom: Double
    @State private var dragStart: Double?

    static let textColor = Color(red: 0.85, green: 0.64, blue: 1)
    static let brollColor = Theme.accent
    static let cintilloColor = Color(red: 1, green: 0.72, blue: 0.42)
    static let musicColor = Color(red: 0.08, green: 0.72, blue: 0.65)
    private let labelW: CGFloat = 170

    private var duration: Double { max(1, session.project.duration) }

    @State private var viewportW: CGFloat = 1200
    /// Beat snap: the episode music's beats (episode time) and whether to snap to them
    @State private var beats: [Double] = []
    @State private var beatSnap = true
    @State private var bpmLabel = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { outer in
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    ruler
                    track(String(localized: "Textos y stickers"), color: Self.textColor, height: 56) { w in overlaysRow(w) }
                    track(String(localized: "B-roll e imágenes"), color: Self.brollColor, height: 56) { w in brollsRow(w) }
                    track(String(localized: "Cámaras"), color: EpisodeTimeline.palette[0], height: 56, sub: session.project.studioVideo.followSpeaker ? String(localized: "sigue a quien habla") : String(localized: "plantilla fija")) { w in camerasRow(w) }
                    track(String(localized: "Cintillos y marcas"), color: Self.cintilloColor, height: 40) { w in cintillosRow(w) }
                    track(String(localized: "Voces"), color: EpisodeTimeline.palette[0], height: 36, sub: String(localized: "\(session.project.lanes.count) · pestaña Audio")) { w in vocesRow(w) }
                    track(String(localized: "Música y efectos"), color: Self.musicColor, height: 44) { w in musicRow(w) }
                    if case .overlay(let id) = session.selectedTrack, let i = session.project.overlays.firstIndex(where: { $0.id == id }),
                       let a = session.project.overlays[i].animation, !a.isEmpty {
                        ForEach(LayerAnimation.params.filter { a.has($0) }, id: \.self) { p in
                            track("  ◆ \(VideoTracks.paramName(p))", color: Theme.accent, height: 44, sub: String(localized: "\(a.tracks[p]?.count ?? 0) puntos")) { w in
                                KeyframeStrip(session: session, overlayIndex: i, param: p, width: w, beats: beatSnap ? beats : [])
                            }
                        }
                    }
                }
                .frame(width: labelW + timelineWidth)
            }
            .onAppear { viewportW = outer.size.width }
            .onChange(of: outer.size.width) { _, w in viewportW = w }
            }
        }
        .task(id: session.project.audioLane.map { "\($0.id):\($0.mediaId):\($0.tlStart):\($0.srcIn):\($0.srcOut)" }.joined(separator: "|")) {
            let p = session.project
            let (b, label) = await Task.detached(priority: .utility) { () -> ([Double], String) in
                let bs = BeatGrid.episodeBeats(project: p)
                let bpms = Set(p.audioLane.compactMap { BeatGrid.load(project: p, mediaId: $0.mediaId)?.bpm }.filter { $0 > 0 })
                return (bs, bpms.isEmpty ? "" : bpms.sorted().map { String(format: "%.0f", $0) }.joined(separator: " · ") + " BPM")
            }.value
            beats = b; bpmLabel = label
        }
    }

    /// Seconds covered by 8 px at the current scale: the snap tolerance.
    private var snapTolerance: Double { 8 / Double(timelineWidth) * duration }
    /// The time snapped to the nearest beat if snapping is on.
    private func snapped(_ t: Double) -> Double {
        guard beatSnap, !beats.isEmpty else { return t }
        return BeatGrid.snap(t, to: beats, tolerance: snapTolerance) ?? t
    }

    static func paramName(_ p: String) -> String {
        switch p {
        case LayerAnimation.x: return String(localized: "Posición X"); case LayerAnimation.y: return String(localized: "Posición Y"); case LayerAnimation.scale: return String(localized: "Tamaño")
        case LayerAnimation.rotation: return String(localized: "Giro"); case LayerAnimation.opacity: return String(localized: "Opacidad"); default: return p
        }
    }

    /// Zoom 1 = the whole episode fits in the window; each zoom step stretches it.
    private var timelineWidth: CGFloat { max(300, viewportW - labelW) * zoom }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("+ Texto") { _ = session.addOverlay(kind: .text, text: String(localized: "Título")) }
            Button("+ Sticker") { _ = session.addOverlay(kind: .sticker, text: "✦") }
            Button("+ Imagen…") { session.chooseOverlayImage() }
            Button("+ B-roll…") { session.chooseBRoll() }
            Spacer()
            if !beats.isEmpty {
                Toggle(isOn: $beatSnap) { Label("Imán al ritmo", systemImage: "metronome") }.toggleStyle(.button)
                    .help("Al arrastrar, los clips, los keyframes y los cortes de cámara se enganchan al golpe de la música más cercano (\(bpmLabel))")
                Text(bpmLabel).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Text("Clic: ir ahí · arrastra un clip para moverlo · clic derecho en Cámaras: fijar").font(.caption).foregroundStyle(Theme.secondary)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondary)
            Slider(value: $zoom, in: 1...30).frame(width: 110)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelW, height: 20)
            GeometryReader { g in
                let w = g.size.width
                let pxPerSec = w / duration
                let step: Double = pxPerSec > 20 ? 5 : pxPerSec > 8 ? 15 : pxPerSec > 3 ? 30 : pxPerSec > 1 ? 60 : pxPerSec > 0.4 ? 300 : 600
                ZStack(alignment: .topLeading) {
                    // Music beats: thin marks (only when distinguishable)
                    if !beats.isEmpty, w / CGFloat(duration) * 0.4 > 2 {
                        Path { p in for b in beats { let x = CGFloat(b / duration) * w; p.move(to: CGPoint(x: x, y: 14)); p.addLine(to: CGPoint(x: x, y: 20)) } }
                            .stroke(VideoTracks.musicColor.opacity(beatSnap ? 0.9 : 0.4), lineWidth: 1)
                    }
                    ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { t in
                        Text(EditEngine.clock(t)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
                            .offset(x: CGFloat(t / duration) * w + 3, y: 3)
                    }
                }
            }
            .frame(height: 20)
        }
        .background(Theme.panel)
    }

    private func track<Content: View>(_ name: String, color: Color, height: CGFloat, sub: String? = nil, @ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(name).font(.caption.bold()).lineLimit(1) }
                if let sub { Text(sub).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1) }
            }
            .frame(width: labelW, alignment: .leading).padding(.horizontal, 10)
            .frame(height: height).background(Theme.panel)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black.opacity(0.25))
                    content(g.size.width)
                    playhead(g.size.width, height: height)
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in session.seek(timeline: Double(loc.x / g.size.width) * duration, play: false) }
            }
            .frame(height: height)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func playhead(_ w: CGFloat, height: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Rectangle().fill(Theme.accent).frame(width: 1, height: height).offset(x: x(session.playheadTimeline, w))
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / duration) * w }

    /// A draggable clip (moves the start) with a handle on the right (changes the duration).
    private func clip(_ title: String, start: Double, dur: Double, color: Color, selected: Bool, w: CGFloat, height: CGFloat = 36, dashed: Bool = false,
                      onSelect: @escaping () -> Void, onMove: @escaping (Double) -> Void, onResize: ((Double) -> Void)? = nil) -> some View {
        let width = max(6, x(dur, w))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(selected ? 0.35 : 0.2))
            RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.accent : color.opacity(0.6), style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: dashed ? [4, 3] : []))
            Text(title).font(.caption2).lineLimit(1).padding(.horizontal, 6)
            if let onResize {
                HStack { Spacer(); Rectangle().fill(Color.clear).frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in onResize(max(0.3, dur + Double(v.translation.width / w) * duration)) })
                    .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } } }
            }
        }
        .frame(width: width, height: height)
        .offset(x: x(start, w), y: 10)
        .onTapGesture { onSelect() }
        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
            if dragStart == nil { dragStart = start; onSelect() }
            onMove(snapped(max(0, min(duration - dur, (dragStart ?? start) + Double(v.translation.width / w) * duration))))
        }.onEnded { _ in dragStart = nil })
    }

    private func overlaysRow(_ w: CGFloat) -> some View {
        ForEach(session.project.overlays) { o in
            let sel: Bool = { if case .overlay(let id) = session.selectedTrack { return id == o.id }; return false }()
            clip(o.title + (o.tunedInStudio ? " ◆" : ""), start: o.start, dur: o.duration, color: Self.textColor, selected: sel, w: w,
                 onSelect: { session.selectedTrack = .overlay(o.id); selectedCut = nil },
                 onMove: { t in if let i = session.project.overlays.firstIndex(where: { $0.id == o.id }) { session.project.overlays[i].start = t } },
                 onResize: { d in if let i = session.project.overlays.firstIndex(where: { $0.id == o.id }) { session.project.overlays[i].duration = d } })
            .contextMenu { Button("Quitar", role: .destructive) { session.removeOverlay(o.id) } }
        }
    }

    private func brollsRow(_ w: CGFloat) -> some View {
        ForEach(session.project.brolls) { b in
            let sel: Bool = { if case .broll(let id) = session.selectedTrack { return id == b.id }; return false }()
            clip(b.title + (b.speed != 1 ? String(format: " · %.2g×", b.speed) : "") + (b.transitionIn.map { " · \($0.kind.name)" } ?? ""), start: b.start, dur: b.duration, color: Self.brollColor, selected: sel, w: w,
                 onSelect: { session.selectedTrack = .broll(b.id); selectedCut = nil },
                 onMove: { t in if let i = session.project.brolls.firstIndex(where: { $0.id == b.id }) { session.project.brolls[i].start = t } },
                 onResize: { d in if let i = session.project.brolls.firstIndex(where: { $0.id == b.id }) { session.project.brolls[i].duration = min(BRollClip.maxSeconds, d) } })
            .contextMenu { Button("Quitar", role: .destructive) { session.removeBRoll(b.id) } }
        }
    }

    /// Cameras: automatic switches (dimmed) and manual spans (dashed border, draggable).
    private func camerasRow(_ w: CGFloat) -> some View {
        let auto = autoBlocks()
        return Group {
            // Background with the menu to pin a camera at the current second
            Rectangle().fill(Color.clear).frame(width: w, height: 56).contentShape(Rectangle())
                .contextMenu {
                    Section("Fijar cámara en \(EditEngine.clock(session.playheadTimeline))") {
                        ForEach(session.project.lanes) { l in Button(session.project.laneName(l.id)) { addCut(lane: l.id, template: nil) } }
                        Divider()
                        ForEach(LayoutTemplate.allCases.filter { $0 != .auto }) { t in Button("Todas · \(t.title)") { addCut(lane: nil, template: t) } }
                    }
                }
            ForEach(Array(auto.enumerated()), id: \.offset) { _, b in
                let i = session.project.lanes.firstIndex { $0.id == b.lane } ?? 0
                RoundedRectangle(cornerRadius: 4).fill(EpisodeTimeline.palette[i % EpisodeTimeline.palette.count].opacity(0.22))
                    .overlay(Text(session.project.laneName(b.lane)).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(2, x(b.end - b.start, w)), height: 36).offset(x: x(b.start, w), y: 10)
                    .allowsHitTesting(false)
            }
            ForEach(session.project.studioVideo.cuts) { c in
                let name = c.lane.map { session.project.laneName($0) } ?? (c.template?.title ?? String(localized: "Todas"))
                clip(name + (c.template != nil && c.lane != nil ? " · \(c.template!.title)" : ""), start: c.start, dur: c.end - c.start, color: Theme.accent,
                     selected: selectedCut == c.id, w: w, dashed: true,
                     onSelect: { selectedCut = c.id; session.selectedTrack = nil },
                     onMove: { t in if let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == c.id }) { let d = c.end - c.start; session.project.studioVideo.cuts[i].start = t; session.project.studioVideo.cuts[i].end = t + d } },
                     onResize: { d in if let i = session.project.studioVideo.cuts.firstIndex(where: { $0.id == c.id }) { session.project.studioVideo.cuts[i].end = c.start + d } })
                .contextMenu { Button("Quitar (vuelve el automático)", role: .destructive) { session.project.studioVideo.cuts.removeAll { $0.id == c.id }; if selectedCut == c.id { selectedCut = nil } } }
            }
        }
    }

    private func addCut(lane: Int?, template: LayoutTemplate?) {
        let t = session.playheadTimeline
        let next = session.project.studioVideo.cuts.map(\.start).filter { $0 > t }.min() ?? duration
        let end = min(next, t + max(3, session.project.studioVideo.minHold * 2), duration)
        let c = CameraCut(start: t, end: end, lane: lane, template: template)
        session.project.studioVideo.cuts.append(c)
        session.project.studioVideo.cuts.sort { $0.start < $1.start }
        selectedCut = c.id; session.selectedTrack = nil
    }

    /// Automatic camera switches, in episode time (from the built preview).
    private func autoBlocks() -> [(start: Double, end: Double, lane: Int)] {
        guard let b = session.built, let sc = b.scene else {
            // No preview yet: a single camera (the first) across the episode
            return session.project.lanes.first.map { [(0, duration, $0.id)] } ?? []
        }
        let sw = sc.switches
        var out: [(Double, Double, Int)] = []
        for (i, s) in sw.enumerated() {
            let a = EditEngine.toTimeline(s.time, keep: b.keep)
            let z = i + 1 < sw.count ? EditEngine.toTimeline(sw[i + 1].time, keep: b.keep) : duration
            if z > a { out.append((a, z, s.lane)) }
        }
        return out
    }

    private func cintillosRow(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.project.cintillos) { c in
                RoundedRectangle(cornerRadius: 4).fill(Self.cintilloColor.opacity(0.2)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.cintilloColor.opacity(0.6)))
                    .overlay(Text(c.title).font(.caption2).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(4, x(c.duration, w)), height: 24).offset(x: x(c.start, w), y: 8)
                    .onTapGesture { session.selectedTrack = .cintillo(c.id); selectedCut = nil }
            }
            ForEach(Array(session.project.sponsorAppearances().enumerated()), id: \.offset) { _, a in
                RoundedRectangle(cornerRadius: 4).fill(Self.cintilloColor.opacity(0.12)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.cintilloColor.opacity(0.4), style: StrokeStyle(dash: [3, 2])))
                    .overlay(Text("Sponsor · \(a.sponsor.name)").font(.caption2).lineLimit(1).padding(.horizontal, 4), alignment: .leading)
                    .frame(width: max(4, x(a.end - a.start, w)), height: 24).offset(x: x(a.start, w), y: 8)
            }
        }
    }

    private func vocesRow(_ w: CGFloat) -> some View {
        HStack {
            Text("Las voces se mezclan en la pestaña Audio (⌘E): consola, cadena de cada persona, automatización.")
                .font(.caption2).foregroundStyle(Theme.secondary).padding(.horizontal, 8)
            Spacer()
        }
        .frame(width: w, height: 36)
    }

    private func musicRow(_ w: CGFloat) -> some View {
        ForEach(session.project.audioLane) { c in
            let name = session.project.mediaItem(c.mediaId)?.originalName ?? String(localized: "Música")
            let sel: Bool = { if case .sound(let id) = session.selectedTrack { return id == c.id }; return false }()
            clip(name + (c.speed != 1 ? String(format: " · %.2g×", c.speed) : "") + (c.crossfade ? " · ✕" : c.fadeIn > 0 || c.fadeOut > 0 ? String(localized: " · fades") : ""), start: c.tlStart, dur: c.length, color: Self.musicColor, selected: sel, w: w, height: 28,
                 onSelect: { session.selectedTrack = .sound(c.id); selectedCut = nil },
                 onMove: { t in
                     if let i = session.project.audioLane.firstIndex(where: { $0.id == c.id }) {
                         session.project.audioLane[i].tlStart = t
                         session.project.crossfadeOverlaps(touching: c.id)
                     }
                 })
        }
    }
}

/// Keyframe lane of a layer parameter: drag a diamond (time and value), double-click removes it.
struct KeyframeStrip: View {
    @ObservedObject var session: ProjectSession
    let overlayIndex: Int
    let param: String
    let width: CGFloat
    var beats: [Double] = []
    @State private var dragging: UUID?
    private let h: CGFloat = 44

    private var duration: Double { max(1, session.project.duration) }
    private var points: [Keyframe] { (session.project.overlays[overlayIndex].animation?.tracks[param] ?? []).sorted { $0.t < $1.t } }
    private var range: ClosedRange<Double> {
        switch param {
        case LayerAnimation.scale: return 0.2...4
        case LayerAnimation.rotation: return -180...180
        case LayerAnimation.opacity: return 0...1
        default: return -0.5...1.5
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                guard let f = points.first else { return }
                p.move(to: CGPoint(x: 0, y: y(f.v)))
                for pt in points { p.addLine(to: CGPoint(x: x(pt.t), y: y(pt.v))) }
                p.addLine(to: CGPoint(x: width, y: y(points.last!.v)))
            }
            .stroke(Theme.accent.opacity(0.8), lineWidth: 1.2)
            ForEach(points) { pt in
                Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(dragging == pt.id ? Color.white : Theme.accent)
                    .position(x: x(pt.t), y: y(pt.v))
                    .help("\(EditEngine.clock(pt.t)) · \(VideoTracks.paramName(param)) \(String(format: "%.2f", pt.v)) · \(pt.ease.name)")
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        dragging = pt.id
                        var t = max(0, min(duration, Double(v.location.x / width) * duration))
                        if let b = BeatGrid.snap(t, to: beats, tolerance: 8 / Double(width) * duration) { t = b }
                        let val = value(forY: v.location.y)
                        update { pts in if let i = pts.firstIndex(where: { $0.id == pt.id }) { pts[i].t = t; pts[i].v = val } }
                    }.onEnded { _ in dragging = nil })
                    .onTapGesture(count: 2) { update { pts in pts.removeAll { $0.id == pt.id } } }
            }
        }
        .frame(width: width, height: h)
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
    private func y(_ v: Double) -> CGFloat {
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return h - 6 - CGFloat(max(0, min(1, f))) * (h - 12)
    }
    private func value(forY py: CGFloat) -> Double {
        let f = Double((h - 6 - py) / (h - 12))
        return range.lowerBound + max(0, min(1, f)) * (range.upperBound - range.lowerBound)
    }
    private func update(_ f: (inout [Keyframe]) -> Void) {
        var a = session.project.overlays[overlayIndex].animation ?? LayerAnimation()
        var pts = a.tracks[param] ?? []
        f(&pts)
        a.tracks[param] = pts.isEmpty ? nil : pts.sorted { $0.t < $1.t }
        session.project.overlays[overlayIndex].animation = a.isEmpty ? nil : a
    }
}


/// A clip's speed (b-roll or music), with detents at the usual values and back to 1× with a click.
struct SpeedRow: View {
    @Binding var speed: Double
    let range: ClosedRange<Double>
    let note: String
    private static let stops: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Velocidad").font(.caption)
                Slider(value: Binding(get: { log2(speed) }, set: { v in
                    let raw = pow(2, v)
                    speed = Self.stops.first { abs($0 - raw) < 0.04 } ?? (raw * 100).rounded() / 100
                }), in: log2(range.lowerBound)...log2(range.upperBound))
                Button(String(format: "%.2g×", speed)) { speed = 1 }
                    .buttonStyle(.plain).font(.caption.monospacedDigit().bold()).frame(width: 44, alignment: .trailing)
                    .foregroundStyle(speed == 1 ? Theme.secondary : Theme.accent).help("Volver a velocidad normal")
            }
            Text(note).font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// A camera's mask: shape, position, size, feather; the camera color goes only inside, and outside it
/// can be darkened. Follows motion with position and size keyframes set by hand.
struct MaskPanel: View {
    @ObservedObject var session: ProjectSession
    let laneIndex: Int

    private var m: ShapeMask { session.project.lanes[laneIndex].mask ?? ShapeMask() }
    private func set(_ f: (inout ShapeMask) -> Void) { var v = m; f(&v); session.project.lanes[laneIndex].mask = v }
    private var t: Double { session.playheadTimeline }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Máscara", isOn: Binding(get: { session.project.lanes[laneIndex].mask != nil },
                                                set: { on in session.project.lanes[laneIndex].mask = on ? ShapeMask() : nil })).font(.caption.bold()).toggleStyle(.checkbox)
                Spacer()
                if session.project.lanes[laneIndex].mask != nil {
                    Picker("", selection: Binding(get: { m.shape }, set: { v in set { $0.shape = v } })) {
                        ForEach(ShapeMask.Shape.allCases, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
            }
            if session.project.lanes[laneIndex].mask != nil {
                keyRow(String(localized: "Centro X"), LayerAnimation.x, value: m.x, range: 0...1) { v in set { $0.x = v } }
                keyRow(String(localized: "Centro Y"), LayerAnimation.y, value: m.y, range: 0...1) { v in set { $0.y = v } }
                keyRow(String(localized: "Tamaño"), LayerAnimation.scale, value: 1, range: 0.3...2.5, fixed: true) { _ in }
                row(String(localized: "Ancho"), value: Binding(get: { m.w }, set: { v in set { $0.w = v } }), range: 0.1...1, fmt: { String(format: "%.0f %%", $0 * 100) })
                row(String(localized: "Alto"), value: Binding(get: { m.h }, set: { v in set { $0.h = v } }), range: 0.1...1, fmt: { String(format: "%.0f %%", $0 * 100) })
                row(String(localized: "Suavizado"), value: Binding(get: { m.feather }, set: { v in set { $0.feather = v } }), range: 0...120, fmt: { String(format: "%.0f px", $0) })
                row(String(localized: "Oscurecer fuera"), value: Binding(get: { m.dimOutside }, set: { v in set { $0.dimOutside = v } }), range: 0...1, fmt: { String(format: "%.0f %%", $0 * 100) })
                Toggle("Invertir (el color va fuera)", isOn: Binding(get: { m.invert }, set: { v in set { $0.invert = v } })).font(.caption)
                if let a = m.animation, !a.isEmpty {
                    Button("Quitar el seguimiento (keyframes)") { set { $0.animation = nil } }.controlSize(.mini)
                }
                Text("El color de esta cámara se aplica dentro de la máscara. Para que siga a la persona, mueve el centro en distintos segundos: cada cambio deja un keyframe (rombo lleno) y entre dos se interpola.")
                    .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Keyframe diamond row: moving the control with the track animated (or with ⌥) writes a keyframe at this second.
    private func keyRow(_ label: String, _ param: String, value: Double, range: ClosedRange<Double>, fixed: Bool = false, set staticSet: @escaping (Double) -> Void) -> some View {
        let anim = m.animation ?? LayerAnimation()
        let animated = anim.has(param)
        let hasKey = (anim.tracks[param] ?? []).contains { abs($0.t - t) < 0.04 }
        let current = anim.value(param, at: t) ?? value
        return HStack(spacing: 6) {
            Button {
                var a = anim
                if hasKey, let k = (a.tracks[param] ?? []).first(where: { abs($0.t - t) < 0.04 }) { a.remove(param, id: k.id) } else { a.write(param, t: t, v: current) }
                set { $0.animation = a.isEmpty ? nil : a }
            } label: { Image(systemName: hasKey ? "diamond.fill" : animated ? "diamond" : "diamond").foregroundStyle(hasKey || animated ? Theme.accent : Theme.secondary).font(.caption) }
            .buttonStyle(.plain).help(hasKey ? String(localized: "Quitar el keyframe de aquí") : String(localized: "Poner un keyframe aquí"))
            Text(label).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { current }, set: { v in
                if animated || fixed { var a = anim; a.write(param, t: t, v: v); set { $0.animation = a } } else { staticSet(v) }
            }), in: range)
            Text(String(format: "%.2f", current)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }
    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 94, alignment: .leading)
            Slider(value: value, in: range)
            Text(fmt(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
    }
}
