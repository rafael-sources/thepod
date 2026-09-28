import SwiftUI
import LiveKit

/// Cuarto de control del director.
struct DirectorView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var dir: DirectorStudio

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Divider()
                if dir.connected { feedsGrid } else { connectPrompt }
                Divider()
                ifbBar
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CintillosCard(dir: dir)
                    CuesCard(dir: dir)
                    peopleCard
                    uploadsCard
                    DirectorChatCard(dir: dir)
                    if !dir.sounds.isEmpty { soundsCard }
                }
                .padding(16)
            }
            .frame(width: 390)
            .background(Color.black.opacity(0.25))
        }
        .tint(.prodPod)
        .onAppear { dir.join() }
        .alert("Algo salió mal", isPresented: Binding(get: { dir.error != nil }, set: { if !$0 { dir.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(dir.error ?? "") }
        .overlay(alignment: .top) {
            if let n = dir.note {
                Text(n).font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.75))).padding(.top, 60)
            }
        }
    }

    private func close() { Task { await dir.leave(); app.director = nil } }

    // MARK: Barra superior

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
            Text("DIRECTOR").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.prodPod)).foregroundStyle(.black)
            Text(dir.session.title).font(.headline).lineLimit(1)
            if dir.practice { Chip(text: "ENSAYO", color: .yellow, filled: true) }
            Spacer()
            Text(String(format: "%d:%02d", dir.recSeconds / 60, dir.recSeconds % 60))
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(dir.recording ? Color.prodPod : Theme.secondary)
            if let c = dir.countdown {
                Text("\(c)").font(.title.weight(.black)).foregroundStyle(Color.prodPod).frame(width: 40)
            }
            if dir.recording {
                Button { dir.stopRecording() } label: { Label("Detener", systemImage: "stop.fill").font(.headline) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button { dir.startRecording() } label: { Label("Grabar", systemImage: "record.circle").font(.headline) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!dir.allHostsReady || dir.countdown != nil || !dir.connected)
                    .help(dir.allHostsReady ? "Empieza la cuenta regresiva para todos"
                                            : "Se habilita cuando todos los conductores en la sala marquen Preparado")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            if dir.joining { ProgressView("Entrando al cuarto de control…") }
            else {
                Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(Theme.secondary)
                Button("Entrar como director") { dir.join() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Cámaras

    private var feedsGrid: some View {
        let tiles: [(String, String, VideoTrack?, Bool, Bool, Bool)] = dir.feeds.flatMap { f -> [(String, String, VideoTrack?, Bool, Bool, Bool)] in
            var t = [(f.id, f.name, f.camera, f.speaking, f.micOn, dir.readyMap[f.id] == true)]
            if let s = f.screen { t.append((f.id + "-screen", "Pantalla de \(f.name)", s, false, true, false)) }
            return t
        }
        return ZStack(alignment: .bottomLeading) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
                    ForEach(tiles, id: \.0) { t in
                        ZStack(alignment: .bottomLeading) {
                            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.08))
                            if let v = t.2 { SwiftUIVideoView(v, layoutMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)) }
                            else { Avatar(name: t.1, size: 60).frame(maxWidth: .infinity, maxHeight: .infinity) }
                            HStack(spacing: 6) {
                                Image(systemName: t.4 ? "mic.fill" : "mic.slash.fill").foregroundStyle(t.4 ? .white : .red)
                                Text(t.1).font(.callout.weight(.semibold))
                                if t.5 { Text("PREPARADO").font(.caption2.weight(.heavy)).foregroundStyle(Theme.good) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.6))).padding(8)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(t.3 ? Theme.good : Theme.stroke, lineWidth: t.3 ? 3 : 1))
                    }
                }
                .padding(16)
                if tiles.isEmpty {
                    Text("Todavía no hay nadie en la sala.").foregroundStyle(Theme.secondary).padding(40)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(dir.overlays) { o in Cintillo(overlay: o, scale: 0.8) }
            }
            .padding(24)
            .animation(.spring(duration: 0.4), value: dir.overlays)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hablar al oído

    private var ifbBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones").foregroundStyle(Theme.secondary)
            Text("Hablar al oído (mantén presionado):").font(.callout).foregroundStyle(Theme.secondary)
            HoldButton(title: "A todos los conductores", active: dir.ifbTarget == "all_hosts") { down in
                down ? dir.ifbPress("all_hosts") : dir.ifbRelease()
            }
            ForEach(dir.hostsInRoom) { p in
                HoldButton(title: p.display_name, active: dir.ifbTarget == "participant_\(p.id)") { down in
                    down ? dir.ifbPress("participant_\(p.id)") : dir.ifbRelease()
                }
            }
            Spacer()
        }
        .padding(12)
        .disabled(!dir.connected)
    }

    // MARK: Personas, subidas, sonidos

    private var peopleCard: some View {
        Card {
            Label("Personas", systemImage: "person.2").font(.headline)
            ForEach(dir.participants.filter { $0.role != "director" }) { p in
                let id = "participant_\(p.id)"
                let inRoom = dir.feeds.contains { $0.id == id }
                HStack(spacing: 8) {
                    Avatar(name: p.display_name, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.display_name).font(.callout.weight(.semibold))
                        Text([p.roleTitle, inRoom ? "en la sala" : "fuera", dir.readyMap[id] == true ? "preparado" : nil,
                              p.recording_quality.map { "REC \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(dir.readyMap[id] == true ? Theme.good : Theme.secondary)
                    }
                    Spacer()
                    if inRoom {
                        Button { dir.forceMute(p) } label: { Image(systemName: "mic.slash") }
                            .buttonStyle(.borderless).help("Silenciar a \(p.display_name)")
                        Button { dir.kick(p) } label: { Image(systemName: "person.fill.xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.red).help("Sacar a \(p.display_name)")
                    }
                }
            }
        }
    }

    private var uploadsCard: some View {
        Card {
            Label("Pistas", systemImage: "arrow.up.circle").font(.headline)
            if dir.uploads.isEmpty {
                Text(dir.recording ? "Esperando que empiecen a subir…" : "Aparecen al grabar.").font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(dir.uploads.sorted(by: { $0.key < $1.key }), id: \.key) { id, st in
                let name = dir.feeds.first { $0.id == id }?.name ?? dir.participants.first { "participant_\($0.id)" == id }?.display_name ?? id
                let mb = Double(dir.uploadBytes[id] ?? 0) / 1_048_576
                HStack {
                    Text(name).font(.callout)
                    Spacer()
                    Text(st == "done" ? "✓ \(String(format: "%.0f", mb)) MB" : st == "error" ? "Error" : "↑ \(String(format: "%.0f", mb)) MB")
                        .font(.caption.monospacedDigit()).foregroundStyle(st == "done" ? Theme.good : st == "error" ? .red : Theme.secondary)
                }
            }
            if !dir.recording && dir.allUploadsDone {
                Button { dir.exportToPost() } label: {
                    Label(dir.exporting ? "Enviando…" : "Enviar a post", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(dir.exporting)
            }
            if let r = dir.exportResult { Text(r).font(.caption).foregroundStyle(Theme.good) }
        }
    }

    private var soundsCard: some View {
        Card {
            Label("Soundboard", systemImage: "speaker.wave.3.fill").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                ForEach(dir.sounds) { pad in
                    Button { dir.trigger(pad) } label: {
                        Text(pad.name).font(.caption.weight(.semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill((pad.color.map { Color(hex: $0) } ?? .gray).opacity(0.55)))
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
        Text(title).font(.callout.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(active ? Color.prodPod : Color(white: 1, opacity: 0.12)))
            .foregroundStyle(active ? .black : .white)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; change(true) } }
                .onEnded { _ in down = false; change(false) })
    }
}

// MARK: - Cintillos

struct CintillosCard: View {
    @ObservedObject var dir: DirectorStudio
    @State private var mode = 0
    @State private var sponsorId: Int?
    @State private var sponsorText = ""
    @State private var podTitle = ""
    @State private var podText = ""
    @State private var segTitle = ""
    @State private var segSub = ""
    @State private var seconds: Double = 15

    var body: some View {
        Card {
            Label("Cintillos", systemImage: "rectangle.bottomthird.inset.filled").font(.headline)
            Picker("", selection: $mode) {
                Text("Sponsor").tag(0); Text("Podcast").tag(1); Text("Segmento").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()

            switch mode {
            case 0: sponsorForm
            case 1: podcastForm
            default: segmentForm
            }

            if mode != 2 {
                Picker("En pantalla", selection: $seconds) {
                    Text("8 s").tag(8.0); Text("15 s").tag(15.0); Text("30 s").tag(30.0); Text("Hasta quitarlo").tag(0.0)
                }
                .pickerStyle(.segmented)
            }

            Button { launch() } label: { Label("Poner al aire", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!dir.connected || !canLaunch)

            if !dir.overlays.isEmpty {
                Text("Al aire ahora").font(.caption.bold()).foregroundStyle(Theme.secondary)
                ForEach(dir.overlays) { o in
                    HStack {
                        Circle().fill(o.accent).frame(width: 8, height: 8)
                        Text(o.title).font(.caption).lineLimit(1)
                        Spacer()
                        Button("Quitar") { dir.removeOverlay(o) }.controlSize(.small)
                    }
                }
            }
        }
        .onAppear { if podTitle.isEmpty { podTitle = dir.podcastName } }
        .onChange(of: dir.podcastName) { _, v in if podTitle.isEmpty { podTitle = v } }
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
            Text("Este podcast no tiene sponsors activos en prePod.").font(.caption).foregroundStyle(Theme.secondary)
        } else {
            Picker("Sponsor", selection: Binding(get: { sponsor?.id ?? 0 }, set: { v in
                sponsorId = v
                sponsorText = dir.sponsors.first { $0.id == v }?.copy ?? ""
            })) {
                ForEach(dir.sponsors) { s in Text(s.name).tag(s.id) }
            }
            .onAppear { if sponsorText.isEmpty { sponsorText = sponsor?.copy ?? "" } }
            TextField("Texto del cintillo", text: $sponsorText, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
            if let s = sponsor {
                Cintillo(overlay: Overlay(id: -1, kind: "sponsor", title: s.name, text: sponsorText, filePath: nil,
                                          image: dir.sponsorLogo(s), expires: nil), scale: 0.45)
            }
        }
    }

    @ViewBuilder private var podcastForm: some View {
        TextField("Título (por defecto, el nombre del podcast)", text: $podTitle).textFieldStyle(.roundedBorder)
        TextField("Qué decir ahora", text: $podText, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
        Cintillo(overlay: Overlay(id: -2, kind: "banner", title: podTitle.isEmpty ? dir.podcastName : podTitle,
                                  text: podText, filePath: nil, image: dir.podcastLogo, expires: nil), scale: 0.45)
    }

    @ViewBuilder private var segmentForm: some View {
        TextField("Título del segmento", text: $segTitle).textFieldStyle(.roundedBorder)
        TextField("Subtítulo (opcional)", text: $segSub).textFieldStyle(.roundedBorder)
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

struct CuesCard: View {
    @ObservedObject var dir: DirectorStudio
    @State private var target = "all"
    @State private var custom = ""
    @State private var guestsSee = false

    var body: some View {
        Card {
            Label("Avisos a los conductores", systemImage: "megaphone").font(.headline)
            Picker("Para", selection: $target) {
                Text("Todos").tag("all")
                ForEach(dir.hostsInRoom) { p in Text(p.display_name).tag("participant_\(p.id)") }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(DirectorStudio.cues, id: \.self) { c in
                    Button(c) { dir.sendCue(c, target: target) }.frame(maxWidth: .infinity)
                }
            }
            HStack {
                TextField("Aviso escrito…", text: $custom).textFieldStyle(.roundedBorder)
                    .onSubmit { dir.sendCue("CUSTOM", text: custom, target: target); custom = "" }
                Button("Enviar") { dir.sendCue("CUSTOM", text: custom, target: target); custom = "" }
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle("Los invitados también ven los avisos", isOn: $guestsSee)
                .toggleStyle(.checkbox).font(.caption)
                .onChange(of: guestsSee) { _, v in dir.setGuestCues(v) }
        }
        .disabled(!dir.connected)
    }
}

struct DirectorChatCard: View {
    @ObservedObject var dir: DirectorStudio
    @State private var text = ""
    var body: some View {
        Card {
            Label("Chat de dirección", systemImage: "bubble.left.and.bubble.right").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(dir.chat, id: \.id) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.author).font(.caption2.bold()).foregroundStyle(Theme.secondary)
                            Text(m.text).font(.callout)
                        }
                    }
                    if dir.chat.isEmpty { Text("Los conductores lo ven como aviso.").font(.caption).foregroundStyle(Theme.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 110)
            HStack {
                TextField("Escribe…", text: $text).textFieldStyle(.roundedBorder).onSubmit { dir.sendChat(text); text = "" }
                Button { dir.sendChat(text); text = "" } label: { Image(systemName: "paperplane.fill") }
            }
        }
    }
}
