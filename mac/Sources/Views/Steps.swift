import SwiftUI

// MARK: - 1. Overview

struct OverviewStep: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StepHeader(title: "Tu grabación", subtitle: "Revisa que estén todas las personas y ponle nombre a cada una. Los nombres salen en el video.")
                    Card {
                        TextField("Nombre del episodio", text: $session.project.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                        if let podcast = session.project.podcastName {
                            Text("Podcast: \(podcast)").foregroundStyle(Theme.secondary)
                        }
                        if let d = session.project.episode.description, !d.isEmpty {
                            Text(d).font(.callout).foregroundStyle(Theme.secondary).lineLimit(4)
                        }
                    }
                    if !session.project.episode.script.isEmpty || !session.project.segments.isEmpty {
                        ScriptCard(project: session.project) { t in session.seek(timeline: t) }
                    }
                    if !session.project.sponsors.isEmpty {
                        Card {
                            Text("Sponsors del episodio").font(.headline)
                            ForEach(session.project.sponsorAppearances(), id: \.start) { a in
                                HStack {
                                    Image(systemName: "megaphone.fill").foregroundStyle(Theme.accent)
                                    Text(a.sponsor.name).bold()
                                    if let c = a.sponsor.copy { Text(c).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1) }
                                    Spacer()
                                    Button(EditEngine.clock(a.start)) { session.seek(timeline: a.start) }.buttonStyle(.link).monospacedDigit()
                                }
                            }
                            Text("Aparecen en el video en el momento del bloque del guion. Puedes apagarlos al exportar.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        Text("Personas en la grabación").font(.headline)
                        ForEach(session.project.lanes) { lane in
                            HStack(spacing: 12) {
                                Image(systemName: hasVideo(lane) ? "video.fill" : "mic.fill")
                                    .frame(width: 26)
                                    .foregroundStyle(Theme.accent)
                                TextField("Nombre", text: nameBinding(lane.id))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 260)
                                TextField("@usuario (opcional)", text: handleBinding(lane.id))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 200)
                                Spacer()
                                Text(EditEngine.clock(lane.duration)).monospacedDigit().foregroundStyle(Theme.secondary)
                            }
                        }
                        if !session.project.audioLane.isEmpty {
                            Label("\(session.project.audioLane.count) efectos de sonido / música del soundboard", systemImage: "music.note")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        Text("Qué sigue").font(.headline)
                        checklist("Grabación importada", done: true)
                        checklist("Audio mejorado, silencios y muletillas fuera", done: session.project.fix.lastRun != nil)
                        checklist("Transcripción para subtítulos", done: session.project.isTranscribed)
                        checklist("Reels creados", done: session.project.reels.contains { $0.exportedFile != nil })
                        BigButton(title: session.project.fix.lastRun == nil ? "Siguiente: arreglar el episodio" : "Ir a subtítulos",
                                  symbol: "arrow.right") {
                            session.step = session.project.fix.lastRun == nil ? .fix : .captions
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 420, maxWidth: 560)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { session.setPreview(format: .landscape) }
    }

    private func hasVideo(_ lane: Lane) -> Bool {
        lane.clips.contains { session.project.mediaItem($0.mediaId)?.hasVideo == true }
    }

    private func checklist(_ text: String, done: Bool) -> some View {
        Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Theme.good : Theme.secondary)
    }

    private func nameBinding(_ laneId: Int) -> Binding<String> {
        Binding(get: { session.project.laneName(laneId) }, set: { newValue in
            var p = session.project
            guard let li = p.lanes.firstIndex(where: { $0.id == laneId }) else { return }
            if let pid = p.lanes[li].participantId, let pi = p.participants.firstIndex(where: { $0.id == pid }) {
                p.participants[pi].name = newValue
            } else {
                p.lanes[li].name = newValue
            }
            session.project = p
        })
    }

    private func handleBinding(_ laneId: Int) -> Binding<String> {
        Binding(get: { session.project.participant(forLane: laneId)?.instagram ?? "" }, set: { newValue in
            var p = session.project
            guard let li = p.lanes.firstIndex(where: { $0.id == laneId }) else { return }
            if let pid = p.lanes[li].participantId, let pi = p.participants.firstIndex(where: { $0.id == pid }) {
                p.participants[pi].instagram = newValue
            } else {
                let id = (p.participants.map(\.id).max() ?? 0) + 1
                p.participants.append(Participant(id: id, name: p.lanes[li].name, track: laneId, instagram: newValue))
                p.lanes[li].participantId = id
            }
            session.project = p
        })
    }
}

struct ScriptCard: View {
    let project: Project
    let seek: (Double) -> Void
    @State private var expanded = false

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(project.segments.sorted { $0.position < $1.position }) { seg in
                        HStack(alignment: .top) {
                            Image(systemName: seg.sponsorId != nil ? "megaphone" : "text.alignleft")
                                .foregroundStyle(Theme.accent).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(seg.title.isEmpty ? seg.kind.capitalized : seg.title).bold()
                                if let n = seg.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(Theme.secondary) }
                            }
                            Spacer()
                            if let t = seg.actualOffset {
                                Button(EditEngine.clock(t)) { seek(t) }.buttonStyle(.link).monospacedDigit()
                            } else if let d = seg.durationEstimate {
                                Text("~\(Int(d / 60)) min").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    ForEach(project.episode.script) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            if !item.title.isEmpty { Text(item.title).bold() }
                            if !item.text.isEmpty { Text(item.text).font(.callout).foregroundStyle(Theme.secondary).textSelection(.enabled) }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Guion de prePod", systemImage: "doc.text").font(.headline)
            }
        }
    }
}

// MARK: - 2. Fix

struct FixStep: View {
    @ObservedObject var session: ProjectSession
    @State private var showCuts = false

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Arreglar todo", subtitle: "Un botón: sonido de estudio, sin silencios largos y sin “eeeh”. Nada se borra de verdad: puedes deshacer cuando quieras.")
                    Card {
                        Toggle(isOn: $session.project.fix.enhanceAudio) {
                            VStack(alignment: .leading) {
                                Text("Sonido de estudio").font(.headline)
                                Text("Quita ruido de fondo, iguala volúmenes y le da presencia a la voz").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        if session.project.fix.enhanceAudio {
                            Picker("Ruido de fondo", selection: $session.project.fix.strongNoise) {
                                Text("Suave (ventilador, siseo)").tag(false)
                                Text("Fuerte, con red neuronal (perro, teclas, calle)").tag(true)
                            }
                            .pickerStyle(.radioGroup).font(.caption)
                            if session.project.fix.strongNoise && FFmpeg.strongSpeechChain == nil {
                                Text("Falta el modelo de ruido en esta instalación; se usará el modo suave.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Divider()
                        Toggle(isOn: $session.project.fix.gateOthers) {
                            VStack(alignment: .leading) {
                                Text("Silenciar a quien no habla").font(.headline)
                                Text("Baja 18 dB la pista de quien no está hablando: teclas, perro o ruidos del otro desaparecen. Se aplica en la vista previa y al exportar.").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        .disabled(session.project.lanes.count < 2)
                        Divider()
                        Toggle(isOn: $session.project.fix.removeSilences) {
                            VStack(alignment: .leading) {
                                Text("Quitar silencios").font(.headline)
                                Text("Pausas largas donde nadie habla").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        if session.project.fix.removeSilences {
                            HStack {
                                Text("Suave").font(.caption)
                                Slider(value: Binding(get: { 2.0 - session.project.fix.minSilence },
                                                      set: { session.project.fix.minSilence = 2.0 - $0 }), in: 0.5...1.6)
                                Text("Dinámico").font(.caption)
                            }
                            Text("Cortamos pausas de más de \(String(format: "%.1f", session.project.fix.minSilence)) segundos")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        Divider()
                        Toggle(isOn: $session.project.fix.removeFillers) {
                            VStack(alignment: .leading) {
                                Text("Quitar muletillas").font(.headline)
                                Text("“eh”, “emm”, “mmm”…").font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        if session.project.fix.removeFillers {
                            Toggle("También “este”, “o sea”, “pues”, “bueno” (revisa el resultado)", isOn: $session.project.fix.removeWordFillers)
                                .font(.caption)
                        }
                    }
                    BigButton(title: session.project.fix.lastRun == nil ? "Arreglar todo" : "Volver a arreglar",
                              symbol: "wand.and.stars", disabled: session.isBusy) {
                        session.fixEverything()
                    }
                    if !session.project.isTranscribed && session.project.fix.lastRun == nil {
                        Text("La primera vez también escribimos la transcripción (se hace en tu Mac, sin internet, tarda unos minutos).")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    if let summary = session.fixSummary {
                        Card {
                            Label(summary, systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
                            HStack {
                                Button("Siguiente: subtítulos") { session.step = .captions }.buttonStyle(.borderedProminent)
                                Button("Deshacer cortes") { session.undoFix() }
                            }
                        }
                    }
                    Text("Para quitar un trozo a mano: arrástralo en la línea de tiempo de abajo y pulsa “Cortar este trozo”. Lo ves en la lista de cortes y puedes desactivarlo. Para el volumen, los fades o el desfase de una persona, toca su nombre en el timeline.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    if !session.project.cuts.isEmpty {
                        DisclosureGroup("Ver los \(session.project.cuts.count) cortes (\(EditEngine.clock(session.project.enabledCuts.reduce(0) { $0 + $1.length })) en total)",
                                        isExpanded: $showCuts) {
                            CutList(session: session)
                        }
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 420, maxWidth: 520)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { session.setPreview(format: .landscape) }
    }
}

struct CutList: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(session.project.cuts.sorted { $0.start < $1.start }) { cut in
                HStack {
                    Toggle("", isOn: binding(cut.id)).labelsHidden()
                    Image(systemName: icon(cut.kind)).foregroundStyle(Theme.secondary).frame(width: 18)
                    Button(EditEngine.clock(cut.start)) { session.seek(timeline: max(0, cut.start - 2)) }
                        .buttonStyle(.link).monospacedDigit()
                    Text(cut.label.isEmpty ? String(format: "%.1f s", cut.length) : cut.label)
                        .lineLimit(1).foregroundStyle(cut.enabled ? .primary : Theme.secondary)
                    Spacer()
                    Text(String(format: "%.1f s", cut.length)).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.top, 6)
    }
    private func icon(_ k: Cut.Kind) -> String {
        switch k {
        case .silence: return "speaker.slash"
        case .filler: return "text.bubble"
        case .manual: return "scissors"
        case .imported: return "arrow.down.doc"
        }
    }
    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { session.project.cuts.first { $0.id == id }?.enabled ?? false },
                set: { v in if let i = session.project.cuts.firstIndex(where: { $0.id == id }) { session.project.cuts[i].enabled = v } })
    }
}

// MARK: - 3. Captions

struct CaptionsStep: View {
    @ObservedObject var session: ProjectSession
    @State private var editing: Int?
    @State private var draft = ""
    @State private var filter = ""

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(title: "Subtítulos", subtitle: "Elige un estilo y corrige lo que haga falta. Toca una frase para oírla.")
                    HStack(spacing: 8) {
                        Button { session.saveSubtitles(asText: false) } label: { Label("Guardar subtítulos (.srt)", systemImage: "square.and.arrow.down") }
                        Button { session.saveSubtitles(asText: true) } label: { Label("Guardar transcripción (.txt)", systemImage: "doc.text") }
                        Spacer()
                    }
                    .disabled(!session.project.isTranscribed)
                    .controlSize(.small)
                if !session.project.isTranscribed {
                    Card {
                        Text("Todavía no hay transcripción.").font(.headline)
                        Text("La escribimos en tu Mac con inteligencia artificial, sin subir nada a internet.").foregroundStyle(Theme.secondary)
                        BigButton(title: "Escribir transcripción", symbol: "text.bubble", disabled: session.isBusy) { session.transcribe() }
                    }
                } else {
                    styleCard
                    phraseList
                }
            }
            .padding(.leading, 28).padding(.vertical, 28)
            .frame(minWidth: 460, maxWidth: 580)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { session.setPreview(format: .vertical) }
    }

    private var styleCard: some View {
        Card {
            HStack {
                Toggle("Mostrar subtítulos", isOn: $session.project.captionStyle.enabled).font(.headline)
                Spacer()
                Toggle("Resaltar palabra", isOn: $session.project.captionStyle.karaoke).font(.caption)
            }
            CaptionStyleEditor(style: $session.project.captionStyle)
            Text("También puedes arrastrar los subtítulos sobre el video para ponerlos donde quieras.")
                .font(.caption2).foregroundStyle(Theme.secondary)
        }
        .onAppear { session.captionDragTarget = .episode }
        .onDisappear { if session.captionDragTarget == .episode { session.captionDragTarget = nil } }
    }

    private var phraseList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Texto").font(.headline)
                Spacer()
                TextField("Buscar…", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.phrases().filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }) { ph in
                        PhraseRow(session: session, phrase: ph, editing: $editing, draft: $draft)
                    }
                }
            }
        }
    }

}

/// Estilo de subtítulos: presets, colores, tamaño y posición. Sirve para el episodio y para los reels.
struct CaptionStyleEditor: View {
    @Binding var style: CaptionStyle
    var compact = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CaptionStyle.presets, id: \.id) { preset in
                    Button {
                        var s = preset.style
                        s.enabled = style.enabled
                        s.freeX = style.freeX; s.freeY = style.freeY
                        style = s
                    } label: {
                        VStack(spacing: 6) {
                            Text(preset.style.uppercase ? "HOLA" : "Hola")
                                .font(.custom(preset.style.fontName, size: compact ? 17 : 22))
                                .foregroundStyle(Color(hex: preset.style.textColor))
                                + Text(preset.style.uppercase ? " MUNDO" : " mundo")
                                .font(.custom(preset.style.fontName, size: compact ? 17 : 22))
                                .foregroundStyle(Color(hex: preset.style.highlightColor))
                            Text(preset.title).font(.caption)
                        }
                        .frame(width: compact ? 88 : 110, height: compact ? 58 : 70)
                        .background(RoundedRectangle(cornerRadius: 10).fill(preset.style.backgroundColor != nil ? Color.black : Theme.panelStrong))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style.preset == preset.id ? Theme.accent : Theme.stroke, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        HStack(spacing: 14) {
            ColorPicker("Texto", selection: colorBinding(\.textColor))
            ColorPicker("Resaltado", selection: colorBinding(\.highlightColor))
            ColorPicker("Borde", selection: colorBinding(\.outlineColor))
            Toggle("MAYÚSCULAS", isOn: $style.uppercase)
        }
        .font(.caption)
        HStack {
            Picker("Tamaño", selection: $style.size) {
                Text("Chico").tag(CaptionStyle.Size.small)
                Text("Mediano").tag(CaptionStyle.Size.medium)
                Text("Grande").tag(CaptionStyle.Size.large)
            }
            Picker("Posición", selection: Binding(get: { style.freeX == nil ? style.position : nil },
                                                 set: { if let p = $0 { style.position = p; style.freeX = nil; style.freeY = nil } })) {
                Text("Arriba").tag(Optional(CaptionStyle.Position.top))
                Text("Centro").tag(Optional(CaptionStyle.Position.center))
                Text("Abajo").tag(Optional(CaptionStyle.Position.bottom))
            }
        }
        .pickerStyle(.segmented)
        .font(.caption)
        if style.freeX != nil {
            HStack {
                Text("Posición libre (arrastrada sobre el video).").font(.caption2).foregroundStyle(Theme.secondary)
                Button("Volver a abajo") { style.freeX = nil; style.freeY = nil; style.position = .bottom }.controlSize(.mini)
            }
        }
    }

    private func colorBinding(_ kp: WritableKeyPath<CaptionStyle, String>) -> Binding<Color> {
        Binding(get: { Color(hex: style[keyPath: kp]) },
                set: { style[keyPath: kp] = $0.hex; style.preset = "custom" })
    }
}

struct PhraseRow: View {
    @ObservedObject var session: ProjectSession
    let phrase: ProjectSession.Phrase
    @Binding var editing: Int?
    @Binding var draft: String
    var reel: Reel? = nil               // dentro de un reel: cortar/devolver solo en ese reel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(EditEngine.clock(phrase.start)) { session.seek(timeline: phrase.start) }
                .buttonStyle(.link).monospacedDigit().font(.caption)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project.laneName(phrase.lane)).font(.caption2.bold()).foregroundStyle(Theme.accent)
                if editing == phrase.id {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commit() }
                    HStack {
                        Button("Guardar") { commit() }.buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Cancelar") { editing = nil }.controlSize(.small)
                    }
                } else {
                    Text(phrase.text)
                        .strikethrough(phrase.isCut)
                        .foregroundStyle(phrase.isCut ? Theme.secondary : .primary)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) { draft = phrase.text; editing = phrase.id }
                }
            }
            Spacer(minLength: 4)
            if editing != phrase.id {
                Button { draft = phrase.text; editing = phrase.id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Corregir texto")
                Button { if let reel { session.togglePhraseCut(phrase, reel: reel) } else { session.togglePhraseCut(phrase) } } label: {
                    Image(systemName: phrase.isCut ? "arrow.uturn.backward" : "scissors")
                }
                .buttonStyle(.borderless)
                .help(phrase.isCut ? "Volver a poner esta frase" : (reel != nil ? "Quitar esta frase solo de este reel" : "Quitar esta frase del video"))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }

    private func commit() {
        session.updatePhrase(phrase, text: draft)
        editing = nil
    }
}

// MARK: - 4. Reels

struct ReelsStep: View {
    @ObservedObject var session: ProjectSession
    @State private var previewing: UUID?

    /// El reel que se está viendo (si sigue existiendo).
    private var currentReel: Reel? { previewing.flatMap { id in session.project.reels.first { $0.id == id } } }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StepHeader(title: "Reels, TikTok y Shorts", subtitle: "Cada momento que marcaste en postPod se convierte en un video vertical con subtítulos.")
                    if session.project.moments.isEmpty && session.project.reels.isEmpty {
                        Card {
                            Label("Este episodio no tiene momentos marcados", systemImage: "bookmark.slash").font(.headline)
                            Text("Márcalos aquí mismo con “Marcar momento” debajo del video, o en postPod web (tecla M) y usa “Traer de nuevo”.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    } else if !session.project.moments.isEmpty {
                        HStack {
                            Label("\(session.project.moments.count) momentos de postPod", systemImage: "bookmark.fill")
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Button("Restaurar desde los momentos") {
                                session.project.reels = session.project.reelsFromMoments()
                            }
                            .buttonStyle(.borderless)
                            .help("Vuelve a crear los reels tal como vienen de postPod")
                        }
                        .font(.callout)
                    }
                    // Cada tarjeta busca su reel por id: borrar uno no deja tarjetas apuntando a un índice que ya no existe (antes la app se cerraba)
                    ForEach(session.project.reels) { reel in
                        ReelCard(reel: reelBinding(reel), isPreviewing: previewing == reel.id, duration: session.project.duration, preview: {
                            show(reel)
                        }, remove: {
                            removeReel(reel.id)
                        }, export: { session.exportReel(reel) }, busy: session.isBusy)
                    }
                    if let reel = currentReel {
                        ReelTextCard(session: session, reel: reel)
                        ReelSoundCard(session: session, reel: reel)
                        ReelBRollCard(session: session, reel: reel)
                        ReelCintilloCard(session: session, reel: reel)
                    }
                    Card {
                        Label("Marcar un momento nuevo", systemImage: "bookmark.fill").font(.headline)
                        Text("Mira el episodio y, cuando pase algo bueno, toca “Marcar momento” debajo del video. Se crea un reel de 60 segundos desde ahí; luego ajustas inicio y fin.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        if session.previewWindow != nil {
                            Button("Ver el episodio completo") {
                                previewing = nil
                                session.setPreview(format: .vertical, window: nil, look: session.project.reelLook)
                            }
                        }
                    }
                    if !session.project.reels.isEmpty {
                        let n = session.project.reels.filter(\.selected).count
                        BigButton(title: "Exportar \(n) \(n == 1 ? "reel" : "reels")", symbol: "square.and.arrow.up",
                                  disabled: n == 0 || session.isBusy) { session.exportReels() }
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 460, maxWidth: 560)
            VStack(spacing: 12) {
                PreviewPane(session: session, allowedFormats: [.vertical])
                    .frame(minHeight: 380)
                ScrollView {
                    ReelLookCard(session: session, reel: currentReel)
                        .frame(maxWidth: 420)
                }
            }
            .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear {
            if let r = session.project.reels.first { show(r) }
            else { session.setPreview(format: .vertical, window: nil, look: session.project.reelLook); session.captionDragTarget = .allReels }
        }
        .onDisappear { session.setPreview(format: .landscape); session.captionDragTarget = nil }
        // Cambios en el diseño (de todos o del reel que se ve) → la vista previa se actualiza
        .onChange(of: session.project.reelLook) { _, _ in refresh() }
        .onChange(of: currentReel?.look) { _, _ in refresh() }
        .onChange(of: currentReel?.cuts) { _, _ in refresh() }
        .onChange(of: currentReel?.brolls) { _, _ in refresh() }
        .onChange(of: currentReel?.music) { _, _ in refresh() }
        .onChange(of: currentReel?.cintillos) { _, _ in refresh() }
    }

    private func reelBinding(_ reel: Reel) -> Binding<Reel> {
        Binding(get: { session.project.reels.first { $0.id == reel.id } ?? reel },
                set: { v in if let i = session.project.reels.firstIndex(where: { $0.id == reel.id }) { session.project.reels[i] = v } })
    }

    private func removeReel(_ id: UUID) {
        if previewing == id {
            previewing = nil
            session.selectedTrack = nil
            session.captionDragTarget = .allReels
            session.setPreview(format: .vertical, window: nil, look: session.project.reelLook)
        }
        if case .reelBRoll(let rid, _) = session.selectedTrack ?? .lane(-1), rid == id { session.selectedTrack = nil }
        session.project.reels.removeAll { $0.id == id }
    }

    private func show(_ reel: Reel) {
        previewing = reel.id
        session.setPreview(format: .vertical, window: (reel.start, reel.end), look: session.project.look(for: reel), reel: reel)
        session.captionDragTarget = reel.look?.captionStyle != nil ? .reel(reel.id) : .allReels
        session.player.seek(to: .zero)
        session.player.play()
    }

    private func refresh() {
        session.setPreview(format: .vertical, window: session.previewWindow, look: session.project.look(for: currentReel), reel: currentReel)
        session.captionDragTarget = captionTarget
    }

    /// Arrastrar los subtítulos cambia el estilo propio del reel si lo tiene; si no, el de todos los reels.
    private var captionTarget: ProjectSession.CaptionTarget {
        if let r = currentReel, r.look?.captionStyle != nil { return .reel(r.id) }
        return .allReels
    }
}

/// Diseño y marca de los reels: para todos, o solo para el reel que se está viendo.
struct ReelLookCard: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel?

    private var own: Bool { reel?.look != nil }
    /// Lo que se edita: el diseño propio del reel o el de todos.
    private var look: Binding<ReelLook> {
        if let reel, let i = session.project.reels.firstIndex(where: { $0.id == reel.id }), session.project.reels[i].look != nil {
            return Binding(get: { session.project.reels[i].look ?? session.project.reelLook },
                           set: { session.project.reels[i].look = $0 })
        }
        return $session.project.reelLook
    }

    var body: some View {
        let p = session.project
        let onePerson = p.lanes.count <= 1
        let choices: [LayoutTemplate] = onePerson ? [.solo, .studio] : [.auto, .solo, .stack, .pip, .spotlight, .grid, .sideBySide, .studio]
        let l = look.wrappedValue
        let chosen: LayoutTemplate = (onePerson && l.layout == .auto) ? .solo : l.layout
        Card {
            HStack {
                Text(own ? "Diseño de este reel" : "Diseño de todos los reels").font(.headline)
                Spacer()
                if reel != nil {
                    Toggle("Este reel tiene el suyo", isOn: Binding(get: { own }, set: { on in
                        guard let reel, let i = session.project.reels.firstIndex(where: { $0.id == reel.id }) else { return }
                        session.project.reels[i].look = on ? session.project.reelLook : nil
                    }))
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                }
            }
            Text(own ? "Solo cambia \"\(reel?.title ?? "")\". Los demás reels siguen con el diseño de todos."
                     : "Aparte del episodio: lo que cambies aquí no toca el video completo.")
                .font(.caption).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 6) {
                ForEach(choices) { t in
                    Button { look.wrappedValue.layout = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.title3)
                            Text(t == .auto ? "Quien habla" : t.title).font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 8).fill(chosen == t ? Theme.panelStrong : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen == t ? Theme.accent : Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .help(t == .auto ? "Pantalla completa para quien está hablando" : t.help)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if l.layout == .auto || l.layout == .solo {
                    Toggle("Con marco de estudio (el fondo detrás)", isOn: look.options.soloStudio)
                }
                if l.layout == .grid && !onePerson {
                    Toggle("Quien habla en grande, los demás en cuadritos", isOn: look.options.gridSpeakerBig)
                }
                if l.layout == .pip && !onePerson {
                    Toggle("En grande quien habla", isOn: look.options.pipFollowSpeaker)
                }
            }
            .font(.caption)
            if !onePerson {
                Divider()
                HStack {
                    Text("Orden en pantalla").font(.caption.bold())
                    Spacer()
                    Toggle("Propio", isOn: Binding(get: { l.laneOrder != nil },
                                                   set: { on in look.wrappedValue.laneOrder = on ? (l.laneOrder ?? p.lanesOnScreen.map(\.id)) : nil }))
                        .toggleStyle(.checkbox).controlSize(.mini).font(.caption)
                }
                let order: [Int] = l.laneOrder ?? p.lanesOnScreen.map(\.id)
                let ids = order + p.lanes.map(\.id).filter { !order.contains($0) }
                ForEach(Array(ids.enumerated()), id: \.element) { i, laneId in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.bold()).frame(width: 18, height: 18).background(Circle().fill(Theme.panelStrong))
                        Text(p.laneName(laneId)).font(.caption)
                        Spacer()
                        Button { session.setReelLanePosition(laneId, i, reelId: own ? reel?.id : nil) } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0 || l.laneOrder == nil).help("Subir")
                        Button { session.setReelLanePosition(laneId, i + 2, reelId: own ? reel?.id : nil) } label: { Image(systemName: "chevron.down") }
                            .disabled(i == ids.count - 1 || l.laneOrder == nil).help("Bajar")
                    }
                    .controlSize(.small)
                }
                Text(l.laneOrder == nil ? "Usa el orden del episodio. Marca «Propio» para cambiarlo solo en los reels." : "1 = arriba (o izquierda). En Ventanita y Protagonista, el primero va en grande.")
                    .font(.caption2).foregroundStyle(Theme.secondary)
            }
            Divider()
            Text("Marca").font(.caption.bold())
            Toggle("Fondo detrás del video", isOn: look.showBackground).font(.caption)
            brandRow(kind: "background", label: "Fondo solo para reels", file: l.backgroundFile, fallback: p.backgroundFile)
            Toggle("Logo arriba a la derecha", isOn: look.showLogo).font(.caption)
            brandRow(kind: "logo", label: "Logo solo para reels", file: l.logoFile, fallback: p.logoFile)
            Toggle("Nombres de las personas", isOn: look.showNames).font(.caption)
            Divider()
            Text("Sonido y subtítulos").font(.caption.bold())
            Toggle("Música y efectos del episodio", isOn: look.music).font(.caption)
            Toggle("Subtítulos", isOn: look.captions).font(.caption)
            if l.captions {
                Toggle("Subtítulos con estilo propio en el reel", isOn: Binding(
                    get: { l.captionStyle != nil },
                    set: { on in look.wrappedValue.captionStyle = on ? (l.captionStyle ?? p.captionStyle) : nil }))
                    .font(.caption)
                if l.captionStyle != nil {
                    CaptionStyleEditor(style: Binding(get: { look.wrappedValue.captionStyle ?? p.captionStyle },
                                                      set: { look.wrappedValue.captionStyle = $0 }), compact: true)
                    Text("Arrastra el recuadro de los subtítulos sobre el video para ponerlos donde quieras en el reel.")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            if !l.music {
                if let reel {
                    HStack {
                        Text("Música de este reel").font(.caption.bold())
                        Spacer()
                        Button { session.importSounds(placeAt: session.playheadTimeline, reelId: reel.id) } label: { Label("Agregar…", systemImage: "music.note.list") }
                            .controlSize(.mini)
                    }
                    if reel.music.isEmpty {
                        Text("Sin música del episodio. Agrega una canción solo para este reel: empieza al inicio del reel y, si es más corta, se repite hasta el final.")
                            .font(.caption2).foregroundStyle(Theme.secondary)
                    }
                    ForEach(reel.music) { m in
                        let sel = session.selectedTrack == .reelSound(reel.id, m.id)
                        Button {
                            session.selectedTrack = .reelSound(reel.id, m.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note").frame(width: 18).foregroundStyle(sel ? Theme.accent : .white)
                                Text(session.project.mediaItem(m.mediaId).map { (($0.originalName as NSString).deletingPathExtension) } ?? "Música").lineLimit(1).font(.caption)
                                Spacer()
                                Text("\(EditEngine.clock(m.tlStart))\(m.loop ? " · bucle" : "") · \(Int(m.volume * 100)) %").font(.caption2).monospacedDigit().foregroundStyle(Theme.secondary)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Theme.panelStrong : Theme.panel))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Sin música del episodio en los reels. Al ver un reel puedes agregarle una canción propia.").font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            if !onePerson {
                Divider()
                Text("Encuadre de cada persona").font(.caption.bold())
                ForEach(p.lanes) { lane in
                    HStack {
                        Text(p.laneName(lane.id)).font(.caption).frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { session.project.laneCrop[lane.id] ?? 0.5 },
                                              set: { session.project.laneCrop[lane.id] = $0 }), in: 0...1)
                    }
                }
                Text("El encuadre vale para todos los reels.").font(.caption2).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func brandRow(kind: String, label: String, file: String?, fallback: String?) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.panelStrong)
                if let f = file ?? fallback, let img = NSImage(contentsOf: ProjectStore.url(f, in: session.project.id)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(3)
                } else {
                    Image(systemName: kind == "logo" ? "seal" : "photo").foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 40, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption)
                Text(file != nil ? "Propio de los reels" : (fallback != nil ? "Se usa el del podcast" : "No hay; elige uno"))
                    .font(.caption2).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button(file == nil ? "Elegir…" : "Cambiar…") { session.chooseReelImage(kind: kind, reelId: own ? reel?.id : nil) }
                .controlSize(.mini)
            if file != nil {
                Button { session.setReelImage(kind: kind, reelId: own ? reel?.id : nil, file: nil) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).controlSize(.mini).help("Volver al del podcast")
            }
        }
    }
}

struct ReelCard: View {
    @Binding var reel: Reel
    let isPreviewing: Bool
    let duration: Double
    let preview: () -> Void
    let remove: () -> Void
    var export: (() -> Void)? = nil
    var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $reel.selected).labelsHidden().padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Título", text: $reel.title).textFieldStyle(.plain).font(.headline)
                if !reel.reason.isEmpty { Text(reel.reason).font(.caption).foregroundStyle(Theme.secondary) }
                HStack(spacing: 6) {
                    timeStepper(value: $reel.start, label: "Empieza")
                    Text("→").foregroundStyle(Theme.secondary)
                    timeStepper(value: $reel.end, label: "Termina")
                    Text("· \(EditEngine.clock(reel.length))").font(.caption).foregroundStyle(reel.length > 90 ? .orange : Theme.secondary)
                }
                HStack(spacing: 6) {
                    Text("Duración:").font(.caption).foregroundStyle(Theme.secondary)
                    ForEach([30.0, 60.0, 90.0], id: \.self) { secs in
                        Button("\(Int(secs)) s") { reel.end = min(duration, reel.start + secs) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                    if reel.length > 90 {
                        Text("Muy largo para reels").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if let file = reel.exportedFile {
                    Label(file, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.good).lineLimit(1)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button(action: preview) { Image(systemName: isPreviewing ? "play.circle.fill" : "play.circle").font(.title2) }
                    .buttonStyle(.borderless).help("Ver este reel")
                if let export {
                    Button(action: export) { Image(systemName: "square.and.arrow.down").font(.title3) }
                        .buttonStyle(.borderless).disabled(busy).help("Exportar solo este reel")
                }
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(isPreviewing ? Theme.panelStrong : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isPreviewing ? Theme.accent : Theme.stroke))
    }

    private func timeStepper(value: Binding<Double>, label: String) -> some View {
        HStack(spacing: 2) {
            Button { value.wrappedValue = max(0, value.wrappedValue - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).help("\(label) 1 s antes")
            TimecodeField(seconds: value, range: 0...max(0, duration)).controlSize(.small)
            Button { value.wrappedValue = min(duration, value.wrappedValue + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("\(label) 1 s después")
        }
    }
}

// MARK: - 5. Export


// MARK: - Patrocinios y marcas

struct BrandsStep: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Patrocinios y marcas", subtitle: "Los sponsors del podcast aparecen en el momento del guion donde van; los cintillos del director, donde los puso en vivo.")
                    Card {
                        HStack {
                            Text("Sponsors").font(.headline)
                            Spacer()
                            Button("Buscar en prePod") { session.fetchBranding() }.controlSize(.small)
                        }
                        if let st = session.brandingStatus {
                            Text(st).font(.caption).foregroundStyle(Theme.secondary)
                        }
                        if session.project.sponsors.isEmpty {
                            Text("Este episodio no tiene sponsors. Si los tienes en prePod, usa “Buscar en prePod”.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        } else {
                            Toggle("Mostrar sponsors en su momento del guion", isOn: $session.project.showSponsors)
                            let apps = session.project.sponsorAppearances()
                            ForEach(session.project.sponsors) { sp in
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 6).fill(Theme.panelStrong)
                                        if let f = sp.logoFile, let img = NSImage(contentsOf: ProjectStore.url(f, in: session.project.id)) {
                                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(4)
                                        } else {
                                            Image(systemName: "tag").foregroundStyle(Theme.secondary)
                                        }
                                    }
                                    .frame(width: 48, height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sp.name).font(.callout.bold())
                                        let mine = apps.filter { $0.sponsor.id == sp.id }
                                        if mine.isEmpty {
                                            Text("Sin momento en el guion de este episodio").font(.caption).foregroundStyle(Theme.secondary)
                                        } else {
                                            Text(mine.map { EditEngine.clock($0.start) }.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let a = apps.first(where: { $0.sponsor.id == sp.id }) {
                                        Button("Ver") { session.seek(timeline: max(0, a.start - 1), play: true) }.controlSize(.small)
                                    }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                            }
                            if apps.isEmpty {
                                Text("Hay sponsors pero ningún bloque del guion de este episodio tiene sponsor asignado. Asígnalo en prePod (guion → bloque → sponsor) y vuelve a “Buscar en prePod”.")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    Card {
                        Text("Cintillos del director").font(.headline)
                        if session.project.cintillos.isEmpty {
                            Text("Este episodio no tiene cintillos puestos en vivo desde prodPod.").font(.caption).foregroundStyle(Theme.secondary)
                        } else {
                            Toggle("Mostrar los \(session.project.cintillos.count) cintillos", isOn: $session.project.showCintillos)
                            ForEach(session.project.cintillos) { c in
                                HStack {
                                    Button(EditEngine.clock(c.start)) { session.seek(timeline: max(0, c.start - 1), play: true) }
                                        .buttonStyle(.link).monospacedDigit()
                                    Text(c.title).lineLimit(1)
                                    Spacer()
                                    Text(c.kind).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 420, maxWidth: 560)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
    }
}

// MARK: - Aspecto

struct LookStep: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Aspecto", subtitle: "Cómo se ve el video. Vale para YouTube, reels y cuadrado; cada formato se ajusta solo.")
                    let onePerson = session.project.lanes.count <= 1
                    let choices = onePerson ? [LayoutTemplate.solo, .studio] : LayoutTemplate.allCases
                    let chosen: LayoutTemplate = (onePerson && session.project.layout == .auto) ? .solo : session.project.layout
                    Card {
                        Text(onePerson ? "Cómo te ves" : "Cómo se ven las personas").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                            ForEach(choices) { l in
                                Button {
                                    session.project.layout = l
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: l.symbol).font(.title2)
                                        Text(l.title).font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 60)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(chosen == l ? Theme.panelStrong : .clear))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen == l ? Theme.accent : Theme.stroke))
                                }
                                .buttonStyle(.plain)
                                .help(l.help)
                            }
                        }
                        layoutOptionsView(onePerson: onePerson)
                        if !onePerson {
                            Divider()
                            Text("Orden en pantalla (1 = izquierda o arriba)").font(.caption.bold())
                            let onScreen = session.project.lanesOnScreen
                            ForEach(Array(onScreen.enumerated()), id: \.element.id) { i, lane in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)").font(.caption.bold()).frame(width: 18, height: 18)
                                        .background(Circle().fill(Theme.panelStrong))
                                    Text(session.project.laneName(lane.id)).font(.caption)
                                    Spacer()
                                    Button { session.setLanePosition(lane.id, i) } label: { Image(systemName: "chevron.up") }
                                        .disabled(i == 0).help("Subir")
                                    Button { session.setLanePosition(lane.id, i + 2) } label: { Image(systemName: "chevron.down") }
                                        .disabled(i == onScreen.count - 1).help("Bajar")
                                }
                                .controlSize(.small)
                            }
                            Text("En Ventanita y Protagonista, el primero es el que va en grande cuando no sigues a quien habla.")
                                .font(.caption2).foregroundStyle(Theme.secondary)
                        }
                        Divider()
                        Text("Espejo (voltear el video de izquierda a derecha)").font(.caption.bold())
                        ForEach(session.project.lanes) { lane in
                            Toggle(session.project.laneName(lane.id), isOn: Binding(get: { session.project.laneMirror[lane.id] ?? false },
                                                                                    set: { session.project.laneMirror[lane.id] = $0 }))
                                .font(.caption)
                        }
                    }
                    Card {
                        Text("Fondo virtual").font(.headline)
                        Text("Quita el fondo real de cada persona (se separa en la Mac, sin internet) y pone otro detrás. Tarda más al exportar y la vista previa usa una separación rápida, menos fina.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        ForEach(session.project.lanes) { lane in
                            virtualBackgroundRow(lane)
                        }
                    }
                    Card {
                        Text("Color").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
                            ForEach([("none", "Original"), ("warm", "Cálido"), ("cool", "Frío"), ("cine", "Cine"), ("bw", "B/N"), ("vivid", "Vivo")], id: \.0) { look in
                                Button { session.project.colorLook = look.0 } label: {
                                    Text(look.1).font(.caption)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(session.project.colorLook == look.0 ? Theme.panelStrong : .clear))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(session.project.colorLook == look.0 ? Theme.accent : Theme.stroke))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if session.project.lanes.count > 1 {
                            HStack {
                                Toggle("Igualar el color de las cámaras", isOn: Binding(
                                    get: { session.project.matchColors },
                                    set: { on in
                                        if on && session.project.laneColorGain.isEmpty { session.matchCameraColors() }
                                        else { session.project.matchColors = on }
                                    }))
                                Spacer()
                                if session.project.matchColors {
                                    Button("Volver a medir") { session.matchCameraColors() }.controlSize(.small).disabled(session.isBusy)
                                }
                            }
                            Text("Toma como referencia a quien está primero en el orden en pantalla (\(session.project.lanesOnScreen.first.map { session.project.laneName($0.id) } ?? "")).")
                                .font(.caption2).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        Text("Marca del podcast").font(.headline)
                        if session.project.backgroundFile != nil {
                            Toggle("Fondo del podcast detrás del video", isOn: $session.project.showBackground)
                        }
                        if session.project.logoFile != nil {
                            Toggle("Logo arriba a la derecha", isOn: $session.project.showLogo)
                        }
                        Toggle("Nombres de las personas", isOn: $session.project.showNames)
                        HStack(spacing: 8) {
                            Button(session.project.backgroundFile == nil ? "Elegir imagen de fondo…" : "Cambiar fondo…") { session.chooseBranding(kind: "background") }
                            Button(session.project.logoFile == nil ? "Elegir logo…" : "Cambiar logo…") { session.chooseBranding(kind: "logo") }
                            if session.project.backgroundFile == nil || session.project.logoFile == nil {
                                Button("Buscar en prePod") { session.fetchBranding() }
                            }
                        }
                        .controlSize(.small)
                        if let st = session.brandingStatus {
                            Text(st).font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        Text("Intro y cierre").font(.headline)
                        Text("Una imagen fija unos segundos antes del video y otra al final, con música si quieres. Solo en el video completo (no en reels ni trozos).")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        bumperRow(title: "Intro", kind: "intro", bumper: session.project.intro)
                        Divider()
                        bumperRow(title: "Cierre", kind: "outro", bumper: session.project.outro)
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 420, maxWidth: 560)
            PreviewPane(session: session)
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { session.setPreview(format: session.previewFormat == .audio ? .landscape : session.previewFormat) }
    }

    @ViewBuilder
    private func bumperRow(title: String, kind: String, bumper: Bumper?) -> some View {
        let isIntro = kind == "intro"
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panelStrong)
                if let b = bumper, let img = NSImage(contentsOf: ProjectStore.url(b.imageFile, in: session.project.id)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.callout.bold())
                    Spacer()
                    Button(bumper == nil ? "Elegir imagen…" : "Cambiar imagen…") { session.chooseBumperImage(isIntro: isIntro) }.controlSize(.small)
                    if bumper != nil {
                        Button(role: .destructive) { session.setBumper(isIntro: isIntro, nil) } label: { Image(systemName: "trash") }.controlSize(.small).help("Quitar")
                    }
                }
                if let b = bumper {
                    HStack(spacing: 8) {
                        Text("Dura").font(.caption)
                        Slider(value: Binding(get: { b.seconds }, set: { v in var nb = b; nb.seconds = v; session.setBumper(isIntro: isIntro, nb) }), in: 1...15, step: 0.5)
                        Text(String(format: "%.1f s", b.seconds)).font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").foregroundStyle(Theme.secondary)
                        if let m = b.musicFile {
                            Text(((m as NSString).lastPathComponent as NSString).deletingPathExtension).font(.caption).lineLimit(1)
                            Slider(value: Binding(get: { b.musicVolume }, set: { v in var nb = b; nb.musicVolume = v; session.setBumper(isIntro: isIntro, nb) }), in: 0...1.5).frame(width: 90)
                            Button("Quitar música") { var nb = b; nb.musicFile = nil; session.setBumper(isIntro: isIntro, nb) }.controlSize(.small)
                        } else {
                            Button("Agregar música…") { session.chooseBumperMusic(isIntro: isIntro) }.controlSize(.small)
                            Text("se corta al largo del \(isIntro ? "intro" : "cierre") y baja al final").font(.caption2).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder
    private func virtualBackgroundRow(_ lane: Lane) -> some View {
        let vb = session.project.laneBackground[lane.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.project.laneName(lane.id)).font(.callout.bold()).frame(width: 90, alignment: .leading)
                Picker("", selection: Binding<String>(
                    get: { vb?.mode.rawValue ?? "none" },
                    set: { v in
                        if v == "none" { session.project.laneBackground[lane.id] = nil }
                        else { var b = vb ?? VirtualBackground(); b.mode = VirtualBackground.Mode(rawValue: v) ?? .blur; session.project.laneBackground[lane.id] = b }
                    })) {
                    Text("Su fondo real").tag("none")
                    ForEach(VirtualBackground.Mode.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
                .labelsHidden().frame(maxWidth: 200)
            }
            if let vb {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 90)
                    switch vb.mode {
                    case .blur:
                        Text("Cuánto").font(.caption)
                        Slider(value: Binding(get: { vb.blur }, set: { session.project.laneBackground[lane.id]?.blur = $0 }), in: 6...40, step: 1)
                            .frame(maxWidth: 180)
                    case .color:
                        ForEach(["#14141A", "#FFFFFF", "#1E3A5F", "#2E7D5B", "#7C2D3D", "#FFD60A"], id: \.self) { c in
                            Button { session.project.laneBackground[lane.id]?.color = c } label: {
                                Circle().fill(Color(hex: c)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(vb.color == c ? Theme.accent : Color.white.opacity(0.3), lineWidth: vb.color == c ? 2.5 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    case .image:
                        if let f = vb.imageFile, let img = NSImage(contentsOf: ProjectStore.url(f, in: session.project.id)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 48, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Button(vb.imageFile == nil ? "Elegir imagen…" : "Cambiar…") { session.chooseVirtualBackgroundImage(laneId: lane.id) }.controlSize(.small)
                        if vb.imageFile == nil { Text("Sin imagen se usa el color").font(.caption2).foregroundStyle(Theme.secondary) }
                    case .podcast:
                        Text(session.project.backgroundFile == nil ? "Este proyecto no tiene fondo del podcast; se verá el color." : "El mismo fondo del podcast, detrás de la persona.")
                            .font(.caption2).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    /// Ajustes del diseño elegido. Cambiar el proyecto ya refresca la vista previa (dirty → schedulePreview).
    @ViewBuilder
    private func layoutOptionsView(onePerson: Bool) -> some View {
        let l = session.project.layout
        let hasBackground = session.project.backgroundFile != nil
        VStack(alignment: .leading, spacing: 6) {
            if l == .auto || l == .solo {
                Toggle("Con marco de estudio (el fondo del podcast detrás)", isOn: $session.project.layoutOptions.soloStudio)
                if session.project.layoutOptions.soloStudio && !hasBackground {
                    Text("Este proyecto no tiene fondo del podcast; se verá un fondo oscuro. Súbelo en prePod → Branding → Fondo.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if l == .grid && !onePerson {
                Toggle("Quien habla en grande, los demás en cuadritos abajo", isOn: $session.project.layoutOptions.gridSpeakerBig)
            }
            if l == .pip && !onePerson {
                Toggle("En grande quien habla (si no, siempre la primera persona)", isOn: $session.project.layoutOptions.pipFollowSpeaker)
            }
        }
        .padding(.top, 4)
    }
}

struct ExportStep: View {
    @ObservedObject var session: ProjectSession
    @State private var format: ExportFormat = .landscape

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Exportar", subtitle: "Elige dónde lo vas a publicar. Nosotros ponemos el tamaño correcto.")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ExportFormat.allCases) { f in
                            Button { select(f) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(systemName: f.symbol).font(.title)
                                        .foregroundStyle(format == f ? Theme.accent : .white)
                                    Text(f.title).font(.headline)
                                    Text(f.subtitle).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 12).fill(format == f ? Theme.panelStrong : Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(format == f ? Theme.accent : Theme.stroke, lineWidth: format == f ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if format != .audio {
                        Card {
                            Text("Qué incluir").font(.headline)
                            HStack {
                                Toggle("Subtítulos", isOn: $session.project.captionStyle.enabled)
                                    .disabled(!session.project.isTranscribed)
                                Spacer()
                                Button("Guardar .srt") { session.saveSubtitles(asText: false) }.controlSize(.small).disabled(!session.project.isTranscribed)
                            }
                            if !session.project.sponsors.isEmpty {
                                Toggle("Sponsors en su momento del guion (\(session.project.sponsorAppearances().count))", isOn: $session.project.showSponsors)
                            }
                            if !session.project.cintillos.isEmpty {
                                Toggle("Cintillos del director (\(session.project.cintillos.count))", isOn: $session.project.showCintillos)
                            }
                            Divider()
                            HStack(spacing: 6) {
                                Image(systemName: "rectangle.3.group").foregroundStyle(Theme.secondary)
                                Text("Aspecto: \(session.project.layout.title)\(session.project.showBackground && session.project.backgroundFile != nil ? " · fondo" : "")\(session.project.showLogo && session.project.logoFile != nil ? " · logo" : "")\(session.project.intro != nil ? " · intro" : "")\(session.project.outro != nil ? " · cierre" : "")")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                                Spacer()
                                Button("Cambiar") { session.step = .look }.controlSize(.small)
                            }
                        }
                    }
                    if format != .audio {
                        Card {
                            Picker("Archivo", selection: $session.project.exportHEVC) {
                                Text("Compatible (H.264): se ve en todas partes").tag(false)
                                Text("Liviano (HEVC): la mitad de peso, más rápido").tag(true)
                            }
                            .pickerStyle(.radioGroup).font(.caption)
                        }
                    }
                    Toggle("Ajustar el volumen final para Spotify y YouTube (−16 LUFS)", isOn: $session.project.normalizeLoudness)
                        .font(.caption)
                    BigButton(title: "Exportar \(format.title)", symbol: "square.and.arrow.up", disabled: session.isBusy) {
                        session.export(format: format)
                    }
                    if !session.lastExports.isEmpty {
                        Card {
                            Text("Ya exportados").font(.headline)
                            ForEach(session.lastExports.prefix(12), id: \.self) { url in
                                HStack {
                                    Image(systemName: url.pathExtension == "mp4" ? "film" : "waveform")
                                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        .buttonStyle(.borderless)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding(28)
            }
            .frame(minWidth: 440, maxWidth: 540)
            PreviewPane(session: session, allowedFormats: [])
                .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear { select(format) }
    }

    private func select(_ f: ExportFormat) {
        format = f
        session.setPreview(format: f == .audio ? .landscape : f)
    }


}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("whisperModel") private var whisperModel = Transcriber.defaultModel
    @AppStorage("introAlAbrir") private var introEnabled = true
    @AppStorage("sonidoAlCerrar") private var quitSound = true

    var body: some View {
        Form {
            PrePodSettingsSection()
            UpdateSettingsSection()
            Section("Al abrir y cerrar") {
                Toggle("Sonido y animación de thePod al abrir la app", isOn: $introEnabled)
                Toggle("Sonido de thePod al cerrar la app", isOn: $quitSound)
            }
            Section("Transcripción (en tu Mac)") {
                Picker("Modelo de voz", selection: $whisperModel) {
                    Text("Preciso (recomendado)").tag(Transcriber.defaultModel)
                    Text("Rápido (ocupa menos y termina antes)").tag("openai_whisper-small")
                }
            }
            if !FFmpeg.isAvailable {
                Section {
                    Label("A esta copia de thePod le falta una parte para procesar video. Vuelve a instalar la app.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Carpeta de proyectos") {
                Button(ProjectStore.libraryURL.path) { NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.libraryURL]) }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}


/// Texto del reel: las frases que caen en él, para corregirlas o quitarlas solo en este reel.
struct ReelTextCard: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        Card {
            Text("Texto de este reel").font(.headline)
            if !session.project.isTranscribed {
                Text("Este episodio no tiene transcripción. Hazla en Subtítulos y aquí aparecen las frases del reel.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            } else {
                Text("Doble clic para corregir una palabra (vale para el episodio y el reel). Las tijeras quitan la frase solo de este reel.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                ForEach(session.phrases(reel: reel)) { ph in
                    PhraseRow(session: session, phrase: ph, editing: $editing, draft: $draft, reel: reel)
                }
                if !reel.cuts.isEmpty {
                    HStack {
                        Text("\(reel.cuts.count) \(reel.cuts.count == 1 ? "corte propio" : "cortes propios") en este reel").font(.caption2).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("Deshacer todos") {
                            if let i = session.project.reels.firstIndex(where: { $0.id == reel.id }) { session.project.reels[i].cuts = [] }
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
    }
}

/// Sonido del reel: limpieza (si falta), silencios solo del reel y silenciar a quien no habla.
struct ReelSoundCard: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel

    private var gate: Binding<Bool> {
        Binding(get: { session.project.look(for: reel).gateOthers ?? session.project.fix.gateOthers },
                set: { v in
                    if let i = session.project.reels.firstIndex(where: { $0.id == reel.id }), session.project.reels[i].look != nil {
                        session.project.reels[i].look?.gateOthers = v
                    } else { session.project.reelLook.gateOthers = v }
                })
    }

    var body: some View {
        let cleaned = session.project.media.contains { $0.enhancedAudioFile != nil }
        Card {
            Text("Sonido de este reel").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: cleaned ? "checkmark.circle.fill" : "circle").foregroundStyle(cleaned ? Theme.good : Theme.secondary)
                Text(cleaned ? "Sonido de estudio aplicado (vale para el episodio y todos los reels)." : "El sonido todavía no está limpio.")
                    .font(.caption)
                Spacer()
                if !cleaned {
                    Button("Limpiar sonido") { session.enhanceAudioOnly() }.controlSize(.small).disabled(session.isBusy)
                        .help("Lo mismo que en Limpiar sonido, pero sin tocar cortes ni transcripción")
                }
            }
            HStack(spacing: 8) {
                Button { session.removeSilences(in: reel) } label: { Label("Quitar silencios solo en este reel", systemImage: "scissors") }
                    .controlSize(.small).disabled(session.isBusy)
                Spacer()
            }
            if session.project.lanes.count > 1 {
                Toggle("Silenciar a quien no habla", isOn: gate).font(.caption)
            }
            if let n = session.reelsNote { Text(n).font(.caption2).foregroundStyle(Theme.secondary) }
            Text("Lo que corta aquí no cambia el episodio.").font(.caption2).foregroundStyle(Theme.secondary)
        }
    }
}


/// B-roll solo de este reel: video o foto corta (máximo 10 s y siempre más corta que el reel), entera o en ventanita.
struct ReelBRollCard: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel

    var body: some View {
        Card {
            HStack {
                Text("B-roll de este reel").font(.headline)
                Spacer()
                Button { session.chooseBRoll(reelId: reel.id) } label: { Label("Agregar video o imagen…", systemImage: "film") }
                    .controlSize(.small).disabled(reel.length < 2)
            }
            if reel.length < 2 {
                Text("El reel es muy corto para un b-roll.").font(.caption).foregroundStyle(Theme.secondary)
            } else if reel.brolls.isEmpty {
                Text("Un video o una foto que entra unos segundos solo en este reel: toda la pantalla o en una ventanita abajo. Máximo \(Int(BRollClip.maxSeconds)) s.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(reel.brolls.sorted { $0.start < $1.start }) { b in
                let sel = session.selectedTrack == .reelBRoll(reel.id, b.id)
                Button {
                    session.selectedTrack = .reelBRoll(reel.id, b.id)
                    session.seek(timeline: b.start + min(1, b.duration / 2), play: false)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: b.isVideo ? "film" : "photo").frame(width: 22).foregroundStyle(sel ? Theme.accent : .white)
                        Text(b.title).lineLimit(1)
                        Spacer()
                        Text((b.placement == "full" ? "pantalla" : b.placement == "pipLeft" ? "ventanita izq." : "ventanita der.") + " · \(EditEngine.clock(b.start)) · \(String(format: "%.0f s", b.duration))")
                            .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}


/// Cintillos solo de este reel (además de los del episodio que caigan en su tramo).
struct ReelCintilloCard: View {
    @ObservedObject var session: ProjectSession
    let reel: Reel

    var body: some View {
        let inherited = session.project.cintillos.filter { $0.end > reel.start && $0.start < reel.end }.count
        Card {
            Text("Cintillos de este reel").font(.headline)
            HStack(spacing: 8) {
                Button("Noticiero") { _ = session.addCintillo(style: "news", kind: "banner", logoFile: session.project.logoFile, tag: "AHORA", reelId: reel.id) }
                Button("Limpio") { _ = session.addCintillo(style: "clean", kind: "comment", reelId: reel.id) }
                Button("Sponsor") { _ = session.addCintillo(style: "sponsor", kind: "sponsor", tag: "PATROCINA", reelId: reel.id) }
                ForEach(session.project.sponsors) { sp in
                    Button("De \(sp.name)") { session.addSponsorCintillo(sp, reelId: reel.id) }
                }
            }
            .controlSize(.small)
            if reel.cintillos.isEmpty {
                Text(inherited > 0 ? "El reel ya muestra \(inherited) del episodio que caen en su tramo. Los que agregues aquí salen solo en este reel."
                                   : "Los que agregues aquí salen solo en este reel, donde está el video.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(reel.cintillos.sorted { $0.start < $1.start }) { c in
                let sel = session.selectedTrack == .reelCintillo(reel.id, c.id)
                Button {
                    session.selectedTrack = .reelCintillo(reel.id, c.id)
                    session.seek(timeline: max(reel.start, c.start - 0.5), play: false)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.bottomthird.inset.filled").frame(width: 22).foregroundStyle(sel ? Theme.accent : .white)
                        Text(c.title.isEmpty ? c.text : c.title).lineLimit(1)
                        Spacer()
                        Text("\(c.style == "clean" ? "Limpio" : c.style == "sponsor" ? "Sponsor" : "Noticiero") · \(EditEngine.clock(c.start)) · \(String(format: "%.0f s", c.duration))")
                            .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
