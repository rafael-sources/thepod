import SwiftUI
import LiveKit

/// Ventana "Prueba de sala": comprueba cámara, eco y servidor antes de construir prod.
struct RoomProbeView: View {
    @StateObject private var probe = RoomProbe()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { controls.padding(20) }
                .frame(width: 360)
                .background(Color.black.opacity(0.25))
            Divider()
            videos.padding(20)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Color(red: 1, green: 0.23, blue: 0.23))
        .onAppear { probe.load() }
        .onDisappear { Task { await probe.leave() } }
        .alert("Algo salió mal", isPresented: Binding(get: { probe.error != nil }, set: { if !$0 { probe.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(probe.error ?? "") }
    }

    private var connected: Bool { probe.phase == .connected }

    // MARK: Controles

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Prueba de sala").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Comprueba que la Mac puede entrar a una sala de prodPod, mandar tu cámara y grabarla en 1080p al mismo tiempo. No graba nada en el servidor.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            }

            Card {
                Label("1 · Sala", systemImage: "door.left.hand.open").font(.headline)
                Picker("Sala", selection: $probe.sessionId) {
                    Text("Elige…").tag(Int?.none)
                    ForEach(probe.sessions) { s in Text("\(s.title) · #\(s.id)").tag(Int?.some(s.id)) }
                }
                .labelsHidden()
                .disabled(connected)
                Button { probe.createTestSession() } label: { Label("Crear sala de prueba", systemImage: "plus") }
                    .disabled(connected || probe.busy)
                Text("Mejor usa una sala de prueba, no la de un episodio real.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }

            Card {
                Label("2 · Cámara", systemImage: "video").font(.headline)
                Picker("Cámara", selection: $probe.cameraId) {
                    ForEach(probe.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .labelsHidden()
                .disabled(connected)
                Text("El micrófono es el que esté elegido en tu Mac.").font(.caption).foregroundStyle(Theme.secondary)
            }

            if connected {
                Button { Task { await probe.leave() } } label: {
                    Label("Salir de la sala", systemImage: "phone.down.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).controlSize(.large)
            } else {
                Button { probe.join() } label: {
                    Label(probe.phase == .connecting ? String(localized: "Entrando…") : String(localized: "Entrar a la sala"), systemImage: "record.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(probe.sessionId == nil || probe.phase == .connecting)
            }

            if connected {
                Card {
                    Label("3 · Invitado", systemImage: "person.badge.plus").font(.headline)
                    Text("Abre el link en otro equipo o en el teléfono, como lo haría un invitado.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Button { probe.makeInvite() } label: { Label("Copiar link de invitado", systemImage: "link") }
                    if let u = probe.inviteURL { Text(u).font(.caption2).foregroundStyle(Theme.secondary).textSelection(.enabled).lineLimit(2) }
                }
                Card {
                    Label("4 · Grabar", systemImage: "record.circle").font(.headline)
                    if probe.recording {
                        Button { probe.stopRecording() } label: { Label("Detener (\(probe.recordSeconds) s)", systemImage: "stop.fill") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button { probe.startRecording() } label: { Label("Grabar 30 segundos", systemImage: "record.circle") }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Habla normal mientras graba. Se guarda solo en tu Mac.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }

            results
            if !probe.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lo que pasó").font(.caption.bold()).foregroundStyle(Theme.secondary)
                    ForEach(probe.notes.suffix(14), id: \.self) { Text($0).font(.caption2.monospaced()).foregroundStyle(Theme.secondary) }
                }
            }
        }
    }

    // MARK: Resultados

    private var results: some View {
        Card {
            Label("Resultado", systemImage: "checklist").font(.headline)
            check(String(localized: "Cámara para la sala y grabación a la vez"),
                  ok: probe.framesSent > 0 && probe.framesRecorded > 0,
                  detail: probe.framesSent == 0 ? String(localized: "Todavía sin datos")
                      : String(localized: "Sala \(probe.roomSize.isEmpty ? "…" : probe.roomSize) · Grabación \(probe.captureSize) · \(probe.framesRecorded) cuadros grabados"))
            check(String(localized: "Servidor de la sala"),
                  ok: connected,
                  detail: connected ? String(localized: "Conectado · \(probe.remotes.count) persona(s) más · \(probe.dataMessages) mensajes recibidos") : String(localized: "Sin conectar"))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "ear").foregroundStyle(.orange)
                    Text("Eco").font(.callout.weight(.semibold))
                }
                Text("Sin audífonos, pide al invitado que hable. Si él se oye a sí mismo, hay eco. Después compara las dos grabaciones de tu voz:")
                    .font(.caption).foregroundStyle(Theme.secondary)
                if let dir = probe.folder, !probe.recording {
                    HStack {
                        Button("Grabada en la Mac") { NSWorkspace.shared.open(dir.appendingPathComponent("camara-1080p.mov")) }
                        Button("Como sale a la sala") { NSWorkspace.shared.open(dir.appendingPathComponent("voz-hacia-la-sala.wav")) }
                    }
                    .controlSize(.small)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: { Label("Mostrar archivos", systemImage: "folder") }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func check(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.good : Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: Videos

    private var videos: some View {
        let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return VStack(alignment: .leading, spacing: 12) {
            if !connected {
                VStack(spacing: 10) {
                    Image(systemName: "video.badge.waveform").font(.system(size: 44)).foregroundStyle(Theme.secondary)
                    Text(probe.phase == .connecting ? String(localized: "Entrando a la sala…") : String(localized: "Elige la sala y toca “Entrar a la sala”."))
                        .foregroundStyle(Theme.secondary)
                    if case .failed(let why) = probe.phase { Text(why).font(.caption).foregroundStyle(.orange) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: cols, spacing: 14) {
                    tile(name: String(localized: "Tú (Mac)"), track: probe.localTrack, speaking: false, mirror: true, recording: probe.recording)
                    ForEach(probe.remotes) { r in tile(name: r.name, track: r.track, speaking: r.speaking, mirror: false, recording: false) }
                }
                Spacer()
            }
        }
    }

    private func tile(name: String, track: VideoTrack?, speaking: Bool, mirror: Bool, recording: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.black)
            if let track {
                SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: mirror ? .mirror : .off)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                Avatar(name: name, size: 64).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if recording { Circle().fill(.red).frame(width: 8, height: 8) }
                Text(name).font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(10)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(speaking ? Theme.good : Theme.stroke, lineWidth: speaking ? 3 : 1))
    }
}
