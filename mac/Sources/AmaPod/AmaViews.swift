import SwiftUI
import LiveKit

extension Color {
    static let amaPod = Color(red: 0.078, green: 0.722, blue: 0.651)      // #14B8A6, el color de amaPod en la suite
}

private enum AS {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.07)
    static let side = Color(red: 0.085, green: 0.085, blue: 0.105)
    static let field = Color(white: 1, opacity: 0.06)
    static let line = Color(white: 1, opacity: 0.08)
}

private struct AmaTitle: View {
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

private struct AmaButton: View {
    let title: String
    let symbol: String
    var color: Color = .amaPod
    var filled = true
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .bold)).lineLimit(1)
                .padding(.horizontal, 16).frame(height: 38)
                .foregroundStyle(!enabled ? Theme.secondary : filled ? Color.black : color)
                .background(RoundedRectangle(cornerRadius: 10).fill(!enabled ? AS.field : filled ? color.opacity(hover ? 1 : 0.9) : color.opacity(hover ? 0.22 : 0.14)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!enabled).fixedSize()
        .onHover { hover = $0 }
    }
}

private struct AmaField: View {
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1
    var onSubmit: () -> Void = {}
    var body: some View {
        TextField(placeholder, text: $text, axis: lines.upperBound > 1 ? .vertical : .horizontal)
            .lineLimit(lines).textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(AS.field))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AS.line))
            .onSubmit(onSubmit)
    }
}

private func chatModeName(_ m: String?) -> String {
    ["free": "Chat libre", "moderated": "Chat moderado", "off": "Sin chat"][m ?? "free"] ?? "Chat libre"
}

// MARK: - Inicio de ama: tus eventos

struct AmaHomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var events: [AmaClient.Event] = []
    @State private var templates: [AmaClient.Template] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showFinished = false
    @State private var creating = false
    @State private var toDelete: AmaClient.Event?

    var body: some View {
        Group {
            if let s = app.ama { AmaStudioView(studio: s) } else { list }
        }
        .tint(.amaPod)
        .onAppear { load() }
        .onChange(of: app.ama == nil) { _, closed in if closed { load() } }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("thePod").font(.system(size: 40, weight: .black, design: .rounded))
                    SectionSwitcher()
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { creating = true } label: { Label("Nuevo evento", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).help("Actualizar")
                    SettingsLink { Label("Ajustes", systemImage: "gearshape") }.buttonStyle(.bordered)
                }
                Text("Preguntas del público en vivo: tú moderas desde la Mac; tu audiencia pregunta o mira desde la web con un link.")
                    .font(.title3).foregroundStyle(Theme.secondary)

                if let error {
                    Card {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        SettingsLink { Text("Abrir Ajustes") }
                    }
                }

                let live = events.filter { $0.status == "active" }
                let upcoming = events.filter { $0.status == "created" }
                let done = events.filter { $0.status == "finished" }
                if live.isEmpty && upcoming.isEmpty && !loading && error == nil {
                    EmptyHint(symbol: "questionmark.bubble", title: "No tienes eventos de preguntas",
                              text: "Toca “Nuevo evento”. Cuando lo empieces, comparte el link y la gente se anota para preguntar.")
                }
                if !live.isEmpty { section("En vivo", live) }
                if !upcoming.isEmpty { section("Por empezar", upcoming) }
                if !done.isEmpty {
                    DisclosureGroup(isExpanded: $showFinished) {
                        grid(done).padding(.top, 8)
                    } label: { Text("Terminados (\(done.count))").font(.headline) }
                }
            }
            .padding(36)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $creating) {
            NewAmaEventSheet(templates: templates) { ev in
                events.insert(ev, at: 0)
                app.ama = AmaStudio(event: ev)
            }
        }
        .alert("¿Eliminar este evento?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Eliminar", role: .destructive) {
                if let e = toDelete { Task { do { try await AmaClient.shared.delete(e.id); load() } catch { self.error = error.localizedDescription } } }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text(toDelete?.title ?? "") }
    }

    private func section(_ title: String, _ list: [AmaClient.Event]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            grid(list)
        }
    }

    private func grid(_ list: [AmaClient.Event]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
            ForEach(list) { e in
                AmaEventCard(event: e, open: { app.ama = AmaStudio(event: e) },
                             delete: { toDelete = e },
                             saveTemplate: { Task { try? await AmaClient.shared.saveAsTemplate(e.id); templates = (try? await AmaClient.shared.templates()) ?? templates } })
            }
        }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            do {
                events = try await AmaClient.shared.events()
                templates = (try? await AmaClient.shared.templates()) ?? []
                error = nil
            } catch {
                self.error = PrePodClient.isConfigured ? "No se pudo leer amaPod: \(error.localizedDescription)" : "Conecta tu cuenta en Ajustes para ver tus eventos."
            }
        }
    }
}

private struct AmaEventCard: View {
    let event: AmaClient.Event
    let open: () -> Void
    let delete: () -> Void
    let saveTemplate: () -> Void
    @State private var hover = false

    var body: some View {
        let (label, color): (String, Color) = {
            switch event.status {
            case "active": return ("En vivo", .amaPod)
            case "finished": return ("Terminado", Theme.secondary)
            default: return ("Por empezar", .orange)
            }
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Chip(text: label, symbol: "circle.fill", color: color)
                Text(chatModeName(event.chat_mode)).font(.caption).foregroundStyle(Theme.secondary)
                Spacer()
                Text("#\(event.id)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Text(event.title).font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let d = event.description, !d.isEmpty {
                Text(d).font(.callout).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            if event.status != "created" {
                HStack(spacing: 14) {
                    Label("\(event.like_count ?? 0)", systemImage: "heart.fill")
                    Label("\(event.spectator_count ?? 0)", systemImage: "eye.fill")
                    if event.recording_file?.isEmpty == false { Label("Grabado", systemImage: "record.circle") }
                }
                .font(.caption).foregroundStyle(Theme.secondary)
            }
            HStack {
                Spacer()
                if event.status != "finished" {
                    Button(action: open) {
                        Label(event.status == "active" ? "Entrar" : "Preparar", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? Color(white: 1, opacity: 0.08) : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(event.status == "active" ? Color.amaPod.opacity(0.6) : Theme.stroke))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copiar link para preguntar") { copy(AmaClient.joinLink(event.id)) }
            Button("Copiar link para mirar") { copy(AmaClient.watchLink(event.id)) }
            Button("Guardar como plantilla", action: saveTemplate)
            if event.status == "created" {
                Divider()
                Button("Eliminar…", role: .destructive, action: delete)
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct NewAmaEventSheet: View {
    let templates: [AmaClient.Template]
    let created: (AmaClient.Event) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var desc = ""
    @State private var mode = "free"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreHeader(symbol: "questionmark.bubble.fill", title: "Nuevo evento de preguntas",
                      subtitle: "Después lo empiezas cuando quieras y compartes el link.", color: .amaPod)
            if !templates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    AmaTitle(text: "Empezar desde una plantilla")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(templates) { t in
                                Button { fromTemplate(t) } label: {
                                    Text(t.title).font(.callout.weight(.semibold)).lineLimit(1)
                                        .padding(.horizontal, 12).frame(height: 30)
                                        .background(Capsule().fill(AS.field))
                                }
                                .buttonStyle(.plain).disabled(busy)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                AmaTitle(text: "Título")
                AmaField(placeholder: "Ej.: Pregúntanos lo que quieras — Lee La Letra Chica", text: $title)
            }
            VStack(alignment: .leading, spacing: 8) {
                AmaTitle(text: "Descripción", trailing: "opcional")
                AmaField(placeholder: "De qué va, qué tipo de preguntas buscas", text: $desc, lines: 2...4)
            }
            VStack(alignment: .leading, spacing: 8) {
                AmaTitle(text: "Chat")
                Picker("", selection: $mode) {
                    Text("Libre").tag("free"); Text("Moderado").tag("moderated"); Text("Apagado").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(mode == "moderated"
                     ? "Los mensajes del público esperan tu aprobación. Ojo: hoy amaPod todavía no muestra la lista de mensajes por aprobar, así que no se verían."
                     : mode == "off" ? "No habrá chat en este evento." : "Todo lo que escriban aparece al instante.")
                    .font(.caption).foregroundStyle(mode == "moderated" ? .orange : Theme.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { create() } label: { Text(busy ? "Creando…" : "Crear evento") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(.amaPod)
    }

    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let e = try await AmaClient.shared.create(title: title.trimmingCharacters(in: .whitespaces),
                                                         description: desc.trimmingCharacters(in: .whitespacesAndNewlines), chatMode: mode)
                dismiss(); created(e)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func fromTemplate(_ t: AmaClient.Template) {
        busy = true
        Task {
            defer { busy = false }
            do { let e = try await AmaClient.shared.fromTemplate(t.id); dismiss(); created(e) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Estudio del host

struct AmaStudioView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var studio: AmaStudio
    var preview = false
    @AppStorage("amaPestana") private var tab = 0
    @State private var confirmFinish = false
    @State private var chatText = ""

    var body: some View {
        Group {
            switch studio.phase {
            case .live: live
            case .ended: ended
            default: prejoin
            }
        }
        .background(AS.bg)
        .tint(.amaPod)
        .onAppear { if !preview, studio.phase == .prejoin { studio.startPreview() } }
        .alert("Algo salió mal", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(studio.error ?? "") }
        .overlay(alignment: .top) {
            if let n = studio.note {
                Text(n).font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(.black.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(AS.line))
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.note)
    }

    private func close() {
        Task { await studio.leave(); app.ama = nil }
    }

    // MARK: Antes de empezar

    private var prejoin: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Button { close() } label: { Label("Tus eventos", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.1))
                    if let v = studio.myVideo {
                        SwiftUIVideoView(v, layoutMode: .fill, mirrorMode: .mirror).clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        Image(systemName: "video.slash").font(.system(size: 34)).foregroundStyle(Theme.secondary)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                HStack(spacing: 10) {
                    Picker("Cámara", selection: $studio.camId) { ForEach(studio.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }
                    Picker("Micrófono", selection: $studio.micId) { ForEach(studio.mics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }
                }
            }
            .frame(maxWidth: 640)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text("amaPod").font(.system(size: 11, weight: .heavy)).kerning(0.6)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.amaPod)).foregroundStyle(.black)
                    Chip(text: studio.event.status == "active" ? "En vivo" : "Por empezar", color: studio.event.status == "active" ? .amaPod : .orange)
                }
                Text(studio.event.title).font(.system(size: 26, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                if let d = studio.event.description, !d.isEmpty { Text(d).foregroundStyle(Theme.secondary) }

                VStack(alignment: .leading, spacing: 10) {
                    AmaTitle(text: "Links para compartir")
                    linkRow("Para preguntar", "person.wave.2.fill", AmaClient.joinLink(studio.event.id), "para preguntar")
                    linkRow("Para mirar", "eye.fill", AmaClient.watchLink(studio.event.id), "para mirar")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Al empezar se abre la sala y se empieza a grabar en el servidor.", systemImage: "record.circle")
                    Label("Al terminar, la grabación se manda sola a postPod.", systemImage: "paperplane")
                    Label(chatModeName(studio.event.chat_mode), systemImage: "bubble.left.and.bubble.right")
                }
                .font(.callout).foregroundStyle(Theme.secondary)

                AmaButton(title: studio.phase == .joining ? "Abriendo…" : studio.event.status == "active" ? "Entrar al evento" : "Empezar el evento",
                          symbol: "play.fill", enabled: studio.phase == .prejoin) { studio.goLive() }
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func linkRow(_ title: String, _ symbol: String, _ link: String, _ what: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.amaPod).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(link).font(.caption.monospaced()).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { studio.copy(link, what) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copiar")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(AS.field))
    }

    // MARK: Terminado

    private var ended: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Color.amaPod)
            Text("Evento terminado").font(.title.bold())
            Text(studio.event.recording_file?.isEmpty == false
                 ? "La grabación va camino a postPod. En post, “En postPod web” → Traer a la Mac."
                 : "No quedó grabación de este evento.")
                .foregroundStyle(Theme.secondary)
            Button("Volver a tus eventos") { app.ama = nil }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: En vivo

    private var live: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(AS.line).frame(height: 1)
                stage
                onAirBar
            }
            Rectangle().fill(AS.line).frame(width: 1)
            side.frame(width: 400).background(AS.side)
        }
        .alert("¿Terminar el evento?", isPresented: $confirmFinish) {
            Button("Terminar", role: .destructive) { studio.finish() }
            Button("Seguir", role: .cancel) {}
        } message: { Text("Se desconecta a todos y se cierra la sala. Si se grabó, la grabación se manda a postPod.") }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30).background(Circle().fill(AS.field))
            }
            .buttonStyle(.plain).help("Salir sin terminar el evento (sigue abierto para el público)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("amaPod").font(.system(size: 10, weight: .heavy)).kerning(0.6)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.amaPod)).foregroundStyle(.black)
                    Text(chatModeName(studio.event.chat_mode)).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                }
                Text(studio.event.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                Label("\(studio.likes)", systemImage: "heart.fill").help("Me gusta")
                Label("\(studio.spectators)", systemImage: "eye.fill").help("Personas que entraron a mirar")
            }
            .font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.secondary).fixedSize()
            Button { studio.toggleRecording() } label: {
                HStack(spacing: 7) {
                    Circle().fill(studio.recording ? Color.prodPod : Color(white: 1, opacity: 0.3)).frame(width: 9, height: 9)
                    Text(studio.recording ? "Grabando" : "Sin grabar").font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(studio.recording ? Color.prodPod.opacity(0.18) : AS.field))
            }
            .buttonStyle(.plain).fixedSize().help(studio.recording ? "Detener la grabación del servidor" : "Grabar en el servidor")
            circle(studio.micOn ? "mic.fill" : "mic.slash.fill", on: studio.micOn) { studio.toggleMic() }
            circle(studio.camOn ? "video.fill" : "video.slash.fill", on: studio.camOn) { studio.toggleCam() }
            Button { confirmFinish = true } label: {
                Text("Terminar evento").font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Capsule().fill(Color.prodPod)).foregroundStyle(.black)
            }
            .buttonStyle(.plain).fixedSize().disabled(studio.busy)
        }
        .padding(.horizontal, 18).frame(height: 64)
    }

    private func circle(_ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(on ? AS.field : Color.prodPod.opacity(0.85)))
                .foregroundStyle(on ? .white : .black)
        }
        .buttonStyle(.plain)
    }

    /// Quien está al aire en grande; tú en pequeño.
    private var stage: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.09))
                if let p = studio.onAir {
                    if p.censored {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash.fill").font(.system(size: 40))
                            Text("\(p.display_name) está silenciado y oculto").font(.headline)
                        }
                        .foregroundStyle(.orange)
                    } else if let v = studio.onAirTile?.video {
                        SwiftUIVideoView(v, layoutMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        VStack(spacing: 10) {
                            Avatar(name: p.display_name, size: 84)
                            Text(studio.onAirTile == nil ? "Esperando que \(p.display_name) se conecte…" : "\(p.display_name) todavía no prende la cámara")
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 46)).foregroundStyle(Theme.secondary)
                        Text("Nadie al aire").font(.headline)
                        Text(studio.waiting.isEmpty ? "Cuando aceptes solicitudes, toca “Siguiente” para dar la palabra."
                                                    : "Toca “Siguiente” para darle la palabra a \(studio.waiting[0].display_name).")
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if let p = studio.onAir {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(Color.amaPod).frame(width: 8, height: 8)
                            Text("AL AIRE").font(.system(size: 11, weight: .heavy)).kerning(0.8).foregroundStyle(Color.amaPod)
                            Text(p.display_name).font(.callout.weight(.semibold))
                            if let t = studio.onAirTile, !t.micOn { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(studio.onAirTile?.speaking == true ? Color.amaPod : AS.line,
                                                                      lineWidth: studio.onAirTile?.speaking == true ? 3 : 1))

            // Tú
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14))
                if let v = studio.myVideo, studio.camOn {
                    SwiftUIVideoView(v, layoutMode: .fill, mirrorMode: .mirror).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Avatar(name: PrePodClient.username.isEmpty ? "Host" : PrePodClient.username, size: 40)
                }
            }
            .frame(width: 220, height: 124)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AS.line))
            .overlay(alignment: .bottomLeading) {
                Text("Tú").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6))).padding(6)
            }
            .padding(14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Las preguntas de quien está al aire y los botones para seguir.
    private var onAirBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let p = studio.onAir {
                    Text("LO QUE QUIERE PREGUNTAR \(p.display_name.uppercased())").font(.system(size: 11, weight: .bold)).kerning(0.6)
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                    if let qs = p.questions, !qs.isEmpty {
                        ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(i + 1).").font(.callout.weight(.bold)).foregroundStyle(Color.amaPod)
                                Text(q).font(.callout).lineLimit(2)
                            }
                        }
                    } else {
                        Text("No escribió sus preguntas de antemano.").font(.callout).foregroundStyle(Theme.secondary)
                    }
                } else {
                    Text("\(studio.waiting.count) en la cola · \(studio.requests.count) por aceptar")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let p = studio.onAir {
                AmaButton(title: p.censored ? "Devolver la palabra" : "Silenciar y ocultar", symbol: p.censored ? "eye" : "eye.slash.fill",
                          color: .orange, filled: false) { studio.censor(p) }
                    .help("Si alguien usa el aire para algo indebido: se le corta el audio y el video al instante")
            }
            AmaButton(title: studio.waiting.isEmpty ? (studio.onAir == nil ? "Siguiente" : "Terminar su turno") : "Siguiente: \(studio.waiting[0].display_name)",
                      symbol: "forward.end.fill", enabled: studio.onAir != nil || !studio.waiting.isEmpty) { studio.next() }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(minHeight: 84)
        .background(Color.amaPod.opacity(studio.onAir == nil ? 0.03 : 0.07))
        .overlay(alignment: .top) { Rectangle().fill(AS.line).frame(height: 1) }
    }

    // MARK: Panel lateral

    private var side: some View {
        let tabs: [(String, String, Int)] = [("Solicitudes", "hand.raised.fill", studio.requests.count),
                                             ("Cola", "list.number", studio.waiting.count),
                                             ("Chat", "bubble.left.and.bubble.right.fill", 0),
                                             ("Compartir", "link", 0)]
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                    if i == 2 && studio.event.chat_mode == "off" { EmptyView() } else {
                        Button { tab = i } label: {
                            VStack(spacing: 4) {
                                Image(systemName: t.1).font(.system(size: 15, weight: .semibold))
                                    .overlay(alignment: .topTrailing) {
                                        if t.2 > 0 {
                                            Text("\(t.2)").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                                .background(Capsule().fill(i == 0 ? Color.orange : Color.amaPod)).offset(x: 10, y: -6)
                                        }
                                    }
                                Text(t.0).font(.system(size: 11, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(tab == i ? Color.white : Theme.secondary)
                            .background(RoundedRectangle(cornerRadius: 9).fill(tab == i ? AS.field : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
            Rectangle().fill(AS.line).frame(height: 1)
            switch tab {
            case 1: queuePanel
            case 2: chatPanel
            case 3: ScrollView { sharePanel.padding(18) }
            default: ScrollView { requestsPanel.padding(18) }
            }
        }
    }

    private var requestsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            AmaTitle(text: "Quieren preguntar", trailing: studio.requests.isEmpty ? nil : "\(studio.requests.count)")
            if studio.requests.isEmpty {
                Text("Nadie por ahora. Comparte el link para preguntar (pestaña Compartir).")
                    .font(.callout).foregroundStyle(Theme.secondary).padding(.vertical, 8)
            }
            ForEach(studio.requests) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Avatar(name: p.display_name, size: 30)
                        Text(p.display_name).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer()
                    }
                    questions(p)
                    HStack(spacing: 8) {
                        AmaButton(title: "Aceptar", symbol: "checkmark") { studio.approve(p) }
                        AmaButton(title: "Rechazar", symbol: "xmark", color: .red, filled: false) { studio.reject(p) }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 11).fill(AS.field))
            }
        }
    }

    @ViewBuilder private func questions(_ p: AmaClient.Person) -> some View {
        if let qs = p.questions, !qs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1).").font(.caption.weight(.bold)).foregroundStyle(Color.amaPod)
                        Text(q).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Text("Sin preguntas escritas").font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            AmaTitle(text: "En la cola", trailing: studio.waiting.isEmpty ? nil : "arrastra para ordenar").padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
            if studio.waiting.isEmpty {
                Text("Nadie en la cola. Acepta solicitudes para que aparezcan aquí.")
                    .font(.callout).foregroundStyle(Theme.secondary).padding(.horizontal, 18).padding(.vertical, 8)
                Spacer()
            } else {
                List {
                    ForEach(studio.waiting) { p in queueRow(p).listRowBackground(Color.clear).listRowSeparator(.hidden) }
                        .onMove { from, to in studio.move(from: from, to: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func queueRow(_ p: AmaClient.Person) -> some View {
        let connected = studio.tiles.contains { $0.pid == p.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(p.queue_position ?? 0)").font(.system(size: 13, weight: .heavy).monospacedDigit())
                    .frame(width: 24, height: 24).background(Circle().fill(Color.amaPod.opacity(0.18))).foregroundStyle(Color.amaPod)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.display_name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(connected ? "Conectado, listo para salir" : p.preconnected ? "Preparándose…" : "Esperando su turno")
                        .font(.caption).foregroundStyle(connected ? Theme.good : Theme.secondary)
                }
                Spacer()
                Button { studio.putOnAir(p) } label: {
                    Text("Al aire").font(.caption.weight(.bold)).padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(Color.amaPod)).foregroundStyle(.black)
                }
                .buttonStyle(.plain).help("Darle la palabra ahora, saltando la cola")
                Button { studio.remove(p) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26).background(Circle().fill(Color(white: 1, opacity: 0.08)))
                }
                .buttonStyle(.plain).help("Sacar de la cola")
            }
            questions(p)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(AS.field))
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            AmaTitle(text: "Chat del evento", trailing: chatModeName(studio.event.chat_mode))
            if studio.event.chat_mode == "moderated" {
                Text("Chat moderado: hoy amaPod no muestra los mensajes por aprobar; solo ves los ya publicados.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if studio.chat.isEmpty {
                            Text("Todavía no hay mensajes.").font(.callout).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(studio.chat) { m in
                            HStack(alignment: .top, spacing: 8) {
                                Avatar(name: m.sender_name, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(m.sender_name).font(.caption.bold()).foregroundStyle((m.is_host ?? 0) != 0 ? Color.amaPod : Theme.secondary)
                                        if (m.is_host ?? 0) != 0 { Text("HOST").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.amaPod) }
                                    }
                                    Text(m.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(AS.field))
                            .contextMenu { Button("Borrar mensaje", role: .destructive) { studio.deleteMessage(m) } }
                            .id(m.id)
                        }
                    }
                }
                .onChange(of: studio.chat.count) { _, _ in if let l = studio.chat.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            }
            HStack(spacing: 8) {
                AmaField(placeholder: "Escribe al público…", text: $chatText) { studio.say(chatText); chatText = "" }
                Button { studio.say(chatText); chatText = "" } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9).fill(chatText.isEmpty ? AS.field : Color.amaPod))
                        .foregroundStyle(chatText.isEmpty ? Theme.secondary : .black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
    }

    private var sharePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            AmaTitle(text: "Links del evento")
            linkRow("Para preguntar", "person.wave.2.fill", AmaClient.joinLink(studio.event.id), "para preguntar")
            Text("Se anotan con su nombre y hasta 3 preguntas. Tú los aceptas y decides el orden.")
                .font(.caption).foregroundStyle(Theme.secondary)
            linkRow("Para mirar", "eye.fill", AmaClient.watchLink(studio.event.id), "para mirar")
            Text("Miran sin cuenta, dan “me gusta” y desde ahí también pueden pedir preguntar.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }
}
