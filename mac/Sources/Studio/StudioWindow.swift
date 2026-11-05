import SwiftUI
import AVFoundation

/// El estudio: ventana aparte con la línea de tiempo y la consola del episodio abierto.
/// Mismo proyecto, mismo motor: lo que suena aquí es lo que exporta el nivel simple.
/// Qué pestaña de Studio está abierta (Audio o Video); la cambian los botones y ⌘E / ⌘⇧E.
final class StudioTab: ObservableObject {
    static let shared = StudioTab()
    enum Tab: String, CaseIterable, Identifiable { case audio, video; var id: String { rawValue } }
    @Published var tab: Tab = .audio
}

struct StudioRoot: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var tabs = StudioTab.shared
    var body: some View {
        Group {
            if let s = app.session {
                VStack(spacing: 0) {
                    StudioTransport(session: s, tab: $tabs.tab)
                    Divider()
                    switch tabs.tab {
                    case .audio: AudioStudioView(session: s)
                    case .video: VideoStudioView(session: s)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(Theme.secondary)
                    Text("Abre un episodio para entrar a Studio").foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

/// Transporte común a las dos pestañas: título, Audio/Video, reproducir, reloj, sonoridad y Exportar.
struct StudioTransport: View {
    @ObservedObject var session: ProjectSession
    @Binding var tab: StudioTab.Tab
    @ObservedObject private var chains = VoiceChainRegistry.shared

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Studio · \(session.project.name)").font(.headline)
                Text(tab == .audio ? "Lo que suena aquí es lo que se exporta. Los pasos simples siguen igual."
                     : "Lo que se ve aquí es lo que se exporta. Aspecto, Textos y Reels siguen igual.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            Picker("", selection: $tab) {
                Text("Audio").tag(StudioTab.Tab.audio)
                Text("Video").tag(StudioTab.Tab.video)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Spacer()
            Button {
                if session.player.rate > 0 { session.player.pause() } else { session.player.play() }
            } label: {
                Image(systemName: session.player.rate > 0 ? "pause.fill" : "play.fill").frame(width: 36)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.space, modifiers: [])
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(EditEngine.clock(session.playheadTimeline)).font(.title3.monospacedDigit())
            }
            Spacer()
            Toggle(isOn: $chains.bypassAll) {
                Label(chains.bypassAll ? "Sin procesar" : "A/B", systemImage: chains.bypassAll ? "waveform.slash" : "waveform")
            }
            .toggleStyle(.button).keyboardShortcut("b", modifiers: [.command, .shift])
            .tint(chains.bypassAll ? .orange : Theme.accent)
            .help("A/B instantáneo (⌘⇧B): oír las voces sin ninguna cadena (EQ, compresor, plugins, limitador) mientras suena. Solo al escuchar; el export siempre procesa.")
            MasterBadge(session: session)
            Button("Exportar…") { session.step = .export }
                .help("Vuelve a la ventana principal, en Exportar")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct AudioStudioView: View {
    @ObservedObject var session: ProjectSession
    @State private var editingInsert: InsertRef?

    struct InsertRef: Identifiable, Hashable {
        enum Kind: Hashable { case eq, compressor, deesser, gate }
        let laneId: Int
        let kind: Kind
        var id: String { "\(laneId)-\(kind)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                EpisodeTimeline(session: session)
                    .padding(.horizontal, 12).padding(.top, 8)
                HStack { Text("Automatización").font(.caption.bold()); Spacer() }.padding(.horizontal, 12).padding(.top, 4)
                AutomationLanes(session: session).padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            Divider()
            console
        }
        .sheet(item: $editingInsert) { ref in
            InsertEditor(session: session, ref: ref)
        }
        .task(id: session.project.episode.prepodSlug) {
            if let slug = session.project.episode.prepodSlug { await ChainPresets.refresh(podcast: slug) }
        }
    }

    // MARK: Consola

    private var console: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Consola").font(.headline)
                Text("inserts antes del volumen · faders en dB · medidor de lo que suena")
                    .font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(session.project.lanes.indices, id: \.self) { i in
                        ChannelStrip(session: session, index: i, color: EpisodeTimeline.palette[i % EpisodeTimeline.palette.count]) { kind in
                            editingInsert = InsertRef(laneId: session.project.lanes[i].id, kind: kind)
                        }
                    }
                    MasterStrip(session: session)
                }
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .frame(height: 380)
    }
}

/// Sonoridad: la medida real llega al exportar (EBU R128); mientras, el objetivo del destino.
struct MasterBadge: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let r = session.built?.loudness?.read()
            HStack(spacing: 10) {
                Text("MASTER").font(.caption2.monospaced()).foregroundStyle(Theme.secondary)
                if let r {
                    LoudnessBar(lufs: r.momentary, target: -16)
                    Text(String(format: "%.1f", r.momentary)).font(.callout.monospacedDigit())
                    Text("LUFS").font(.caption2).foregroundStyle(Theme.secondary)
                    if let i = r.integrated {
                        Text(String(format: "int. %.1f", i)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("— LUFS").font(.callout.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                Text(session.project.normalizeLoudness ? "→ −16 audio · −14 video al exportar" : "sin ajuste al exportar")
                    .font(.caption2).foregroundStyle(session.project.normalizeLoudness ? Theme.secondary : .orange)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .help("Sonoridad de la mezcla mientras suena (estimada sumando las pistas con su volumen, con filtro K). La medida exacta se hace al exportar.")
        }
    }
}

struct LoudnessBar: View {
    let lufs: Double
    let target: Double
    var body: some View {
        GeometryReader { g in
            let frac = max(0, min(1, (lufs + 40) / 40))         // −40 … 0 LUFS
            let tf = max(0, min(1, (target + 40) / 40))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35))
                RoundedRectangle(cornerRadius: 3)
                    .fill(abs(lufs - target) < 1.5 ? Theme.good : (lufs > target ? Theme.accent : Theme.secondary))
                    .frame(width: g.size.width * frac)
                Rectangle().fill(Color.white).frame(width: 1).offset(x: g.size.width * tf)
            }
        }
        .frame(width: 110, height: 8)
    }
}

/// Un canal de la consola: nombre, inserts, fader en dB, medidor, M/S.
struct ChannelStrip: View {
    @ObservedObject var session: ProjectSession
    let index: Int
    let color: Color
    let openInsert: (AudioStudioView.InsertRef.Kind) -> Void
    @State private var askPresetName = false
    @State private var presetName = ""
    @State private var presetsTick = 0

    private var lane: Lane { session.project.lanes[index] }
    private var chain: ChainSettings { lane.effectiveChain }
    private var podcastSlug: String? { session.project.episode.prepodSlug }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(session.project.laneName(lane.id)).font(.callout.bold()).lineLimit(1)
                Spacer()
                if chain.hasAutomation {
                    Image(systemName: "a.circle.fill").foregroundStyle(Theme.accent).help("Tiene parámetros automatizados")
                }
                if lane.tunedInStudio {
                    Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(Theme.accent)
                        .help("Ajustado en Studio: el nivel simple no sabe describir esta cadena")
                }
            }
            VStack(spacing: 3) {
                insertRow("EQ paramétrico", on: !chain.bands.isEmpty, detail: chain.bands.isEmpty ? "plano" : "\(chain.bands.filter(\.enabled).count) bandas") { openInsert(.eq) }
                insertRow("Compresor", on: chain.compressorOn, detail: chain.compressorOn ? String(format: "%.0f dB · %.1f:1", chain.threshold, chain.ratio) : "apagado") { openInsert(.compressor) }
                insertRow("De-esser", on: chain.deesserOn, detail: chain.deesserOn ? "\(Int(chain.deesserAmount * 100)) %" : "apagado") { openInsert(.deesser) }
                insertRow("Puerta", on: chain.gateOn, detail: chain.gateOn ? String(format: "%.0f dB", chain.gateThreshold) : "apagada") { openInsert(.gate) }
                ForEach(chain.plugins) { pl in
                    HStack(spacing: 6) {
                        Button {
                            PluginHost.openEditor(pl, title: "\(session.project.laneName(lane.id)) · \(pl.name)") { data in
                                edit { c in if let i = c.plugins.firstIndex(where: { $0.id == pl.id }) { c.plugins[i].state = data } }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(pl.enabled ? Theme.good : Color.clear).overlay(Circle().strokeBorder(pl.enabled ? Theme.good : Theme.secondary, lineWidth: 1)).frame(width: 7, height: 7)
                                Text(pl.name).font(.caption).lineLimit(1)
                                Spacer()
                                Image(systemName: "macwindow").font(.caption2).foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelStrong))
                        }
                        .buttonStyle(.plain)
                        .help("\(pl.vendor) · abrir la ventana del plugin")
                        .contextMenu {
                            Button(pl.enabled ? "Apagar" : "Encender") { edit { c in if let i = c.plugins.firstIndex(where: { $0.id == pl.id }) { c.plugins[i].enabled.toggle() } } }
                            let idx = chain.plugins.firstIndex(where: { $0.id == pl.id }) ?? 0
                            Button("Subir") { edit { c in if let i = c.plugins.firstIndex(where: { $0.id == pl.id }), i > 0 { c.plugins.swapAt(i, i - 1) } } }.disabled(idx == 0)
                            Button("Bajar") { edit { c in if let i = c.plugins.firstIndex(where: { $0.id == pl.id }), i < c.plugins.count - 1 { c.plugins.swapAt(i, i + 1) } } }.disabled(idx >= chain.plugins.count - 1)
                            Divider()
                            Button("Quitar de la cadena", role: .destructive) { edit { c in c.plugins.removeAll { $0.id == pl.id } } }
                        }
                    }
                }
                Menu {
                    let avail = PluginHost.available()
                    if avail.isEmpty { Text("No hay plugins Audio Unit instalados") }
                    let favs = PluginHost.favorites(from: avail)
                    if !favs.isEmpty {
                        Section("Usados hace poco") {
                            ForEach(favs) { a in Button(a.name) { add(a) } }
                        }
                    }
                    ForEach(Dictionary(grouping: avail, by: \.vendor).keys.sorted(), id: \.self) { vendor in
                        Menu(vendor) {
                            ForEach(avail.filter { $0.vendor == vendor }) { a in
                                Button(a.name + (a.isV3 ? "" : "  (AUv2, dentro de la app)")) { add(a) }
                            }
                        }
                    }
                } label: { Text("+ plugin AU").font(.caption) }
                .menuStyle(.borderlessButton).frame(height: 22)
                .help("Plugins Audio Unit instalados en esta Mac. Los AUv3 corren aparte: si uno falla no cae la app.")
                HStack {
                    Text("Limitador").font(.caption)
                    Spacer()
                    Toggle("", isOn: Binding(get: { chain.limiterOn }, set: { v in edit { $0.limiterOn = v } })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                .padding(.horizontal, 6).frame(height: 22)
            }
            HStack(alignment: .top, spacing: 8) {
                Fader(volume: $session.project.lanes[index].volume)
                Meter(session: session, laneId: lane.id)
            }
            .frame(height: 100)
            HStack(spacing: 4) {
                Toggle("M", isOn: $session.project.lanes[index].muted).toggleStyle(.button).controlSize(.small)
                Toggle("S", isOn: $session.project.lanes[index].solo).toggleStyle(.button).controlSize(.small)
                Spacer()
                if session.project.matchVoices, abs(lane.matchGain) >= 0.05 {
                    Text(String(format: "%@%.1f", lane.matchGain >= 0 ? "+" : "", lane.matchGain)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.accent)
                        .help(String(format: "Voces parejas por medición: %.1f LUFS medidos, %+.1f dB aplicados antes del fader", lane.measuredLUFS ?? 0, lane.matchGain))
                }
                Text(Fader.label(lane.volume)).font(.caption.monospacedDigit())
            }
            HStack(spacing: 6) {
                Menu {
                    Button(podcastSlug != nil ? "Guardar en el podcast como preset…" : "Guardar en esta Mac como preset…") { askPresetName = true }
                    let ofPodcast = podcastSlug.map { ChainPresets.all(podcast: $0) } ?? []
                    let mine = ChainPresets.all()
                    if !ofPodcast.isEmpty {
                        Divider()
                        Text("Del podcast")
                        ForEach(ofPodcast) { p in Button(p.name) { Lane.store(p.chain, in: &session.project.lanes[index]) } }
                    }
                    if !mine.isEmpty {
                        Divider()
                        Text("De esta Mac")
                        ForEach(mine) { p in Button(p.name) { Lane.store(p.chain, in: &session.project.lanes[index]) } }
                    }
                    if !ofPodcast.isEmpty || !mine.isEmpty {
                        Divider()
                        Menu("Borrar un preset") {
                            ForEach(ofPodcast) { p in Button(p.name + " (podcast)", role: .destructive) { ChainPresets.remove(p.id, podcast: podcastSlug); presetsTick += 1 } }
                            ForEach(mine) { p in Button(p.name + " (esta Mac)", role: .destructive) { ChainPresets.remove(p.id); presetsTick += 1 } }
                        }
                    }
                    Divider()
                    Button("Voz clara") { Lane.store(ChainSettings.preset(VoiceEQ.preset("clear")), in: &session.project.lanes[index]) }
                    Button("Cálida") { Lane.store(ChainSettings.preset(VoiceEQ.preset("warm")), in: &session.project.lanes[index]) }
                    Button("Original (sin cadena)") { session.project.lanes[index].eq = VoiceEQ(); session.project.lanes[index].chain = nil }
                } label: { Label("Presets", systemImage: "square.stack").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().id(presetsTick)
                Spacer()
                if lane.chain != nil {
                    Button("Volver al simple") { session.project.lanes[index].chain = nil }
                        .controlSize(.mini).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
            }
            .alert("Nombre del preset", isPresented: $askPresetName) {
                TextField("Mi cadena de voz", text: $presetName)
                Button("Guardar") {
                    let n = presetName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { ChainPresets.add(name: n, chain: lane.effectiveChain, podcast: podcastSlug); presetsTick += 1 }
                    presetName = ""
                }
                Button("Cancelar", role: .cancel) { presetName = "" }
            } message: { Text(podcastSlug != nil
                              ? "Guarda el ecualizador, el compresor, el de-esser y la puerta de \(session.project.laneName(lane.id)) en el podcast: sirve para cualquier voz y episodio, en cualquier Mac con tu cuenta."
                              : "Guarda el ecualizador, el compresor, el de-esser y la puerta de \(session.project.laneName(lane.id)) en esta Mac. (Este episodio no está vinculado a un podcast de prePod.)") }
        }
        .padding(10)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
    }

    private func edit(_ f: (inout ChainSettings) -> Void) {
        var c = lane.effectiveChain
        f(&c)
        Lane.store(c, in: &session.project.lanes[index])
    }
    private func add(_ a: PluginHost.Available) {
        PluginHost.noteUsed(a)
        edit { c in c.plugins.append(a.insert) }
    }

    private func insertRow(_ name: String, on: Bool, detail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(on ? Theme.good : Color.clear).overlay(Circle().strokeBorder(on ? Theme.good : Theme.secondary, lineWidth: 1)).frame(width: 7, height: 7)
                Text(name).font(.caption)
                Spacer()
                Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .padding(.horizontal, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelStrong))
        }
        .buttonStyle(.plain)
    }
}

/// Fader vertical en dB sobre el volumen lineal de la pista (0…2).
struct Fader: View {
    @Binding var volume: Double
    static let minDB = -40.0, maxDB = 6.0

    static func label(_ v: Double) -> String { v <= 0.0001 ? "−∞" : String(format: "%+.1f dB", 20 * log10(v)) }

    private var db: Binding<Double> {
        Binding(get: { volume <= 0.0001 ? Self.minDB : max(Self.minDB, min(Self.maxDB, 20 * log10(volume))) },
                set: { volume = $0 <= Self.minDB + 0.01 ? 0 : pow(10, $0 / 20) })
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
                Slider(value: db, in: Self.minDB...Self.maxDB)
                    .rotationEffect(.degrees(-90))
                    .frame(width: g.size.height - 8, height: 24)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
        .frame(width: 40)
        .help("Doble clic en el número para escribir dB")
    }
}

/// Medidor de lo que suena de esa persona (después del volumen), leído del motor mientras reproduce.
struct Meter: View {
    @ObservedObject var session: ProjectSession
    let laneId: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            let t = session.player.currentTime().seconds
            let db = session.built?.levelDB(lane: laneId, at: t) ?? -120
            let frac = max(0, min(1, (db + 60) / 60))
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Theme.good, Theme.good, Theme.accent, Color.red], startPoint: .bottom, endPoint: .top))
                        .frame(height: g.size.height * frac)
                }
            }
            .frame(width: 12)
            .help(db > -119 ? String(format: "%.1f dB", db) : "en silencio")
        }
    }
}

struct MasterStrip: View {
    @ObservedObject var session: ProjectSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Master").font(.callout.bold())
            Text("Estéreo · 48 kHz").font(.caption2).foregroundStyle(Theme.secondary)
            Toggle("Sonoridad al exportar", isOn: $session.project.normalizeLoudness).font(.caption).controlSize(.small)
            Text("−16 LUFS para Spotify y Apple · −14 para YouTube y redes. Se mide de verdad (EBU R128) al exportar.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("El medidor de arriba estima la sonoridad mientras suena. Los plugins AU de cada persona (menú «+ plugin AU») suenan y se exportan igual que el resto de la cadena.")
                .font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(width: 210, height: 330)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelStrong))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.35)))
    }
}

/// Editor de un insert. Cada cambio se oye al instante.
struct InsertEditor: View {
    @ObservedObject var session: ProjectSession
    let ref: AudioStudioView.InsertRef
    @Environment(\.dismiss) private var dismiss
    @State private var writing = false      // «Escribir»: mover un control deja un punto en el segundo actual

    private var index: Int? { session.project.lanes.firstIndex { $0.id == ref.laneId } }
    private var chain: Binding<ChainSettings> {
        Binding(get: { index.map { session.project.lanes[$0].effectiveChain } ?? ChainSettings() },
                set: { c in if let i = index { Lane.store(c, in: &session.project.lanes[i]) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Toggle(isOn: $writing) { Label("Escribir", systemImage: "record.circle") }
                    .toggleStyle(.button).tint(.red)
                    .help("Mientras está encendido, mover un control deja un punto en el segundo donde va el episodio (automatización)")
                Button("Listo") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if writing {
                Text("Escribiendo en \(EditEngine.clock(session.playheadTimeline)): cada control que muevas queda como punto en ese segundo. Reproduce y ve moviendo.")
                    .font(.caption).foregroundStyle(.red)
            }
            switch ref.kind {
            case .eq: EQEditor(chain: chain, writing: writing, playhead: { session.playheadTimeline })
            case .compressor: compressor
            case .deesser: deesser
            case .gate: gate
            }
            Text("Se oye al instante mientras suena; lo que oyes es lo que se exporta.").font(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(20)
        .frame(width: 620)
        .background(Theme.background)
    }

    private var title: String {
        let who = index.map { session.project.laneName(session.project.lanes[$0].id) } ?? ""
        switch ref.kind {
        case .eq: return "\(who) · Ecualizador paramétrico"
        case .compressor: return "\(who) · Compresor"
        case .deesser: return "\(who) · De-esser"
        case .gate: return "\(who) · Puerta"
        }
    }

    private var compressor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Activo", isOn: chain.compressorOn)
            param("Umbral", chain.threshold, -60...0, "%.0f dB", auto: ChainSettings.compThreshold)
            param("Relación", chain.ratio, 1...20, "%.1f:1", auto: ChainSettings.compRatio)
            param("Ataque", chain.attack, 0.001...0.1, "%.3f s")
            param("Salida", chain.release, 0.02...1.0, "%.2f s")
            param("Compensación", chain.makeup, 0...18, "%.0f dB", auto: ChainSettings.compMakeup)
            Text("«Voz pareja» del nivel simple = umbral −20, 3:1, ataque 8 ms, salida 140 ms, +4 dB.").font(.caption2).foregroundStyle(Theme.secondary)
        }
        .disabled(false)
    }

    private var deesser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Activo", isOn: chain.deesserOn)
            param("Cantidad", chain.deesserAmount, 0...1, "%.2f", auto: ChainSettings.deesserAmount)
            Text("Baja solo lo que silba por encima de 5 kHz. «Menos siseo» del nivel simple = 0,50.").font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    private var gate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Activa", isOn: chain.gateOn)
            param("Umbral", chain.gateThreshold, -80...(-20), "%.0f dB", auto: ChainSettings.gateThreshold)
            Text("Por debajo del umbral el sonido baja el doble (expansión 1:2): respiraciones y ruido de fondo entre frases. Distinta de «bajar a quien no habla», que sigue en Limpiar sonido.").font(.caption2).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func param(_ name: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String, auto: String? = nil) -> some View {
        let points = auto.flatMap { chain.wrappedValue.automation[$0] } ?? []
        // Con «Escribir» encendido, mover el control deja un punto en el segundo actual en vez de cambiar la base
        let bound: Binding<Double> = (writing && auto != nil)
            ? Binding(get: { chain.wrappedValue.value(of: auto!, at: session.playheadTimeline) ?? v.wrappedValue },
                      set: { nv in var c = chain.wrappedValue; c.writePoint(auto!, t: session.playheadTimeline, v: nv); chain.wrappedValue = c })
            : v
        return HStack {
            Text(name).frame(width: 110, alignment: .leading)
            Slider(value: bound, in: range)
            Text(String(format: fmt, bound.wrappedValue)).font(.callout.monospacedDigit()).frame(width: 74, alignment: .trailing)
            if let auto {
                if points.isEmpty {
                    Button { var c = chain.wrappedValue; c.writePoint(auto, t: session.playheadTimeline, v: v.wrappedValue); chain.wrappedValue = c } label: { Image(systemName: "a.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Dejar un punto de automatización en el segundo actual")
                } else {
                    Menu {
                        Button("Punto aquí (\(EditEngine.clock(session.playheadTimeline)))") { var c = chain.wrappedValue; c.writePoint(auto, t: session.playheadTimeline, v: bound.wrappedValue); chain.wrappedValue = c }
                        Button("Quitar la automatización (\(points.count) puntos)") { var c = chain.wrappedValue; c.automation[auto] = nil; chain.wrappedValue = c }
                    } label: {
                        Label("\(points.count)", systemImage: "a.circle.fill").foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Este parámetro sigue una curva: \(points.count) puntos")
                }
            }
        }
        .font(.callout)
    }
}

/// Ecualizador paramétrico: hasta 8 bandas, cada una con tipo, frecuencia, ganancia y ancho.
struct EQEditor: View {
    @Binding var chain: ChainSettings
    var writing = false
    var playhead: () -> Double = { 0 }

    private func gainBinding(_ i: Int) -> Binding<Double> {
        let b = chain.bands[i]
        let key = ChainSettings.bandGain(b)
        if writing {
            return Binding(get: { chain.value(of: key, at: playhead()) ?? b.gain },
                           set: { nv in chain.writePoint(key, t: playhead(), v: nv) })
        }
        return $chain.bands[i].gain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EQCurve(bands: chain.bands).frame(height: 150)
            ForEach(chain.bands.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Toggle("", isOn: $chain.bands[i].enabled).labelsHidden().toggleStyle(.checkbox)
                    Picker("", selection: $chain.bands[i].kind) {
                        ForEach(EQBand.Kind.allCases, id: \.self) { k in Text(EQBand(kind: k).label).tag(k) }
                    }
                    .labelsHidden().frame(width: 120)
                    Text("Frec").foregroundStyle(Theme.secondary)
                    Slider(value: Binding(get: { log10(chain.bands[i].freq) }, set: { chain.bands[i].freq = (pow(10, $0) * 10).rounded() / 10 }), in: log10(20)...log10(20_000)).frame(width: 120)
                    Text(freqLabel(chain.bands[i].freq)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                    if chain.bands[i].kind != .highpass && chain.bands[i].kind != .lowpass {
                        Text("Gan").foregroundStyle(Theme.secondary)
                        Slider(value: gainBinding(i), in: -18...18).frame(width: 100)
                        Text(String(format: "%+.1f", gainBinding(i).wrappedValue)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        if let pts = chain.automation[ChainSettings.bandGain(chain.bands[i])], !pts.isEmpty {
                            Menu {
                                Button("Quitar la automatización (\(pts.count) puntos)") { chain.automation[ChainSettings.bandGain(chain.bands[i])] = nil }
                            } label: { Label("\(pts.count)", systemImage: "a.circle.fill").foregroundStyle(Theme.accent) }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    Text("Q").foregroundStyle(Theme.secondary)
                    Slider(value: $chain.bands[i].q, in: 0.1...4).frame(width: 60)
                    Button {
                        let b = chain.bands[i]
                        chain.automation[ChainSettings.bandGain(b)] = nil; chain.automation[ChainSettings.bandFreq(b)] = nil
                        chain.bands.remove(at: i)
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
                .font(.callout)
            }
            HStack {
                Button("+ Banda") { chain.bands.append(EQBand(kind: .peak, freq: 1000, gain: 0, q: 1)) }
                    .disabled(chain.bands.count >= ChainSettings.maxBands)
                Text("hasta \(ChainSettings.maxBands)").font(.caption2).foregroundStyle(Theme.secondary)
                Spacer()
                Menu("Presets") {
                    Button("Voz clara") { chain.bands = ChainSettings.preset(VoiceEQ.preset("clear")).bands }
                    Button("Cálida") { chain.bands = ChainSettings.preset(VoiceEQ.preset("warm")).bands }
                    Button("Quitar retumbe") { chain.bands = ChainSettings.preset(VoiceEQ.preset("rumble")).bands }
                    Button("Plano") { chain.bands = [] }
                }
                .frame(width: 110)
            }
        }
    }

    private func freqLabel(_ f: Double) -> String { f >= 1000 ? String(format: "%.1f k", f / 1000) : String(format: "%.0f", f) }
}

/// La curva aproximada del ecualizador (dibujo orientativo, no la respuesta exacta del AU).
struct EQCurve: View {
    let bands: [EQBand]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                Path { p in
                    for db in [-12.0, 0, 12] {
                        let y = h / 2 - CGFloat(db / 24) * h
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(Theme.stroke, lineWidth: 1)
                Path { p in
                    var first = true
                    for px in stride(from: 0, through: Int(w), by: 2) {
                        let f = 20 * pow(1000, Double(px) / Double(w))   // 20 Hz … 20 kHz log
                        let db = gain(at: f)
                        let y = h / 2 - CGFloat(db / 24) * h
                        if first { p.move(to: CGPoint(x: CGFloat(px), y: y)); first = false } else { p.addLine(to: CGPoint(x: CGFloat(px), y: y)) }
                    }
                }
                .stroke(Theme.accent, lineWidth: 2)
                ForEach(bands.filter(\.enabled)) { b in
                    let x = CGFloat(log10(b.freq / 20) / 3) * w
                    let y = h / 2 - CGFloat(gain(at: b.freq) / 24) * h
                    Circle().fill(Theme.accent).frame(width: 8, height: 8).position(x: x, y: max(4, min(h - 4, y)))
                }
                HStack { Text("20").padding(.leading, 6); Spacer(); Text("200"); Spacer(); Text("2k"); Spacer(); Text("20k").padding(.trailing, 6) }
                    .font(.caption2.monospaced()).foregroundStyle(Theme.secondary).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 3)
            }
        }
    }

    /// Suma orientativa de las bandas (campanas gaussianas en octavas; estantes y pasos como rampas).
    private func gain(at f: Double) -> Double {
        var g = 0.0
        for b in bands where b.enabled {
            let oct = log2(f / b.freq)
            switch b.kind {
            case .peak: g += b.gain * exp(-(oct * oct) / (2 * max(0.05, b.q) * max(0.05, b.q)))
            case .lowshelf: g += b.gain * (1 - smooth(oct))
            case .highshelf: g += b.gain * smooth(oct)
            case .highpass: if oct < 0 { g += -12 * (-oct) }
            case .lowpass: if oct > 0 { g += -12 * oct }
            }
        }
        return max(-24, min(24, g))
    }
    private func smooth(_ x: Double) -> Double { 1 / (1 + exp(-x * 3)) }
}

struct OpenStudioButton: View {
    @Environment(\.openWindow) private var openWindow
    var label = "Abrir en Studio"
    var tab: StudioTab.Tab = .audio
    var body: some View {
        Button(label) { StudioTab.shared.tab = tab; openWindow(id: "estudio") }
            .keyboardShortcut("e", modifiers: tab == .audio ? [.command] : [.command, .shift])
    }
}
