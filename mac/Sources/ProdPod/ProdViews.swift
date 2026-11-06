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
    @State private var directing: Set<String> = []

    var body: some View {
        Group {
            if let studio = app.studio {
                StudioView(studio: studio)
            } else if let dir = app.director {
                DirectorView(dir: dir)
            } else {
                list
            }
        }
        .tint(.prodPod)
        .onAppear { load(); AccountRole.shared.refresh(); Task { await ChunkUploader.shared.resumeAll() } }
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
                    Button {
                        Task {
                            do { if try await SessionBundle.importZip() { load() } } catch { self.error = error.localizedDescription }
                        }
                    } label: { Label("Importar sala…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered).help("Sube el paquete .zip de una sala de prodPod")
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
                    EmptyHint(symbol: "record.circle", title: String(localized: "No hay salas por grabar"),
                              text: String(localized: "En pre, abre un episodio y toca “Ir a grabar”. La sala aparece aquí."))
                }
                if !open.isEmpty {
                    Text("Por grabar").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(open) { s in SessionCard(session: s, canDirect: canDirect(s), direct: { direct(s) }) { enter(s) } }
                    }
                }
                if !done.isEmpty {
                    DisclosureGroup(isExpanded: $showFinished) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                            ForEach(done) { s in SessionCard(session: s, canDirect: canDirect(s), direct: { direct(s) }) { enter(s) } }
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
                directing = (try? await ProdPodClient.shared.directorProjects()) ?? []
                error = nil
                if let want = app.prodRequest {
                    app.prodRequest = nil
                    if let s = sessions.first(where: { $0.id == want }) { enter(s) }
                }
            } catch {
                self.error = PrePodClient.isConfigured ? error.localizedDescription : String(localized: "Conecta tu cuenta en Ajustes para ver tus salas.")
            }
        }
    }

    private func enter(_ s: ProdPodClient.Session) {
        guard app.studio == nil, app.director == nil else { return }
        app.studio = ProdStudio(session: s)
    }

    private func canDirect(_ s: ProdPodClient.Session) -> Bool {
        guard let sp = s.shared_project_id else { return false }
        return directing.contains(sp)
    }

    private func direct(_ s: ProdPodClient.Session) {
        guard app.studio == nil, app.director == nil else { return }
        app.director = DirectorStudio(session: s)
    }
}

private struct SessionCard: View {
    @ObservedObject private var role = AccountRole.shared
    let session: ProdPodClient.Session
    var canDirect = false
    var direct: () -> Void = {}
    let enter: () -> Void
    @State private var hover = false
    @State private var sending = false
    @State private var result: String?

    private func export() {
        sending = true
        Task {
            defer { sending = false }
            do {
                let r = try await ProdPodClient.shared.postJSON("/api/sessions/\(session.id)/recordings/export-to-postpod")
                if let e = r["error"] as? String { result = e; return }
                let n = r["exported"] as? Int ?? 0
                result = n > 0 ? String(localized: "Enviado a postPod (\(n) \(n == 1 ? "pista" : "pistas")). En post: “En postPod web” → Traer a la Mac.")
                               : String(localized: "Ya estaba en postPod.")
            } catch { result = error.localizedDescription }
        }
    }

    var body: some View {
        let (label, color): (String, Color) = {
            switch session.status {
            case "recording": return (String(localized: "Grabando"), .prodPod)
            case "finished": return (String(localized: "Terminada"), Theme.good)
            case "live": return (String(localized: "En vivo"), .prodPod)
            default: return (String(localized: "Lista para grabar"), .orange)
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
            if let r = result { Text(r).font(.caption).foregroundStyle(Theme.good) }
            HStack {
                Spacer()
                // Solo administradores: el envío a postPod ya es automático al terminar las subidas
                if session.status == "finished" && role.isAdmin {
                    Button { export() } label: { Label(sending ? String(localized: "Enviando…") : String(localized: "Enviar a post"), systemImage: "paperplane.fill") }
                        .disabled(sending)
                        .help("Manda las pistas de esta grabación a postPod")
                }
                if canDirect {
                    Button(action: direct) { Label("Dirigir", systemImage: "film.stack") }
                        .help("Entrar al cuarto de control como director")
                }
                Button(action: enter) { Label("Entrar", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Color(white: 1, opacity: 0.08) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Descargar paquete de la sala (.zip)…") {
                Task {
                    do { if let u = try await SessionBundle.export(session) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    catch { result = error.localizedDescription }
                }
            }
        }
    }
}

/// Datos para transmitir: plataforma, dirección y clave de transmisión (la clave la pones tú).
struct LiveSheet: View {
    @ObservedObject var studio: ProdStudio
    @Environment(\.dismiss) private var dismiss
    // Se recuerdan la plataforma, la dirección y la vista; la clave no (es secreta).
    @AppStorage("prodpod.live.preset") private var preset = "youtube"
    @AppStorage("prodpod.live.url") private var url = ""
    @State private var key = ""
    @AppStorage("prodpod.live.layout") private var layout = "speaker"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transmitir en vivo").font(.title2.bold())
            Picker("Plataforma", selection: $preset) {
                ForEach(studio.rtmpPresets, id: \.self) { p in Text(p["name"] ?? p["key"] ?? "").tag(p["key"] ?? "") }
                Text("Otra").tag("custom")
            }
            .onChange(of: preset) { _, v in
                if v != "custom" { url = studio.rtmpPresets.first { $0["key"] == v }?["rtmp_url"] ?? "" }
            }
            TextField("Dirección (rtmp://…)", text: $url).textFieldStyle(.roundedBorder)
            SecureField("Clave de transmisión", text: $key).textFieldStyle(.roundedBorder)
            Text("La clave está en YouTube Studio o en el panel de Twitch. No la compartas con nadie. Si la plataforma la rechaza, thePod te avisa en unos segundos.")
                .font(.caption).foregroundStyle(Theme.secondary)
            Picker("Vista", selection: $layout) {
                Text("Quien habla").tag("speaker")
                Text("Todos iguales").tag("grid")
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Transmitir") {
                    studio.startStream(platform: preset == "custom" ? "custom" : preset, url: url, key: key, layout: layout)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.isEmpty || !(url.hasPrefix("rtmp://") || url.hasPrefix("rtmps://")))
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if preset != "custom" || url.isEmpty {
                url = studio.rtmpPresets.first { $0["key"] == preset }?["rtmp_url"] ?? url
            }
        }
    }
}

// MARK: - Estudio: pantalla previa y sala

struct StudioView: View {
    @ObservedObject private var role = AccountRole.shared
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
                        micCheckBox
                        HStack(spacing: 6) {
                            Image(systemName: studio.headphones ? "headphones" : "speaker.wave.2.fill")
                            Text(studio.headphones ? String(localized: "Usas audífonos: perfecto.") : String(localized: "Parece que usas parlantes. Con audífonos se graba mejor."))
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
                    Card {
                        Label("Calidad de tu grabación", systemImage: "record.circle").font(.headline)
                        if let p = studio.preflight {
                            HStack(spacing: 6) {
                                if studio.uploadMbps == nil && p.hasPrefix(String(localized: "Midiendo")) { ProgressView().controlSize(.small) }
                                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good) }
                                Text(p).font(.callout)
                            }
                        }
                        Picker("Calidad", selection: $studio.recQuality) {
                            ForEach(studio.recChoices, id: \.title) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        Text("Se graba en tu Mac y se sube mientras hablan. Puedes bajarla, no subirla por encima de lo que dio la prueba.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    peopleCard(title: String(localized: "Quién está invitado"))
                    Button { studio.join() } label: {
                        Label(studio.phase == .joining ? String(localized: "Entrando…") : String(localized: "Entrar a la sala"), systemImage: "record.circle")
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

    /// Prueba de micrófono de 10 s, como en la web: mide y sugiere cuánto subir o bajar tu voz para la sala.
    @ViewBuilder private var micCheckBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let left = studio.micCheckLeft {
                HStack {
                    ProgressView(value: Double(10 - left), total: 10).frame(maxWidth: .infinity)
                    Text("\(left) s").font(.caption.monospacedDigit())
                    Button("Cancelar") { studio.cancelMicCheck() }.controlSize(.small)
                }
                Text("Habla como lo harás en el episodio…").font(.caption).foregroundStyle(Theme.secondary)
            } else {
                Button { studio.runMicCheck() } label: {
                    Label("Probar micrófono (10 s)", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .disabled(studio.micId.isEmpty)
            }
            if let r = studio.micCheck, studio.micCheckLeft == nil {
                HStack(spacing: 18) {
                    VStack(alignment: .leading) { Text("Pico").font(.caption2).foregroundStyle(Theme.secondary)
                        Text(String(format: "%.1f dB", r.peak)).font(.caption.monospacedDigit().bold()) }
                    VStack(alignment: .leading) { Text("Promedio").font(.caption2).foregroundStyle(Theme.secondary)
                        Text(String(format: "%.1f dB", r.avg)).font(.caption.monospacedDigit().bold()) }
                }
                if let db = r.suggested {
                    if db == 0 {
                        Label("Tu micrófono ya está bien nivelado.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.good)
                    } else {
                        Text(db > 0 ? String(localized: "Tu voz llega baja: te sugerimos subirla \(db) dB.") : String(localized: "Tu voz llega muy fuerte: te sugerimos bajarla \(-db) dB."))
                            .font(.caption)
                        HStack {
                            Button(studio.micGainDb == db ? String(localized: "Aplicado") : String(localized: "Aplicar")) { studio.applyMicGain() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(studio.micGainDb == db)
                            Button("Repetir") { studio.runMicCheck() }.controlSize(.small)
                        }
                    }
                } else {
                    Text("Casi no se oye nada. Revisa que el micrófono no esté en silencio o muy lejos.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if studio.micGainDb != 0 {
                HStack {
                    Text(String(localized: "La sala te oye \(studio.micGainDb > 0 ? "+" : "")\(studio.micGainDb) dB con este micrófono. Tu grabación no cambia."))
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Quitar") { studio.setMicGain(0) }.controlSize(.small)
                }
            }
        }
        .padding(.top, 4)
    }

    private var levelHint: String {
        if studio.micLevel < -55 { return String(localized: "No te oigo. Habla para probar el micrófono.") }
        if studio.micLevel > -8 { return String(localized: "Muy fuerte: aléjate un poco del micrófono.") }
        return String(localized: "Se te oye bien.")
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
                    statusBadge
                    Text(studio.session.title).font(.headline).lineLimit(1)
                    Spacer()
                    if studio.isOwner && !studio.recording && (!studio.sessionEnded || studio.practice) {
                        Toggle("Ensayo", isOn: Binding(get: { studio.practice }, set: { _ in studio.togglePractice() }))
                            .toggleStyle(.checkbox)
                            .help("Practicar sin guardar: se graba solo en tu Mac y no se sube")
                    }
                    Text(clock(studio.recording ? studio.recSeconds : studio.elapsed)).font(.title3.monospacedDigit())
                        .foregroundStyle(studio.recording ? Color.prodPod : Theme.secondary)
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
                .overlay { countdownOverlay }
                .overlay { endCountdownOverlay }
                .overlay(alignment: .top) { banners }
                .overlay { TeleprompterLayer(studio: studio) }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(studio.overlays) { o in Cintillo(overlay: o, scale: 0.9) }
                    }
                    .padding(28)
                    .animation(.spring(duration: 0.4), value: studio.overlays)
                }

                HStack(spacing: 14) {
                    recordControls
                    Spacer().frame(width: 10)
                    RoundButton(on: studio.micOn, onSymbol: "mic.fill", offSymbol: "mic.slash.fill", big: true) { studio.toggleMic() }
                        .help(studio.micOn ? String(localized: "Silenciar micrófono") : String(localized: "Activar micrófono"))
                    Button { studio.gateOn.toggle() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: studio.gateOn ? "waveform.badge.minus" : "waveform")
                                .font(.system(size: 18, weight: .semibold))
                            Text(studio.gateOn ? "Auto-silencio" : String(localized: "Sin auto-sil.")).font(.system(size: 9, weight: .medium))
                        }
                        .frame(width: 64, height: 52)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 1, opacity: studio.gateOn ? 0.16 : 0.06)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(studio.gateOn ? String(localized: "Cuando no hablas, la sala no oye tus ruidos (teclas, perro). Tu grabación no se toca. Toca para apagar.")
                                        : String(localized: "Apagado: la sala te oye siempre. Toca para encender."))
                    RoundButton(on: studio.camOn, onSymbol: "video.fill", offSymbol: "video.slash.fill", big: true) { studio.toggleCam() }
                        .help(studio.camOn ? String(localized: "Apagar cámara") : String(localized: "Encender cámara"))
                    Menu {
                        if studio.screenOn {
                            Button("Dejar de compartir") { studio.stopScreen() }
                        } else {
                            Button("Compartir una pantalla o ventana…") { studio.shareScreen(recordOnly: false) }
                            Button("Solo grabarla (no se muestra en la sala)…") { studio.shareScreen(recordOnly: true) }
                        }
                    } label: {
                        Image(systemName: studio.screenOn ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(studio.screenOn ? Color.prodPod : Color(white: 1, opacity: 0.16)))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Compartir pantalla")
                    RoundButton(on: !studio.myHand, onSymbol: "hand.raised", offSymbol: "hand.raised.fill", big: true) { studio.toggleHand() }
                        .help(studio.myHand ? String(localized: "Bajar la mano") : String(localized: "Levantar la mano"))
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
                    recordingCard
                    if !studio.sounds.isEmpty { soundboard }
                    if !studio.sponsors.isEmpty { sponsorsCard }
                    peopleCard(title: String(localized: "Personas"))
                    chatCard
                    if studio.isOwner && ProdStudio.liveEnabled { liveCard }   // en vivo: al final del plan
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
            .frame(width: 320)
            .background(Color.black.opacity(0.25))
        }
    }

    // MARK: Grabación

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if studio.recording { return (studio.practice ? String(localized: "ENSAYO") : String(localized: "GRABANDO"), studio.practice ? .yellow : .prodPod) }
            if studio.countdown != nil { return (String(localized: "PREPARADOS"), .orange) }
            if studio.sessionEnded { return (String(localized: "GRABACIÓN TERMINADA"), Theme.good) }
            return (String(localized: "EN LA SALA"), Theme.secondary)
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
                .opacity(studio.recording && studio.recSeconds % 2 == 0 ? 0.35 : 1)
            Text(text).font(.caption.weight(.heavy)).foregroundStyle(color)
        }
    }

    @ViewBuilder private var recordControls: some View {
        if studio.recording {
            if studio.isOwner {
                Button { studio.stopRecording() } label: {
                    Label("Detener", systemImage: "stop.fill").font(.headline).padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.prodPod).controlSize(.large)
            }
            if !studio.practice {
                Button { studio.markMoment() } label: {
                    Label("Marcar momento", systemImage: "mappin.and.ellipse").padding(.vertical, 6)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .help("Marca este momento: en post aparece como capítulo y sirve para hacer un reel")
            }
        } else if !studio.sessionEnded || studio.practice {
            Button { studio.toggleReady() } label: {
                Label(studio.ownReady ? String(localized: "Preparado") : String(localized: "Prepararme"), systemImage: studio.ownReady ? "checkmark.circle.fill" : "circle")
                    .font(.headline).padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(studio.ownReady ? Theme.good : .gray).controlSize(.large)
            .disabled(studio.countdown != nil)
            .help(studio.directorPresent ? String(localized: "El director empieza la grabación cuando todos los conductores estén preparados")
                                         : String(localized: "Cuando todos estén preparados empieza la cuenta regresiva"))
        }
    }

    @ViewBuilder private var countdownOverlay: some View {
        if let c = studio.countdown {
            Text(c > 0 ? "\(c)" : String(localized: "¡Grabando!"))
                .font(.system(size: c > 0 ? 120 : 56, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(40)
                .background(Circle().fill(Color.prodPod.opacity(0.85)).frame(width: 240, height: 240))
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder private var endCountdownOverlay: some View {
        if let n = studio.endCountdown {
            VStack(spacing: 10) {
                Text("La grabación terminó").font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Apagamos cámara y micrófono en \(n)").font(.title2.weight(.semibold))
                Text("Quédate en esta pantalla hasta que tu pista diga Listo").font(.callout).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 26)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.82)))
            .transition(.opacity)
        }
    }

    /// «faltan 120 MB · unos 3 minutos»
    static func pendingText(_ u: ProdStudio.UploadState) -> String? {
        guard let p = u.pending, p > 0 else { return nil }
        var t = String(localized: "faltan \(max(1, p / 1_048_576)) MB")
        if let e = u.eta, e > 0 { t += e < 90 ? String(localized: " · menos de 2 minutos") : String(localized: " · unos \(Int((Double(e) / 60).rounded())) minutos") }
        return t
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if let c = studio.cue {
                Label(c, systemImage: "megaphone.fill")
                    .font(.title3.weight(.heavy)).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color.orange)).foregroundStyle(.black)
            }
            if let s = studio.sponsorAlert {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sponsor: \(s.name)", systemImage: "star.fill").font(.headline)
                    if !s.copy.isEmpty { Text(s.copy).font(.title3) }
                }
                .padding(16).frame(maxWidth: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.9)))
            }
        }
        .padding(.top, 10)
        .animation(.easeOut(duration: 0.2), value: studio.cue)
    }

    private var recordingCard: some View {
        Card {
            Label("Grabación", systemImage: "record.circle").font(.headline)
            Text("Tu pista: \(studio.recQuality.title)").font(.caption).foregroundStyle(Theme.secondary)
            Text(studio.headphones ? String(localized: "Con audífonos: se graba tu micrófono directo.") : String(localized: "Con parlantes: se graba tu voz sin eco."))
                .font(.caption).foregroundStyle(studio.headphones ? Theme.good : .orange)
            if let u = studio.myUpload {
                let mb = Double(u.bytes) / 1_048_576
                let total = Double(max(u.total, u.bytes)) / 1_048_576
                VStack(alignment: .leading, spacing: 4) {
                    if u.state == "done" {
                        Label("Tu pista ya está en prodPod (\(String(format: "%.0f", mb)) MB)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good)
                    } else {
                        Text(u.message ?? (studio.recording ? String(localized: "Subiendo mientras grabas · \(String(format: "%.0f", mb)) MB")
                                                            : String(localized: "Subiendo… ") + (Self.pendingText(u) ?? String(localized: "falta \(String(format: "%.0f", max(0, total - mb))) MB"))))
                            .foregroundStyle(u.message == nil ? Theme.secondary : .orange)
                        if total > 0 { ProgressView(value: min(1, mb / total)) }
                    }
                }
                .font(.caption)
            }
            ForEach(studio.remoteUploads.sorted(by: { $0.key < $1.key }), id: \.key) { id, u in
                let name = studio.people.first(where: { $0.id == id })?.name ?? String(localized: "Otra persona")
                Text(String(localized: "\(name): \(u.state == "done" ? "✓ Listo" : (u.state == "error" ? "problema al subir, reintentando" : "subiendo… " + (Self.pendingText(u) ?? "\(u.bytes / 1_048_576) MB enviados")))"))
                    .font(.caption2).foregroundStyle(u.state == "done" ? Theme.good : Theme.secondary)
            }
            if studio.canExport && role.isAdmin {
                Button { studio.exportToPost() } label: {
                    Label(studio.exporting ? String(localized: "Enviando…") : String(localized: "Enviar a post ahora"), systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(studio.exporting)
            } else if studio.sessionEnded && studio.directorPresent {
                Text("El director envía a post cuando todas las pistas terminen de subir.").font(.caption).foregroundStyle(Theme.secondary)
            }
            if studio.sessionEnded && !studio.recording {
                Text("Cuando todas las pistas terminan de subir, el episodio se envía solo a postPod.").font(.caption2).foregroundStyle(Theme.secondary)
            }
            if let e = studio.exportState { Text(e).font(.caption).foregroundStyle(Theme.good) }
        }
    }

    private var soundboard: some View {
        Card {
            Label("Soundboard", systemImage: "speaker.wave.3.fill").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                ForEach(studio.sounds) { pad in
                    Button { studio.trigger(pad, onlyMe: NSEvent.modifierFlags.contains(.option)) } label: {
                        VStack(spacing: 2) {
                            Text(pad.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let k = pad.key { Text(k.uppercased()).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill((pad.color.map { Color(hex: $0) } ?? .gray).opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Todos lo oyen. Con ⌥ suena solo para ti. También con su tecla.").font(.caption2).foregroundStyle(Theme.secondary)
        }
    }

    private var sponsorsCard: some View {
        Card {
            Label("Sponsors", systemImage: "star").font(.headline)
            ForEach(studio.sponsors) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.callout.weight(.semibold))
                        Text(String(localized: "a los \(studio.clock(Int(s.at)))")).font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if studio.recording { Button("+90 s") { studio.delaySponsor(s) }.controlSize(.small) }
                }
            }
        }
    }

    // MARK: Chat

    @State private var chatText = ""
    @State private var chatHosts = false

    private var chatCard: some View {
        Card {
            HStack {
                Label("Chat", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer()
                Picker("", selection: $chatHosts) {
                    Text("Sala").tag(false)
                    Text("Conductores").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            let msgs = chatHosts ? studio.backstage : studio.chat
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(msgs) { m in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.author).font(.caption2.bold()).foregroundStyle(m.mine ? Color.prodPod : Theme.secondary)
                                Text(m.text).font(.callout).textSelection(.enabled)
                            }
                            .id(m.id)
                        }
                        if msgs.isEmpty {
                            Text(chatHosts ? String(localized: "Solo lo ven los conductores y el director.") : String(localized: "Todos en la sala lo ven."))
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: msgs.count) { _, _ in if let l = msgs.last { proxy.scrollTo(l.id, anchor: .bottom) } }
            }
            HStack {
                TextField("Escribe…", text: $chatText).textFieldStyle(.roundedBorder)
                    .onSubmit { studio.sendChat(chatText, backstage: chatHosts); chatText = "" }
                Button { studio.sendChat(chatText, backstage: chatHosts); chatText = "" } label: { Image(systemName: "paperplane.fill") }
                    .disabled(chatText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { studio.unreadChat = 0 }
    }

    // MARK: En vivo

    @State private var showLive = false

    private var liveCard: some View {
        Card {
            Label("Transmitir en vivo", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            if let s = studio.liveStream {
                Label("En vivo en \((s["platform"] as? String ?? "").capitalized)", systemImage: "circle.fill")
                    .foregroundStyle(Color.prodPod).font(.callout.bold())
                Button("Detener transmisión", role: .destructive) { studio.stopStream() }
            } else {
                Text("YouTube o Twitch, con todos los de la sala.").font(.caption).foregroundStyle(Theme.secondary)
                Button("Empezar transmisión…") { showLive = true }
            }
        }
        .sheet(isPresented: $showLive) { LiveSheet(studio: studio) }
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
        let screenShown = studio.remoteScreen != nil || (studio.screenOn && !studio.screen.recordOnly)
        let main = screenShown ? nil : studio.featured
        let others = studio.people.filter { $0.id != main?.id }
        return VStack(spacing: 12) {
            if let rs = studio.remoteScreen {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 14).fill(Color.black)
                    SwiftUIVideoView(rs.track, layoutMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    Label("Pantalla de \(rs.name)", systemImage: "rectangle.on.rectangle")
                        .font(.callout.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.black.opacity(0.6))).padding(10)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            } else if studio.screenOn && !studio.screen.recordOnly {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 50)).foregroundStyle(Color.prodPod)
                    Text("Estás compartiendo tu pantalla").font(.title3.bold())
                    Button("Dejar de compartir") { studio.stopScreen() }
                }
                .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08)))
            }
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
                        Text(p.roleTitle + (live.contains(p.display_name) ? String(localized: " · en la sala") : "")
                             + (studio.readyMap["participant_\(p.id)"] == true ? String(localized: " · preparado") : "")
                             + (p.recording_quality.map { " · \($0)" } ?? "")).font(.caption)
                            .foregroundStyle(live.contains(p.display_name) ? Theme.good : Theme.secondary)
                    }
                    Spacer()
                    if studio.hands["participant_\(p.id)"] == true {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.yellow).help("Levantó la mano")
                    }
                    if p.role == "guest", let u = p.invite_url {
                        Button { studio.copyInvite(u, name: p.display_name) } label: { Image(systemName: "link") }
                            .buttonStyle(.borderless).help("Copiar el link de \(p.display_name)")
                    }
                    if studio.isOwner, studio.phase == .inRoom, p.role == "guest", live.contains(p.display_name) {
                        Button { studio.kick(p) } label: { Image(systemName: "person.fill.xmark") }
                            .buttonStyle(.borderless).foregroundStyle(.red).help("Sacar a \(p.display_name) de la sala")
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
