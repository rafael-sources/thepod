import SwiftUI
import AVFoundation
import LiveKit

// MARK: - Inicio de prod: las salas de grabación

struct ProdHomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var sessions: [ProdPodClient.Session] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showFinished = false

    var body: some View {
        Group {
            if let studio = app.studio {
                StudioView(studio: studio)
            } else {
                list
            }
        }
        .tint(.prodPod)
        .onAppear { load() }
        .onChange(of: app.prodRequest) { _, _ in load() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                    SectionSwitcher()
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).help("Actualizar")
                    SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
                }
                Text("Grabación: entra a la sala desde la Mac. Tus invitados entran desde la web con su link.")
                    .font(.title3).foregroundStyle(Theme.secondary)

                if let error {
                    Card {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        SettingsLink { Text("Abrir Ajustes") }
                    }
                }

                let open = sessions.filter { $0.status != "finished" }
                let done = sessions.filter { $0.status == "finished" }
                if open.isEmpty && !loading && error == nil {
                    EmptyHint(symbol: "record.circle", title: "No hay salas por grabar",
                              text: "En pre, abre un episodio y toca “Ir a grabar”. La sala aparece aquí.")
                }
                if !open.isEmpty {
                    Text("Por grabar").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(open) { s in SessionCard(session: s) { enter(s) } }
                    }
                }
                if !done.isEmpty {
                    DisclosureGroup(isExpanded: $showFinished) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                            ForEach(done) { s in SessionCard(session: s) { enter(s) } }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Ya grabadas (\(done.count))").font(.headline)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            do {
                sessions = try await ProdPodClient.shared.sessions()
                error = nil
                if let want = app.prodRequest {
                    app.prodRequest = nil
                    if let s = sessions.first(where: { $0.id == want }) { enter(s) }
                }
            } catch {
                self.error = PrePodClient.isConfigured ? error.localizedDescription : "Conecta tu cuenta en Ajustes para ver tus salas."
            }
        }
    }

    private func enter(_ s: ProdPodClient.Session) {
        guard app.studio == nil else { return }
        app.studio = ProdStudio(session: s)
    }
}

private struct SessionCard: View {
    let session: ProdPodClient.Session
    let enter: () -> Void
    @State private var hover = false

    var body: some View {
        let (label, color): (String, Color) = {
            switch session.status {
            case "recording": return ("Grabando", .prodPod)
            case "finished": return ("Terminada", Theme.good)
            case "live": return ("En vivo", .prodPod)
            default: return ("Lista para grabar", .orange)
            }
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Chip(text: label, symbol: "circle.fill", color: color)
                Spacer()
                Text("#\(session.id)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Text(session.title).font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let live = session.live_participants, !live.isEmpty {
                Label("\(live.joined(separator: ", ")) \(live.count == 1 ? "está" : "están") en la sala", systemImage: "person.wave.2.fill")
                    .font(.caption).foregroundStyle(Color.prodPod)
            }
            HStack {
                Spacer()
                Button(action: enter) { Label("Entrar", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Color(white: 1, opacity: 0.08) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        .onHover { hover = $0 }
    }
}

// MARK: - Estudio: pantalla previa y sala

struct StudioView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var studio: ProdStudio
    @State private var inviteName = ""

    var body: some View {
        Group {
            switch studio.phase {
            case .inRoom: room
            default: prejoin
            }
        }
        .onAppear { if studio.phase == .prejoin, !studio.previewReady { studio.prepare() } }
        .alert("Algo salió mal", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(studio.error ?? "") }
        .overlay(alignment: .top) {
            if let n = studio.note {
                Text(n).font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.note)
    }

    private func close() {
        Task {
            await studio.leave()
            app.studio = nil
        }
    }

    // MARK: Pantalla previa

    private var prejoin: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Button { close() } label: { Label("Salas", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                Text(studio.session.title).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(2)
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.black)
                    if studio.permissionDenied {
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                            Text("thePod no tiene permiso para usar la cámara o el micrófono.")
                            Button("Abrir Ajustes del Sistema") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                            }
                        }
                    } else if studio.previewReady && studio.camOn {
                        CameraPreview(session: studio.pipe.captureSession)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        Avatar(name: PrePodClient.username, size: 90)
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            RoundButton(on: studio.micOn, onSymbol: "mic.fill", offSymbol: "mic.slash.fill") { studio.micOn.toggle() }
                            RoundButton(on: studio.camOn, onSymbol: "video.fill", offSymbol: "video.slash.fill") { studio.camOn.toggle() }
                        }
                        .padding(14)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Antes de entrar").font(.title2.bold())
                    Card {
                        Label("Cámara", systemImage: "video").font(.headline)
                        Picker("Cámara", selection: $studio.cameraId) {
                            ForEach(studio.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        .labelsHidden()
                        .onChange(of: studio.cameraId) { _, _ in studio.restartCapture() }
                        if !studio.captureSize.isEmpty {
                            Text("Tu cámara da \(studio.captureSize)").font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    Card {
                        Label("Micrófono", systemImage: "mic").font(.headline)
                        Picker("Micrófono", selection: $studio.micId) {
                            ForEach(studio.mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        .labelsHidden()
                        .onChange(of: studio.micId) { _, _ in studio.restartCapture() }
                        LevelMeter(db: studio.micLevel)
                        Text(levelHint).font(.caption).foregroundStyle(levelHintColor)
                        HStack(spacing: 6) {
                            Image(systemName: studio.headphones ? "headphones" : "speaker.wave.2.fill")
                            Text(studio.headphones ? "Usas audífonos: perfecto." : "Parece que usas parlantes. Con audífonos se graba mejor.")
                        }
                        .font(.caption).foregroundStyle(studio.headphones ? Theme.good : .orange)
                    }
                    Card {
                        Label("Calidad en la sala", systemImage: "dial.medium").font(.headline)
                        Picker("Calidad", selection: $studio.quality) {
                            ForEach(RoomQuality.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text("Es cómo te ven los demás. Si tu internet es lento, baja la calidad.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    peopleCard(title: "Quién está invitado")
                    Button { studio.join() } label: {
                        Label(studio.phase == .joining ? "Entrando…" : "Entrar a la sala", systemImage: "record.circle")
                            .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(studio.phase == .joining || studio.permissionDenied)
                }
                .padding(24)
            }
            .frame(width: 380)
            .background(Color.black.opacity(0.25))
        }
    }

    private var levelHint: String {
        if studio.micLevel < -55 { return "No te oigo. Habla para probar el micrófono." }
        if studio.micLevel > -8 { return "Muy fuerte: aléjate un poco del micrófono." }
        return "Se te oye bien."
    }
    private var levelHintColor: Color {
        if studio.micLevel < -55 || studio.micLevel > -8 { return .orange }
        return Theme.good
    }

    // MARK: Sala

    private var room: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(Color.prodPod).frame(width: 9, height: 9)
                        Text("EN LA SALA").font(.caption.weight(.heavy)).foregroundStyle(Color.prodPod)
                    }
                    Text(studio.session.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(clock(studio.elapsed)).font(.title3.monospacedDigit()).foregroundStyle(Theme.secondary)
                    Picker("", selection: $studio.layout) {
                        Image(systemName: "person.crop.rectangle").tag(ProdStudio.Layout.speaker)
                        Image(systemName: "square.grid.2x2").tag(ProdStudio.Layout.grid)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 90)
                    .help("Quien habla / Todos iguales")
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                Group {
                    if studio.layout == .grid { grid } else { speaker }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 14) {
                    RoundButton(on: studio.micOn, onSymbol: "mic.fill", offSymbol: "mic.slash.fill", big: true) { studio.toggleMic() }
                        .help(studio.micOn ? "Silenciar micrófono" : "Activar micrófono")
                    RoundButton(on: studio.camOn, onSymbol: "video.fill", offSymbol: "video.slash.fill", big: true) { studio.toggleCam() }
                        .help(studio.camOn ? "Apagar cámara" : "Encender cámara")
                    Button { close() } label: {
                        Label("Salir", systemImage: "phone.down.fill").font(.headline).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                }
                .padding(16)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    peopleCard(title: "Personas")
                    Card {
                        Label("Invitar a alguien más", systemImage: "person.badge.plus").font(.headline)
                        TextField("Nombre", text: $inviteName).textFieldStyle(.roundedBorder)
                            .onSubmit { studio.invite(name: inviteName); inviteName = "" }
                        Button("Crear link y copiar") { studio.invite(name: inviteName); inviteName = "" }
                            .disabled(inviteName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("Máximo 4 personas en la sala.").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(18)
            }
            .frame(width: 300)
            .background(Color.black.opacity(0.25))
        }
    }

    private var grid: some View {
        let n = studio.people.count
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: n <= 1 ? 1 : 2)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(studio.people) { p in PersonTile(person: p) }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var speaker: some View {
        let main = studio.featured
        let others = studio.people.filter { $0.id != main?.id }
        return VStack(spacing: 12) {
            if let main { PersonTile(person: main, big: true) }
            if !others.isEmpty {
                HStack(spacing: 12) {
                    ForEach(others) { p in PersonTile(person: p).frame(maxWidth: 240) }
                }
                .frame(height: 135)
            }
        }
    }

    private func peopleCard(title: String) -> some View {
        Card {
            Label(title, systemImage: "person.2").font(.headline)
            let live = Set(studio.people.map(\.name))
            ForEach(studio.participants) { p in
                HStack(spacing: 8) {
                    Avatar(name: p.display_name, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.display_name).font(.callout.weight(.semibold))
                        Text(p.roleTitle + (live.contains(p.display_name) ? " · en la sala" : "")).font(.caption)
                            .foregroundStyle(live.contains(p.display_name) ? Theme.good : Theme.secondary)
                    }
                    Spacer()
                    if p.role == "guest", let u = p.invite_url {
                        Button { studio.copyInvite(u, name: p.display_name) } label: { Image(systemName: "link") }
                            .buttonStyle(.borderless).help("Copiar el link de \(p.display_name)")
                    }
                }
            }
            if studio.participants.isEmpty { Text("Nadie todavía").font(.caption).foregroundStyle(Theme.secondary) }
        }
    }

    private func clock(_ s: Int) -> String { String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
}

// MARK: - Piezas

struct PersonTile: View {
    let person: RoomPerson
    var big = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08))
            if let v = person.video {
                SwiftUIVideoView(v, layoutMode: big ? .fit : .fill, mirrorMode: person.isLocal ? .mirror : .off)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Avatar(name: person.name, size: big ? 110 : 54).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                Image(systemName: person.micOn ? "mic.fill" : "mic.slash.fill")
                    .font(.caption.bold()).foregroundStyle(person.micOn ? .white : .red)
                Text(person.name).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.6)))
            .padding(10)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(person.speaking ? Theme.good : Theme.stroke, lineWidth: person.speaking ? 3 : 1))
        .animation(.easeOut(duration: 0.15), value: person.speaking)
    }
}

struct RoundButton: View {
    let on: Bool
    let onSymbol: String
    let offSymbol: String
    var big = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .font(.system(size: big ? 20 : 16, weight: .semibold))
                .frame(width: big ? 52 : 42, height: big ? 52 : 42)
                .background(Circle().fill(on ? Color(white: 1, opacity: 0.16) : Color.red))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

struct LevelMeter: View {
    let db: Float
    var body: some View {
        let v = CGFloat(max(0, min(1, (db + 60) / 60)))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelStrong)
                Capsule().fill(LinearGradient(colors: [Theme.good, Theme.good, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width)
                    .mask(alignment: .leading) { Capsule().frame(width: g.size.width * v) }
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: v)
    }
}

/// Vista previa de la cámara (como un espejo) antes de entrar.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        layer.frame = v.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer()
        v.layer?.addSublayer(layer)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
