import SwiftUI
import AppKit

// MARK: - Deshacer / rehacer (0.13)

/// Cada cambio del proyecto se puede deshacer con ⌘Z y rehacer con ⇧⌘Z. Los cambios seguidos
/// (arrastrar un control, escribir) se juntan en un solo paso.
final class ProjectHistory {
    private(set) var undo: [Project] = []
    private(set) var redo: [Project] = []
    private var lastPush = Date.distantPast
    var isRestoring = false
    static let limit = 120

    func record(before old: Project) {
        guard !isRestoring else { return }
        let now = Date()
        if now.timeIntervalSince(lastPush) < 0.6, !undo.isEmpty {
            // Mismo gesto: se queda el estado de antes del primer cambio
            lastPush = now
            return
        }
        undo.append(old)
        if undo.count > Self.limit { undo.removeFirst() }
        redo.removeAll()
        lastPush = now
    }

    func popUndo(current: Project) -> Project? {
        guard let p = undo.popLast() else { return nil }
        redo.append(current)
        lastPush = .distantPast
        return p
    }

    func popRedo(current: Project) -> Project? {
        guard let p = redo.popLast() else { return nil }
        undo.append(current)
        lastPush = .distantPast
        return p
    }
}

extension ProjectSession {
    var canUndo: Bool { history.undo.count > 0 }
    var canRedo: Bool { history.redo.count > 0 }

    func undoChange() {
        guard let p = history.popUndo(current: project) else { return }
        history.isRestoring = true
        project = p
        history.isRestoring = false
        flashNote("Deshecho")
    }

    func redoChange() {
        guard let p = history.popRedo(current: project) else { return }
        history.isRestoring = true
        project = p
        history.isRestoring = false
        flashNote("Rehecho")
    }

    func flashNote(_ s: String) {
        note = s
        let id = UUID(); noteId = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if noteId == id { note = nil }
        }
    }

    // MARK: Atajos de teclado

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func nudge(_ seconds: Double) {
        let wasPlaying = player.rate > 0
        let t = min(max(0, playheadTimeline + seconds), max(0, project.duration))
        seek(timeline: t, play: wasPlaying)
    }

    /// I: marca el inicio de un reel en el reloj. O: marca el fin y crea el reel (o ajusta el reel que se está viendo).
    func markIn() {
        inPoint = playheadTimeline
        flashNote("Inicio marcado en \(Timecode.string(inPoint ?? 0)) · pulsa O al final")
    }

    func markOut() {
        let t = playheadTimeline
        if let r = previewReel, let i = project.reels.firstIndex(where: { $0.id == r.id }), inPoint == nil {
            // Viendo un reel sin inicio nuevo: O ajusta el final de ese reel
            if t > project.reels[i].start + 1 {
                project.reels[i].end = t
                previewReel = project.reels[i]
                flashNote("Fin del reel en \(Timecode.string(t))")
            }
            return
        }
        guard let a = inPoint else { flashNote("Primero marca el inicio con I"); return }
        let start = min(a, t), end = max(a, t)
        guard end - start >= 1 else { flashNote("El reel debe durar al menos 1 s"); return }
        let n = project.reels.count + 1
        let reel = Reel(title: "Momento \(n)", reason: "Marcado con I y O", start: start, end: end)
        project.reels.append(reel)
        inPoint = nil
        flashNote("Reel \(Timecode.string(start, tenths: false)) → \(Timecode.string(end, tenths: false)) · lo ves en Reels")
    }

    /// Qué hacer con una tecla cuando no se está escribiendo en un campo. Devuelve true si la usó.
    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            if chars == "z" { if flags.contains(.shift) { redoChange() } else { undoChange() }; return true }
            return false
        }
        switch e.keyCode {
        case 51, 117: return deleteSelectedVolumePoint()                     // Suprimir: quita el punto de volumen elegido
        case 49: togglePlay(); return true                                   // espacio
        case 123: nudge(flags.contains(.shift) ? -5 : -1); return true       // ←
        case 124: nudge(flags.contains(.shift) ? 5 : 1); return true         // →
        default: break
        }
        switch chars {
        case "m": _ = markMoment(); flashNote("Momento marcado · lo ves en Reels"); return true
        case "i": markIn(); return true
        case "o": markOut(); return true
        case "k": togglePlay(); return true
        case "j": nudge(-5); return true
        case "l": nudge(5); return true
        default: return false
        }
    }
}

/// Instala el monitor de teclado mientras el editor está en pantalla. No roba teclas de los campos de texto.
struct KeyShortcuts: ViewModifier {
    @ObservedObject var session: ProjectSession
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    // Si se está escribiendo (campo de texto, editor), no tocar
                    if let r = e.window?.firstResponder, r is NSTextView || r is NSTextField { return e }
                    if e.window?.firstResponder is NSText { return e }
                    return session.handleKey(e) ? nil : e
                }
            }
            .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

// MARK: - Plantillas de reel

/// Un diseño de reel guardado para usarlo en otros episodios (layout, opciones, marca, subtítulos, orden).
/// El logo y el fondo propios no se guardan: son archivos de cada episodio.
struct ReelTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var look: ReelLook

    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("postPod")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plantillas-reel.json")
    }
    static func load() -> [ReelTemplate] {
        (try? JSONDecoder().decode([ReelTemplate].self, from: Data(contentsOf: file))) ?? []
    }
    static func save(_ list: [ReelTemplate]) {
        try? JSONEncoder().encode(list).write(to: file, options: .atomic)
    }
    /// Lo que se aplica: todo menos los archivos del episodio.
    func applied(over current: ReelLook) -> ReelLook {
        var l = look
        l.logoFile = current.logoFile
        l.backgroundFile = current.backgroundFile
        return l
    }
}

/// Menú «Plantillas» para un diseño de reel: guardar el actual, aplicar una guardada, borrar.
struct ReelTemplateMenu: View {
    @Binding var look: ReelLook
    @State private var templates = ReelTemplate.load()
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        Menu {
            if templates.isEmpty {
                Text("No hay plantillas guardadas")
            } else {
                ForEach(templates) { t in
                    Button(t.name) { look = t.applied(over: look) }
                }
                Divider()
                Menu("Borrar plantilla") {
                    ForEach(templates) { t in
                        Button(t.name, role: .destructive) { templates.removeAll { $0.id == t.id }; ReelTemplate.save(templates) }
                    }
                }
                Divider()
            }
            Button("Guardar este diseño como plantilla…") { name = ""; naming = true }
        } label: {
            Label("Plantillas", systemImage: "square.on.square")
        }
        .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
        .help("Guarda este diseño para usarlo en otros episodios, o aplica uno guardado")
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Guardar plantilla de reel").font(.headline)
                Text("Guarda el diseño, las opciones, la marca (sin los archivos de logo y fondo), los subtítulos y el orden. Luego se aplica con un clic en cualquier episodio.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                TextField("Nombre, ej.: Reel vertical con cintillo", text: $name).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancelar") { naming = false }
                    Button("Guardar") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        templates.removeAll { $0.name == n }
                        templates.append(ReelTemplate(name: n, look: look))
                        ReelTemplate.save(templates)
                        naming = false
                    }
                    .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 420)
        }
        .onAppear { templates = ReelTemplate.load() }
    }
}

// MARK: - Ayuda por sección

enum Help {
    static func text(for step: Step) -> String {
        switch step {
        case .overview:
            return """
            Aquí ves las grabaciones que llegaron: una pista por persona. Ponle nombre a cada una (sale en el video) \
            y revisa que estén todas. Si falta alguien, impórtala con ⌘O. Si una persona se oye desfasada, en su panel \
            puedes correrla unos décimas con «Desfase».
            """
        case .fix:
            return """
            «Arreglar todo» hace tres cosas: sonido de estudio (quita ruido y empareja el volumen), quita los silencios \
            largos y las muletillas («eeeh»). Nada se borra de verdad: cada corte queda en la lista y se puede apagar. \
            En el timeline: arrastra un trozo para cortarlo de todos, o solo callar o bajar a una persona ahí (si tose, \
            si gritó). Doble clic sobre una persona pone un punto en su línea de volumen: arrástralo arriba o abajo.
            """
        case .captions:
            return """
            La transcripción se hace en tu Mac, sin internet. Doble clic en una palabra para corregirla; las tijeras \
            quitan una frase del video. Elige un estilo y arrástralos sobre el video para ponerlos donde quieras. \
            «Guardar .srt» te da el archivo para YouTube.
            """
        case .sensitive:
            return """
            Busca en la transcripción groserías y palabras que las redes bajan de alcance (muerte, suicidio, drogas, \
            sexo, armas…). Para cada una eliges: pitido encima (no se oye) y/o cambiar el subtítulo por la palabra que se \
            usa en redes para decir lo mismo (desvivirse, intimidad, sustancias…). También puedes agregar tus propias \
            palabras. El audio original no se toca: el pitido y el cambio van en la vista previa y en el export.
            """
        case .look:
            return """
            Cómo se ve el video: el diseño (quién sale dónde), el orden de las personas, espejo, fondo virtual por \
            persona, color, la marca del podcast (fondo, logo, nombres) y la intro y el cierre. Lo que eliges aquí \
            vale para YouTube, reels y cuadrado; cada formato se acomoda solo.
            """
        case .layers:
            return """
            Capas encima del video un rato: textos (título, caja, etiqueta), imágenes PNG/JPG, stickers (emojis) y \
            b-roll (un video o foto que tapa la pantalla o va en una ventanita, máximo 10 s). Se mueven con el ratón \
            sobre la vista previa y se ubican en el tiempo con el campo h:mm:ss o el botón «Aquí».
            """
        case .cintillos:
            return """
            Los textos tipo noticiero que entran abajo. Tres estilos: Noticiero, Limpio y Sponsor. Los que puso el \
            director en vivo llegan solos y se pueden editar; aquí agregas los que faltaron. Tienen animación de \
            entrada y salida y un sonido bajo opcional.
            """
        case .sounds:
            return """
            Música y efectos del soundboard, y voz artificial. «Al inicio» y «Al final» respetan el intro y el \
            cierre. La música puede bajar sola cuando alguien habla y repetirse en bucle. Cada pista tiene volumen, \
            fades y se mueve con el campo h:mm:ss.
            """
        case .brands:
            return """
            Los sponsors del guion de prePod salen en el minuto donde iban, con su logo. Los cintillos del director \
            quedan donde los puso en vivo. Aquí los apagas o cambias el momento; para crear cintillos nuevos usa la \
            sección Cintillos.
            """
        case .reels:
            return """
            Cada momento marcado (en postPod, con «Marcar momento» o con las teclas I y O) es un video vertical. \
            Cada reel se edita por pestañas: Diseño, Subtítulos (cómo se ven y el texto), Música, B-roll y Cintillos; todo aparte \
            del episodio. Con «Plantillas» guardas un diseño y lo reusas en otros episodios. El botón de bajar exporta \
            solo ese reel.
            """
        case .export:
            return """
            Elige para dónde va (YouTube 16:9, reels 9:16, cuadrado, solo audio). H.264 es el que abre en todos lados; \
            HEVC pesa la mitad. El volumen se ajusta a −16 LUFS (lo que piden Spotify y YouTube). Los archivos \
            quedan en la carpeta de exportados.
            """
        case .publish:
            return """
            Publica con lo que ya tienes configurado en prePod: el feed para Spotify y Apple Podcasts y tu canal de \
            YouTube. Si algo falla, el aviso te dice qué falta configurar en prePod.
            """
        }
    }

    static let shortcuts = """
    Atajos en el editor (cuando no estás escribiendo en un campo):
    Espacio o K · reproducir / pausar
    ← → · un segundo atrás / adelante (con ⇧, cinco)
    J / L · cinco segundos atrás / adelante
    M · marcar momento (crea un reel de 60 s desde aquí)
    Doble clic sobre una persona en el timeline · punto de volumen · arrástralo · Suprimir lo quita
    Arrastra un trozo sobre una persona · «Silenciar solo a…» / «−6 dB a…» / «Cortar de todos»
    I · marcar inicio de un reel · O · marcar fin y crearlo (viendo un reel, O ajusta su fin)
    ⌘Z · deshacer · ⇧⌘Z · rehacer
    """
}

/// Botón «?» que abre una explicación corta de la sección.
struct HelpButton: View {
    let step: Step
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "questionmark.circle").font(.title3) }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            .help("¿Qué es esto?")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.title).font(.headline)
                    Text(Help.text(for: step)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(Help.shortcuts).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(width: 420)
            }
    }
}


// MARK: - Mezcla (0.14): solo, mudo y nivel

extension ProjectSession {
    func toggleSolo(_ laneId: Int) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        project.lanes[i].solo.toggle()
    }

    func toggleMute(_ laneId: Int) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        project.lanes[i].muted.toggle()
    }

    /// Nivel 0…1 de una persona en este instante: el dB del análisis en el reloj, con el volumen de la pista.
    /// Es lo analizado, no una medición de la salida; sirve para ver quién suena y cuánto.
    func laneLevel(_ laneId: Int) -> Double {
        // Reproduciendo: lo que realmente suena de esa persona (con todo lo que le hace la mezcla)
        if player.rate > 0, let db = built?.levelDB(lane: laneId, at: player.currentTime().seconds) {
            return min(1, max(0, (db + 60) / 60))
        }
        // En pausa: una estimación con el análisis del sonido y el volumen de la pista
        guard let energy, let lane = project.lanes.first(where: { $0.id == laneId }), project.laneAudible(lane) else { return 0 }
        let t = playheadTimeline
        var db = Double(energy.db(lane: laneId, at: t))
        if lane.volume > 0 { db += 20 * log10(lane.volume) } else { return 0 }
        return min(1, max(0, (db + 60) / 60))
    }
}


// MARK: - Palabras sensibles

extension ProjectSession {
    func scanSensitive() {
        project.sensitive = SensitiveWords.scan(project)
        project.sensitiveScanned = true
        let n = project.sensitive.filter { !$0.ignored }.count
        flashNote(n == 0 ? "No se encontraron palabras sensibles" : "\(n) palabras encontradas")
    }

    func sensitiveBinding(_ id: String) -> Binding<SensitiveMark>? {
        guard let i = project.sensitive.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.project.sensitive[i] }, set: { self.project.sensitive[i] = $0 })
    }

    func setAllSensitive(bleep: Bool? = nil, replace: Bool? = nil, category: SensitiveWords.Category? = nil) {
        for i in project.sensitive.indices where category == nil || project.sensitive[i].category == category {
            if let bleep { project.sensitive[i].bleep = bleep }
            if let replace { project.sensitive[i].replace = replace }
        }
    }

    /// Frase corta alrededor de una palabra, para ver el contexto.
    func contextAround(_ m: SensitiveMark) -> String {
        let ws = project.words.filter { $0.lane == m.lane && $0.s >= m.s - 3 && $0.s <= m.e + 3 }.sorted { $0.s < $1.s }
        return ws.map { $0.w }.joined(separator: " ")
    }
}

// MARK: - Volumen dibujado (0.16)

extension ProjectSession {
    func addVolumePoint(laneId: Int, t: Double, db: Double) -> UUID? {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return nil }
        let tt = min(max(0, t), project.duration)
        let d = min(VolumePoint.maxDB, max(VolumePoint.minDB, db))
        // Si la línea estaba plana, el primer punto va acompañado de dos extremos para que el resto siga igual
        if project.lanes[i].volumePoints.isEmpty {
            project.lanes[i].volumePoints = [VolumePoint(t: 0, db: 0), VolumePoint(t: project.duration, db: 0)]
        }
        let p = VolumePoint(t: tt, db: d)
        project.lanes[i].volumePoints.append(p)
        selectedVolumePoint = (laneId, p.id)
        return p.id
    }

    func moveVolumePoint(laneId: Int, id: UUID, t: Double, db: Double) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }),
              let j = project.lanes[i].volumePoints.firstIndex(where: { $0.id == id }) else { return }
        project.lanes[i].volumePoints[j].t = min(max(0, t), project.duration)
        project.lanes[i].volumePoints[j].db = min(VolumePoint.maxDB, max(VolumePoint.minDB, db))
    }

    func removeVolumePoint(laneId: Int, id: UUID) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        project.lanes[i].volumePoints.removeAll { $0.id == id }
        if project.lanes[i].volumePoints.allSatisfy({ $0.db == 0 }) { project.lanes[i].volumePoints = [] }
        selectedVolumePoint = nil
    }

    func clearVolumePoints(laneId: Int) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }) else { return }
        project.lanes[i].volumePoints = []
        selectedVolumePoint = nil
    }

    /// Un tramo de UNA persona: silenciar solo ahí (−60 dB) o bajar X dB. Son cuatro puntos en la línea.
    func shapeVolume(laneId: Int, from a: Double, to b: Double, db: Double) {
        guard let i = project.lanes.firstIndex(where: { $0.id == laneId }), b - a > 0.05 else { return }
        let lane = project.lanes[i]
        let before = lane.automationDB(at: a - 0.06), after = lane.automationDB(at: b + 0.06)
        if project.lanes[i].volumePoints.isEmpty {
            project.lanes[i].volumePoints = [VolumePoint(t: 0, db: 0), VolumePoint(t: project.duration, db: 0)]
        }
        // Quitar los puntos que caen dentro y poner los cuatro nuevos
        project.lanes[i].volumePoints.removeAll { $0.t > a - 0.06 && $0.t < b + 0.06 }
        project.lanes[i].volumePoints += [VolumePoint(t: max(0, a - 0.05), db: before), VolumePoint(t: a, db: db),
                                           VolumePoint(t: b, db: db), VolumePoint(t: min(project.duration, b + 0.05), db: after)]
        flashNote(db <= VolumePoint.minDB ? "\(project.laneName(laneId)) en silencio en ese tramo" : "\(project.laneName(laneId)) \(Int(db)) dB en ese tramo")
    }

    func deleteSelectedVolumePoint() -> Bool {
        guard let sel = selectedVolumePoint else { return false }
        removeVolumePoint(laneId: sel.lane, id: sel.id)
        return true
    }
}
