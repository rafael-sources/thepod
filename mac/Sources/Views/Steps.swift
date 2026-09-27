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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CaptionStyle.presets, id: \.id) { preset in
                        Button {
                            var s = preset.style
                            s.enabled = true
                            session.project.captionStyle = s
                        } label: {
                            VStack(spacing: 6) {
                                Text(preset.style.uppercase ? "HOLA" : "Hola")
                                    .font(.custom(preset.style.fontName, size: 22))
                                    .foregroundStyle(Color(hex: preset.style.textColor))
                                    + Text(preset.style.uppercase ? " MUNDO" : " mundo")
                                    .font(.custom(preset.style.fontName, size: 22))
                                    .foregroundStyle(Color(hex: preset.style.highlightColor))
                                Text(preset.title).font(.caption)
                            }
                            .frame(width: 110, height: 70)
                            .background(RoundedRectangle(cornerRadius: 10).fill(preset.style.backgroundColor != nil ? Color.black : Theme.panelStrong))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(session.project.captionStyle.preset == preset.id ? Theme.accent : Theme.stroke, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 14) {
                ColorPicker("Texto", selection: colorBinding(\.textColor))
                ColorPicker("Resaltado", selection: colorBinding(\.highlightColor))
                ColorPicker("Borde", selection: colorBinding(\.outlineColor))
                Toggle("MAYÚSCULAS", isOn: $session.project.captionStyle.uppercase)
            }
            .font(.caption)
            HStack {
                Picker("Tamaño", selection: $session.project.captionStyle.size) {
                    Text("Chico").tag(CaptionStyle.Size.small)
                    Text("Mediano").tag(CaptionStyle.Size.medium)
                    Text("Grande").tag(CaptionStyle.Size.large)
                }
                Picker("Posición", selection: $session.project.captionStyle.position) {
                    Text("Arriba").tag(CaptionStyle.Position.top)
                    Text("Centro").tag(CaptionStyle.Position.center)
                    Text("Abajo").tag(CaptionStyle.Position.bottom)
                }
            }
            .pickerStyle(.segmented)
            .font(.caption)
        }
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

    private func colorBinding(_ kp: WritableKeyPath<CaptionStyle, String>) -> Binding<Color> {
        Binding(get: { Color(hex: session.project.captionStyle[keyPath: kp]) },
                set: { session.project.captionStyle[keyPath: kp] = $0.hex; session.project.captionStyle.preset = "custom" })
    }
}

struct PhraseRow: View {
    @ObservedObject var session: ProjectSession
    let phrase: ProjectSession.Phrase
    @Binding var editing: Int?
    @Binding var draft: String

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
                Button { session.togglePhraseCut(phrase) } label: {
                    Image(systemName: phrase.isCut ? "arrow.uturn.backward" : "scissors")
                }
                .buttonStyle(.borderless)
                .help(phrase.isCut ? "Volver a poner esta frase" : "Quitar esta frase del video")
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
                    ForEach($session.project.reels) { $reel in
                        ReelCard(reel: $reel, isPreviewing: previewing == reel.id, duration: session.project.duration) {
                            previewing = reel.id
                            session.setPreview(format: .vertical, window: (reel.start, reel.end), layout: session.project.reelLayout)
                            session.player.seek(to: .zero)
                            session.player.play()
                        } remove: {
                            session.project.reels.removeAll { $0.id == reel.id }
                        }
                    }
                    Card {
                        Label("Marcar un momento nuevo", systemImage: "bookmark.fill").font(.headline)
                        Text("Mira el episodio y, cuando pase algo bueno, toca “Marcar momento” debajo del video. Se crea un reel de 60 segundos desde ahí; luego ajustas inicio y fin.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        if session.previewWindow != nil {
                            Button("Ver el episodio completo") {
                                previewing = nil
                                session.setPreview(format: .vertical, window: nil, layout: session.project.reelLayout)
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
                if session.project.lanes.count > 1 {
                    Card {
                        Picker("Diseño", selection: Binding(get: { session.project.reelLayout },
                                                            set: { session.project.reelLayout = $0
                                                                   session.setPreview(format: .vertical, window: session.previewWindow, layout: $0) })) {
                            Text("Quien habla").tag(LayoutTemplate.auto)
                            Text("Arriba y abajo").tag(LayoutTemplate.stack)
                        }
                        .pickerStyle(.segmented)
                        Text("Encuadre de cada persona").font(.caption.bold())
                        ForEach(session.project.lanes) { lane in
                            HStack {
                                Text(session.project.laneName(lane.id)).font(.caption).frame(width: 90, alignment: .leading)
                                Slider(value: Binding(get: { session.project.laneCrop[lane.id] ?? 0.5 },
                                                      set: { session.project.laneCrop[lane.id] = $0 }), in: 0...1)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
            .padding(.vertical, 28).padding(.trailing, 28)
        }
        .onAppear {
            session.setPreview(format: .vertical, window: session.project.reels.first.map { ($0.start, $0.end) },
                               layout: session.project.reelLayout)
        }
        .onDisappear { session.setPreview(format: .landscape) }
    }
}

struct ReelCard: View {
    @Binding var reel: Reel
    let isPreviewing: Bool
    let duration: Double
    let preview: () -> Void
    let remove: () -> Void

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
            VStack {
                Button(action: preview) { Image(systemName: isPreviewing ? "play.circle.fill" : "play.circle").font(.title2) }
                    .buttonStyle(.borderless).help("Ver este reel")
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
            Text(EditEngine.clock(value.wrappedValue)).monospacedDigit().font(.caption)
            Button { value.wrappedValue = min(duration, value.wrappedValue + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("\(label) 1 s después")
        }
    }
}

// MARK: - 5. Export

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
                        if session.project.lanes.count > 1 {
                            Card {
                                Text("Cómo se ven las personas").font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                                    ForEach(LayoutTemplate.allCases) { l in
                                        Button {
                                            session.project.layout = l
                                            session.setPreview(format: format, layout: nil)
                                        } label: {
                                            VStack(spacing: 4) {
                                                Image(systemName: l.symbol).font(.title2)
                                                Text(l.title).font(.caption)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 60)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(session.project.layout == l ? Theme.panelStrong : .clear))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(session.project.layout == l ? Theme.accent : Theme.stroke))
                                        }
                                        .buttonStyle(.plain)
                                        .help(l.help)
                                    }
                                }
                            }
                        }
                        Card {
                            Toggle("Subtítulos", isOn: $session.project.captionStyle.enabled)
                                .disabled(!session.project.isTranscribed)
                            Toggle("Nombres de las personas", isOn: $session.project.showNames)
                            if session.project.logoFile != nil {
                                Toggle("Logo del podcast", isOn: $session.project.showLogo)
                            }
                            if !session.project.sponsors.isEmpty {
                                Toggle("Sponsors en su momento del guion", isOn: $session.project.showSponsors)
                            }
                        }
                    }
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

    var body: some View {
        Form {
            PrePodSettingsSection()
            UpdateSettingsSection()
            Section("Al abrir") {
                Toggle("Sonido y animación de thePod al abrir la app", isOn: $introEnabled)
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
