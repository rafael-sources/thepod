import SwiftUI
import LiveKit

// MARK: - Estilo del cuarto de control

private enum CR {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.07)
    static let side = Color(red: 0.085, green: 0.085, blue: 0.105)
    static let field = Color(white: 1, opacity: 0.06)
    static let line = Color(white: 1, opacity: 0.08)
    static let sponsor = Color(red: 0.70, green: 0.45, blue: 1.0)
    static let podcast = Color.prodPod
    static let segment = Color(red: 0.40, green: 0.62, blue: 1.0)
}

/// Título de sección pequeño, en mayúsculas.
private struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.8).foregroundStyle(Theme.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.secondary) }
        }
    }
}

/// Opción tipo píldora (para elegir destino, duración, etc.).
private struct Pill: View {
    let text: String
    var symbol: String? = nil
    let selected: Bool
    var color: Color = .prodPod
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
                Text(text).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(selected ? Color.black : .white)
            .background(Capsule().fill(selected ? color : Color(white: 1, opacity: hover ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Botón grande y sólido del cuarto de control.
private struct CRButton: View {
    let title: String
    let symbol: String
    var color: Color = .prodPod
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(enabled ? Color.black : Theme.secondary)
                .background(RoundedRectangle(cornerRadius: 11).fill(enabled ? color.opacity(hover ? 1 : 0.9) : Color(white: 1, opacity: 0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Campo de texto con el estilo del cuarto de control.
private struct CRField: View {
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lines)
            .textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(CR.field))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CR.line))
            .onSubmit(onSubmit)
    }
}

// MARK: - Cuarto de control

struct DirectorView: View {
    @ObservedObject private var role = AccountRole.shared
    @EnvironmentObject var app: AppModel
    @ObservedObject var dir: DirectorStudio
    var preview = false
    @AppStorage("directorPestana") private var tab = 0
    @State private var seenChat = 0

    private let tabs: [(String, String)] = [("Cintillos", "rectangle.bottomthird.inset.filled"), (String(localized: "Avisos"), "megaphone.fill"),
                                            (String(localized: "Sala"), "person.2.fill"), (String(localized: "Chat"), "bubble.left.and.bubble.right.fill"),
                                            (String(localized: "Sonidos"), "speaker.wave.2.fill"), (String(localized: "Prompter"), "text.viewfinder")]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(CR.line).frame(height: 1)
                if dir.connected || preview { feedsGrid } else { connectPrompt }
                if !dir.overlays.isEmpty { onAirBar }
                ifbBar
            }
            .background(CR.bg)
            Rectangle().fill(CR.line).frame(width: 1)
            sidePanel.frame(width: 400).background(CR.side)
        }
        .tint(.prodPod)
        .onAppear { if !preview { dir.join() }; if tab == 3 { seenChat = dir.chat.count } }
        .onChange(of: dir.chat.count) { _, n in if tab == 3 { seenChat = n } }
        .alert("Algo salió mal", isPresented: Binding(get: { dir.error != nil }, set: { if !$0 { dir.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(dir.error ?? "") }
        .overlay(alignment: .top) {
            if let n = dir.note {
                Text(n).font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(CR.line))
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: dir.note)
    }

    private func close() { Task { await dir.leave(); app.director = nil } }

    // MARK: Barra superior

    private var readyCount: (Int, Int) {
        let hosts = dir.hostsInRoom
        return (hosts.filter { dir.readyMap["participant_\($0.id)"] == true }.count, hosts.count)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30).background(Circle().fill(CR.field))
            }
            .buttonStyle(.plain).help("Salir del cuarto de control")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("DIRECTOR").font(.system(size: 10, weight: .heavy)).kerning(0.6)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.prodPod)).foregroundStyle(.black)
                    if dir.practice { Chip(text: String(localized: "ENSAYO"), color: .yellow, filled: true) }
                    if !dir.podcastName.isEmpty {
                        Text(dir.podcastName).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Text(dir.session.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            .layoutPriority(-1)

            Spacer(minLength: 12)

            let (r, t) = readyCount
            if t > 0 {
                HStack(spacing: 5) {
                    Image(systemName: r == t ? "checkmark.circle.fill" : "hourglass").font(.caption.weight(.bold))
                    Text("\(r)/\(t) preparados").font(.callout.weight(.semibold)).fixedSize()
                }
                .foregroundStyle(r == t ? Theme.good : Theme.secondary)
            }

            HStack(spacing: 8) {
                Circle().fill(dir.recording ? Color.prodPod : Color(white: 1, opacity: 0.25)).frame(width: 9, height: 9)
                if let c = dir.countdown {
                    Text("Empieza en \(c)").font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(Color.prodPod)
                } else {
                    Text(String(format: "%d:%02d", dir.recSeconds / 60, dir.recSeconds % 60))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(dir.recording ? .white : Theme.secondary)
                }
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Capsule().fill(dir.recording ? Color.prodPod.opacity(0.18) : CR.field))
            .fixedSize()

            recordButton
        }
        .padding(.horizontal, 18).frame(height: 64)
    }

    private var recordButton: some View {
        let canStart = dir.allHostsReady && dir.countdown == nil && dir.connected
        return Button {
            dir.recording ? dir.stopRecording() : dir.startRecording()
        } label: {
            Label(dir.recording ? String(localized: "Detener") : String(localized: "Grabar"), systemImage: dir.recording ? "stop.fill" : "record.circle")
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 18).frame(height: 36)
                .foregroundStyle(dir.recording || canStart ? Color.black : Theme.secondary)
                .background(Capsule().fill(dir.recording ? Color.white : canStart ? Color.prodPod : CR.field))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(!dir.recording && !canStart)
        .help(dir.recording ? String(localized: "Detiene la grabación de todos")
              : dir.allHostsReady ? String(localized: "Empieza la cuenta regresiva para todos")
              : String(localized: "Se habilita cuando todos los conductores en la sala marquen Preparado"))
    }

    private var connectPrompt: some View {
        VStack(spacing: 14) {
            if dir.joining { ProgressView("Entrando al cuarto de control…") }
            else {
                Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(Theme.secondary)
                Button("Entrar como director") { dir.join() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Cámaras

    private struct Tile: Identifiable {
        let id: String; let name: String; let video: VideoTrack?; let speaking: Bool; let micOn: Bool; let ready: Bool; let isScreen: Bool
    }

    private var feedsGrid: some View {
        let tiles: [Tile] = dir.feeds.flatMap { f -> [Tile] in
            var t = [Tile(id: f.id, name: f.name, video: f.camera, speaking: f.speaking, micOn: f.micOn,
                          ready: dir.readyMap[f.id] == true, isScreen: false)]
            if let s = f.screen { t.append(Tile(id: f.id + "-screen", name: String(localized: "Pantalla de \(f.name)"), video: s, speaking: false, micOn: true, ready: false, isScreen: true)) }
            return t
        }
        let cols = tiles.count <= 1 ? 1 : 2
        return GeometryReader { geo in
            ScrollView {
                if tiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.rectangle.stack").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                        Text("Todavía no hay nadie en la sala.").foregroundStyle(Theme.secondary)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols), spacing: 12) {
                        ForEach(tiles) { t in feedTile(t) }
                    }
                    .padding(16)
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedTile(_ t: Tile) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1))
            if let v = t.video { SwiftUIVideoView(v, layoutMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)) }
            else { Avatar(name: t.name, size: 72).frame(maxWidth: .infinity, maxHeight: .infinity) }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
            HStack(spacing: 7) {
                Image(systemName: t.isScreen ? "rectangle.on.rectangle" : t.micOn ? "mic.fill" : "mic.slash.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(t.micOn ? .white : .red)
                Text(t.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if t.ready {
                    Text("PREPARADO").font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.good)).foregroundStyle(.black)
                }
            }
            .padding(12)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(t.speaking ? Theme.good : CR.line, lineWidth: t.speaking ? 3 : 1))
    }

    // MARK: Al aire

    private var onAirBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.prodPod).frame(width: 7, height: 7)
                Text("AL AIRE").font(.system(size: 11, weight: .heavy)).kerning(0.8).foregroundStyle(Color.prodPod)
                Text("lo que ven los conductores y queda en la grabación").font(.caption).foregroundStyle(Theme.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(dir.overlays) { o in
                        HStack(spacing: 10) {
                            Cintillo(overlay: o, scale: 0.55).fixedSize()
                            VStack(spacing: 6) {
                                if let e = o.expires {
                                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                        Text(String(localized: "\(max(0, Int(e.timeIntervalSince(ctx.date))))s"))
                                            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.secondary)
                                    }
                                }
                                Button { dir.removeOverlay(o) } label: {
                                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                        .frame(width: 26, height: 26).background(Circle().fill(CR.field))
                                }
                                .buttonStyle(.plain).help("Quitar de pantalla")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prodPod.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(CR.line).frame(height: 1) }
        .animation(.spring(duration: 0.35), value: dir.overlays)
    }

    // MARK: Hablar al oído

    private var ifbBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Label("Hablar al oído", systemImage: "headphones").font(.callout.weight(.semibold))
                Text("mantén presionado").font(.caption).foregroundStyle(Theme.secondary)
            }
            .padding(.trailing, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HoldButton(title: String(localized: "Todos los conductores"), active: dir.ifbTarget == "all_hosts") { down in
                        down ? dir.ifbPress("all_hosts") : dir.ifbRelease()
                    }
                    ForEach(dir.hostsInRoom) { p in
                        HoldButton(title: p.display_name, active: dir.ifbTarget == "participant_\(p.id)") { down in
                            down ? dir.ifbPress("participant_\(p.id)") : dir.ifbRelease()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18).frame(height: 62)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .top) { Rectangle().fill(CR.line).frame(height: 1) }
        .disabled(!dir.connected && !preview)
    }

    // MARK: Panel lateral

    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                    if i == 4 && dir.sounds.isEmpty { EmptyView() } else {
                        Button { tab = i; if i == 3 { seenChat = dir.chat.count } } label: {
                            VStack(spacing: 4) {
                                Image(systemName: t.1).font(.system(size: 15, weight: .semibold))
                                    .overlay(alignment: .topTrailing) {
                                        if i == 3 && dir.chat.count > seenChat && tab != 3 {
                                            Circle().fill(Color.prodPod).frame(width: 8, height: 8).offset(x: 6, y: -3)
                                        }
                                    }
                                Text(t.0).font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(tab == i ? Color.white : Theme.secondary)
                            .background(RoundedRectangle(cornerRadius: 9).fill(tab == i ? CR.field : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
            Rectangle().fill(CR.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 1: CuesPanel(dir: dir)
                    case 2: roomPanel
                    case 3: DirectorChatPanel(dir: dir)
                    case 4: soundsPanel
                    case 5: TeleprompterPanel(dir: dir)
                    default: CintillosPanel(dir: dir)
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: Sala: personas y pistas

    private var roomPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: String(localized: "Personas"))
                let people = dir.participants.filter { $0.role != "director" }
                if people.isEmpty { Text("Nadie invitado todavía.").font(.callout).foregroundStyle(Theme.secondary) }
                ForEach(people) { p in personRow(p) }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: String(localized: "Pistas grabadas"))
                if dir.uploads.isEmpty {
                    Text(dir.recording ? String(localized: "Esperando que empiecen a subir…") : String(localized: "Aparecen al grabar.")).font(.callout).foregroundStyle(Theme.secondary)
                }
                ForEach(dir.uploads.sorted(by: { $0.key < $1.key }), id: \.key) { id, st in
                    let name = dir.feeds.first { $0.id == id }?.name ?? dir.participants.first { "participant_\($0.id)" == id }?.display_name ?? id
                    let mb = Double(dir.uploadBytes[id] ?? 0) / 1_048_576
                    HStack {
                        Image(systemName: st == "done" ? "checkmark.circle.fill" : st == "error" ? "exclamationmark.triangle.fill" : "arrow.up.circle")
                            .foregroundStyle(st == "done" ? Theme.good : st == "error" ? .red : Theme.secondary)
                        Text(name).font(.callout)
                        Spacer()
                        Text(st == "error" ? String(localized: "Error") : String(format: "%.0f MB", mb))
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(CR.field))
                }
                if !dir.recording && dir.allUploadsDone && role.isAdmin {
                    CRButton(title: dir.exporting ? String(localized: "Enviando…") : String(localized: "Enviar a post"), symbol: "paperplane.fill", color: Theme.good,
                              enabled: !dir.exporting) { dir.exportToPost() }
                }
                if let r = dir.exportResult { Text(r).font(.caption).foregroundStyle(Theme.good) }
            }
        }
    }

    private func personRow(_ p: ProdPodClient.Person) -> some View {
        let id = "participant_\(p.id)"
        let inRoom = dir.feeds.contains { $0.id == id }
        let ready = dir.readyMap[id] == true
        return HStack(spacing: 10) {
            Avatar(name: p.display_name, size: 32)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(inRoom ? Theme.good : Color(white: 0.4)).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(CR.side, lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.display_name).font(.callout.weight(.semibold)).lineLimit(1)
                Text([p.roleTitle, inRoom ? (ready ? "preparado" : String(localized: "en la sala")) : "fuera",
                      p.recording_quality.map { String(localized: "graba en \($0)") }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(ready ? Theme.good : Theme.secondary).lineLimit(1)
            }
            Spacer()
            if inRoom {
                iconAction("mic.slash.fill", help: String(localized: "Silenciar a \(p.display_name)")) { dir.forceMute(p) }
                iconAction("person.fill.xmark", color: .red, help: String(localized: "Sacar a \(p.display_name)")) { dir.kick(p) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(CR.field))
    }

    private func iconAction(_ symbol: String, color: Color = .white, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .frame(width: 30, height: 30).background(Circle().fill(Color(white: 1, opacity: 0.08)))
        }
        .buttonStyle(.plain).help(help)
    }

    private var soundsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: String(localized: "Soundboard"), trailing: String(localized: "suena en la sala"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(dir.sounds) { pad in
                    let c = pad.color.map { Color(hex: $0) } ?? .gray
                    Button { dir.trigger(pad) } label: {
                        Text(pad.name).font(.callout.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 56).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(c.opacity(0.22)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(c.opacity(0.5)))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Botón que funciona mientras se mantiene presionado.
struct HoldButton: View {
    let title: String
    let active: Bool
    let change: (Bool) -> Void
    @State private var down = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: active ? "waveform" : "mic.fill").font(.caption.weight(.bold))
            Text(title).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(Capsule().fill(active ? Color.prodPod : Color(white: 1, opacity: 0.08)))
        .overlay(Capsule().strokeBorder(active ? Color.clear : Color(white: 1, opacity: 0.1)))
        .foregroundStyle(active ? .black : .white)
        .fixedSize()
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; change(true) } }
            .onEnded { _ in down = false; change(false) })
    }
}

// MARK: - Cintillos

struct CintillosPanel: View {
    @ObservedObject var dir: DirectorStudio
    @State private var mode = 0
    @State private var sponsorId: Int?
    @State private var sponsorText = ""
    @State private var podTitle = ""
    @State private var podText = ""
    @State private var segTitle = ""
    @State private var segSub = ""
    @State private var seconds: Double = 15

    private let kinds: [(String, String, Color)] = [("Sponsor", "star.fill", CR.sponsor), (String(localized: "Podcast"), "mic.fill", CR.podcast),
                                                    (String(localized: "Segmento"), "text.alignleft", CR.segment)]
    private var accent: Color { kinds[mode].2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { i, k in
                    Button { mode = i } label: {
                        VStack(spacing: 5) {
                            Image(systemName: k.1).font(.system(size: 15, weight: .bold))
                            Text(k.0).font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .foregroundStyle(mode == i ? Color.black : .white)
                        .background(RoundedRectangle(cornerRadius: 10).fill(mode == i ? k.2 : CR.field))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            previewBox

            switch mode {
            case 0: sponsorForm
            case 1: podcastForm
            default: segmentForm
            }

            if mode != 2 {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: String(localized: "Tiempo en pantalla"))
                    HStack(spacing: 6) {
                        ForEach([(8.0, "8 s"), (15.0, "15 s"), (30.0, "30 s"), (0.0, String(localized: "Hasta quitarlo"))], id: \.0) { v, l in
                            Pill(text: l, selected: seconds == v, color: accent) { seconds = v }
                        }
                    }
                }
            }

            CRButton(title: String(localized: "Poner al aire"), symbol: "play.fill", color: accent, enabled: dir.connected && canLaunch) { launch() }
        }
        .onAppear { if podTitle.isEmpty { podTitle = dir.podcastName } }
        .onChange(of: dir.podcastName) { _, v in if podTitle.isEmpty { podTitle = v } }
    }

    /// Vista previa sobre un fondo tipo pantalla, a escala.
    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Vista previa"))
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
                Cintillo(overlay: previewOverlay, scale: 0.5).padding(12)
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CR.line))
        }
    }

    private var previewOverlay: Overlay {
        switch mode {
        case 0:
            let s = sponsor
            return Overlay(id: -1, kind: "sponsor", title: s?.name ?? String(localized: "Sponsor"), text: sponsorText, filePath: nil,
                           image: s.flatMap { dir.sponsorLogo($0) }, expires: nil)
        case 1:
            return Overlay(id: -2, kind: "banner", title: podTitle.isEmpty ? dir.podcastName : podTitle,
                           text: podText.isEmpty ? String(localized: "Lo que quieras decir ahora") : podText, filePath: nil, image: dir.podcastLogo, expires: nil)
        default:
            return Overlay(id: -3, kind: "segment", title: segTitle.isEmpty ? String(localized: "Título del segmento") : segTitle,
                           text: segSub, filePath: nil, image: nil, expires: nil)
        }
    }

    private var sponsor: DirectorStudio.SponsorInfo? { dir.sponsors.first { $0.id == sponsorId } ?? dir.sponsors.first }

    private var canLaunch: Bool {
        switch mode {
        case 0: return sponsor != nil
        case 1: return !podText.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !segTitle.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    @ViewBuilder private var sponsorForm: some View {
        if dir.sponsors.isEmpty {
            Text("Este podcast no tiene sponsors activos en prePod.").font(.callout).foregroundStyle(Theme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Sponsor"))
                VStack(spacing: 6) {
                    ForEach(dir.sponsors) { s in
                        let on = sponsor?.id == s.id
                        Button { sponsorId = s.id; sponsorText = s.copy } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(.white)
                                    if let img = dir.sponsorLogo(s) { Image(nsImage: img).resizable().scaledToFit().padding(3) }
                                    else { Text(String(s.name.prefix(1))).font(.headline.weight(.black)).foregroundStyle(CR.sponsor) }
                                }
                                .frame(width: 34, height: 34)
                                Text(s.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer()
                                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(CR.sponsor) }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(on ? CR.sponsor.opacity(0.14) : CR.field))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? CR.sponsor.opacity(0.6) : .clear))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onAppear { if sponsorText.isEmpty { sponsorText = sponsor?.copy ?? "" } }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Texto"))
                CRField(placeholder: String(localized: "Texto del cintillo"), text: $sponsorText, lines: 2...3)
            }
        }
    }

    @ViewBuilder private var podcastForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Título"))
            CRField(placeholder: dir.podcastName.isEmpty ? String(localized: "Nombre del podcast") : dir.podcastName, text: $podTitle)
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Qué decir ahora"))
            CRField(placeholder: String(localized: "Ej.: Síguenos en todas las plataformas"), text: $podText, lines: 2...3)
        }
    }

    @ViewBuilder private var segmentForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Título del segmento"))
            CRField(placeholder: String(localized: "Ej.: La pregunta de la semana"), text: $segTitle)
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: String(localized: "Subtítulo"), trailing: "opcional")
            CRField(placeholder: String(localized: "Una línea que lo explique"), text: $segSub)
        }
        Text("El segmento se queda en pantalla 12 segundos.").font(.caption).foregroundStyle(Theme.secondary)
    }

    private func launch() {
        switch mode {
        case 0: if let s = sponsor { dir.showSponsor(s, text: sponsorText.isEmpty ? s.copy : sponsorText, seconds: seconds) }
        case 1: dir.showPodcast(title: podTitle, text: podText, seconds: seconds)
        default: dir.showSegment(title: segTitle, subtitle: segSub)
        }
    }
}

// MARK: - Avisos

struct CuesPanel: View {
    @ObservedObject var dir: DirectorStudio
    @State private var target = "all"
    @State private var custom = ""
    @State private var guestsSee = false
    @State private var sent: String?

    static let look: [String: (String, String, Color)] = [
        String(localized: "CERRAR TEMA"): (String(localized: "Cerrar tema"), "flag.checkered", Color.orange),
        String(localized: "SIGUIENTE TEMA"): (String(localized: "Siguiente tema"), "forward.end.fill", CR.segment),
        String(localized: "PAUSA"): (String(localized: "Pausa"), "pause.fill", Color.yellow),
        String(localized: "MÁS RÁPIDO"): (String(localized: "Más rápido"), "hare.fill", Theme.good),
        String(localized: "MÁS LENTO"): (String(localized: "Más lento"), "tortoise.fill", Color.teal),
        String(localized: "LEER ANUNCIO"): (String(localized: "Leer anuncio"), "megaphone.fill", CR.sponsor),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Para"))
                FlowPills(items: [("all", String(localized: "Todos"))] + dir.hostsInRoom.map { ("participant_\($0.id)", $0.display_name) },
                          selected: $target)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Avisos rápidos"), trailing: String(localized: "salen en su pantalla"))
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(DirectorStudio.cues, id: \.self) { c in cueTile(c) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Aviso escrito"))
                HStack(spacing: 8) {
                    CRField(placeholder: String(localized: "Ej.: Faltan 5 minutos"), text: $custom) { sendCustom() }
                    Button { sendCustom() } label: {
                        Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 9).fill(custom.isEmpty ? CR.field : Color.prodPod))
                            .foregroundStyle(custom.isEmpty ? Theme.secondary : .black)
                    }
                    .buttonStyle(.plain).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Toggle("Los invitados también ven los avisos", isOn: $guestsSee)
                .toggleStyle(.switch).controlSize(.small).font(.callout)
                .onChange(of: guestsSee) { _, v in dir.setGuestCues(v) }
        }
        .disabled(!dir.connected)
    }

    private func sendCustom() {
        let t = custom.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        dir.sendCue("CUSTOM", text: t, target: target); custom = ""
    }

    private func cueTile(_ c: String) -> some View {
        let l = Self.look[c] ?? (c.capitalized, "bell.fill", Color.gray)
        let justSent = sent == c
        return Button {
            dir.sendCue(c, target: target)
            sent = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if sent == c { sent = nil } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: justSent ? "checkmark" : l.1).font(.system(size: 15, weight: .bold))
                    .foregroundStyle(justSent ? Color.black : l.2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(justSent ? l.2 : l.2.opacity(0.16)))
                Text(justSent ? String(localized: "Enviado") : l.0).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 11).fill(CR.field))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(justSent ? l.2 : CR.line))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: justSent)
    }
}

// MARK: - Teleprompter

struct TeleprompterPanel: View {
    @ObservedObject var dir: DirectorStudio
    @State private var target = "all"
    @State private var sponsorId: Int?
    @State private var title = ""
    @State private var text = ""
    @State private var speed = "normal"
    @State private var size = "half"
    @State private var countdown = 3
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Para"), trailing: String(localized: "todos ven el aviso; el texto solo quien lo lee"))
                FlowPills(items: [("all", String(localized: "Todos"))] + dir.hostsInRoom.map { ("participant_\($0.id)", $0.display_name) },
                          selected: $target)
            }
            if !dir.sponsors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: String(localized: "Texto de un sponsor (prePod)"))
                    FlowPills(items: dir.sponsors.map { ("\($0.id)", $0.name) },
                              selected: Binding(get: { sponsorId.map(String.init) ?? "" },
                                                set: { v in
                                                    sponsorId = Int(v)
                                                    if let s = dir.sponsors.first(where: { "\($0.id)" == v }) {
                                                        title = String(localized: "Publicidad de \(s.name)")
                                                        text = s.copy.isEmpty ? String(localized: "Sponsor: \(s.name)") : s.copy
                                                    }
                                                }))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Título del aviso"))
                CRField(placeholder: String(localized: "Ej.: Publicidad de Café Loma Verde"), text: $title)
                SectionTitle(text: String(localized: "Texto que va a leer"))
                CRField(placeholder: String(localized: "Escribe o pega el texto…"), text: $text, lines: 4...10)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: String(localized: "Velocidad"))
                    HStack(spacing: 6) {
                        ForEach([("slow", String(localized: "Lenta")), ("normal", String(localized: "Normal")), ("fast", String(localized: "Rápida"))], id: \.0) { v, l in
                            Pill(text: l, selected: speed == v) { speed = v }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: String(localized: "Tamaño"))
                    HStack(spacing: 6) {
                        ForEach([("quarter", String(localized: "¼ pantalla")), ("half", String(localized: "½ pantalla")), ("full", String(localized: "Toda"))], id: \.0) { v, l in
                            Pill(text: l, selected: size == v) { size = v }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: String(localized: "Aviso previo"))
                HStack(spacing: 6) {
                    ForEach([(0, String(localized: "Sin aviso")), (3, "3 s"), (5, "5 s"), (10, "10 s")], id: \.0) { v, l in
                        Pill(text: l, selected: countdown == v) { countdown = v }
                    }
                }
            }
            HStack(spacing: 8) {
                CRButton(title: sent ? String(localized: "Enviado") : String(localized: "Lanzar teleprompter"), symbol: sent ? "checkmark" : "text.viewfinder",
                         enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    dir.sendTeleprompter(target: target, title: title, text: text, speed: speed, size: size, countdown: countdown)
                    sent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sent = false }
                }
                Button { dir.hideTeleprompter() } label: {
                    Label("Quitar", systemImage: "xmark").font(.system(size: 14, weight: .bold))
                        .frame(width: 100, height: 44)
                        .background(RoundedRectangle(cornerRadius: 11).fill(CR.field))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Text("Los teleprompter marcados en el guion de prePod salen solos al minuto indicado, sin que hagas nada.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .disabled(!dir.connected)
    }
}

/// Píldoras que bajan de línea si no caben.
private struct FlowPills: View {
    let items: [(String, String)]
    @Binding var selected: String
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.0) { id, name in
                Pill(text: name, symbol: id == "all" ? "person.3.fill" : nil, selected: selected == id) { selected = id }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > w { x = 0; y += row + spacing; row = 0 }
            x += z.width + spacing; row = max(row, z.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > b.minX && x + z.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

// MARK: - Chat de dirección

struct DirectorChatPanel: View {
    @ObservedObject var dir: DirectorStudio
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: String(localized: "Chat de dirección"), trailing: String(localized: "los conductores lo ven como aviso"))
            VStack(alignment: .leading, spacing: 8) {
                if dir.chat.isEmpty {
                    Text("Todavía no hay mensajes.").font(.callout).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                ForEach(dir.chat, id: \.id) { m in
                    HStack(alignment: .top, spacing: 8) {
                        Avatar(name: m.author, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.author).font(.caption.bold()).foregroundStyle(Theme.secondary)
                            Text(m.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(CR.field))
                }
            }
            HStack(spacing: 8) {
                CRField(placeholder: String(localized: "Escribe…"), text: $text) { send() }
                Button { send() } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(text.isEmpty ? CR.field : Color.prodPod))
                        .foregroundStyle(text.isEmpty ? Theme.secondary : .black)
                }
                .buttonStyle(.plain)
            }
        }
    }
    private func send() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        dir.sendChat(t); text = ""
    }
}
