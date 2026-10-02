import SwiftUI

// MARK: - Cintillos (textos tipo noticiero que entran abajo, con animación y sonido)

struct CintillosStep: View {
    @ObservedObject var session: ProjectSession

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: "Cintillos",
                               subtitle: "Los textos tipo noticiero que entran abajo, con animación y un sonido bajo. Los del director llegan solos de prodPod; aquí agregas los que faltaron al grabar.")
                    Card {
                        Text("Agregar donde está el video").font(.headline)
                        HStack(spacing: 10) {
                            styleButton("Noticiero", help: "Dos barras: color con etiqueta y título, blanco con el texto. Logo a la izquierda.") {
                                _ = session.addCintillo(style: "news", kind: "banner", logoFile: session.project.logoFile, tag: "AHORA")
                            } preview: { newsPreview }
                            styleButton("Limpio", help: "Una línea de color, título grande y texto chico. Sin cajas.") {
                                _ = session.addCintillo(style: "clean", kind: "comment")
                            } preview: { cleanPreview }
                            styleButton("Sponsor", help: "Tarjeta con el logo del sponsor grande, PATROCINA y la frase.") {
                                _ = session.addCintillo(style: "sponsor", kind: "sponsor", tag: "PATROCINA")
                            } preview: { sponsorPreview }
                        }
                        if !session.project.sponsors.isEmpty {
                            HStack(spacing: 8) {
                                Text("De un sponsor de prePod:").font(.caption).foregroundStyle(Theme.secondary)
                                ForEach(session.project.sponsors) { sp in
                                    Button(sp.name) { session.addSponsorCintillo(sp) }.controlSize(.small)
                                }
                            }
                        }
                    }
                    Card {
                        HStack {
                            Text(session.project.cintillos.isEmpty ? "Todavía no hay cintillos" : "En este episodio").font(.headline)
                            Spacer()
                            if !session.project.cintillos.isEmpty {
                                Toggle("Mostrar", isOn: $session.project.showCintillos).toggleStyle(.switch).controlSize(.mini).font(.caption)
                            }
                        }
                        if session.project.cintillos.isEmpty {
                            Text("Cada cintillo entra abajo a la izquierda, se queda los segundos que digas y se va solo. Al tocarlo se edita debajo del video.")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                        ForEach(session.project.cintillos.sorted { $0.start < $1.start }) { c in
                            row(c)
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

    private func styleButton<P: View>(_ title: String, help: String, _ action: @escaping () -> Void, @ViewBuilder preview: () -> P) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview().frame(width: 72, height: 26)
                Text(title).font(.callout.bold())
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var newsPreview: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#F2EDE6")).frame(width: 22)
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#D64545"))
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#F2EDE6"))
            }
        }
    }
    private var cleanPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 26, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#F2EDE6")).frame(height: 9)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#8A8278")).frame(width: 46, height: 6)
        }
    }
    private var sponsorPreview: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#F2EDE6")).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 20, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#F2EDE6")).frame(height: 12)
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5)))
    }

    private func row(_ c: DirectorCintillo) -> some View {
        let sel = session.selectedTrack == .cintillo(c.id)
        return Button {
            session.selectedTrack = .cintillo(c.id)
            session.seek(timeline: max(0, c.start - 0.5), play: false)
        } label: {
            HStack(spacing: 10) {
                Group {
                    switch c.style {
                    case "clean": cleanPreview
                    case "sponsor": sponsorPreview
                    default: newsPreview
                    }
                }
                .frame(width: 40, height: 16)
                Text(c.title.isEmpty ? c.text : c.title).lineLimit(1)
                if c.fromDirector { Text("del director").font(.caption2).foregroundStyle(Theme.secondary) }
                Spacer()
                Text("\(EditEngine.clock(c.start)) · \(String(format: "%.0f s", c.duration))")
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Theme.panelStrong : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sel ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Panel bajo el video para el cintillo elegido.
struct CintilloEditor: View {
    @ObservedObject var session: ProjectSession
    let id: Int

    static let colors = ["#D64545", "#6B8FE6", "#E8B85A", "#2E9E6B", "#7C2D3D", "#111111"]
    static let tags = ["AHORA", "SEGMENTO", "PATROCINA", "EN VIVO", "DATO", ""]

    private var current: DirectorCintillo? { session.project.cintillos.first { $0.id == id } }
    private var c: Binding<DirectorCintillo> {
        Binding(get: { current ?? DirectorCintillo(id: id, kind: "banner", title: "", text: "", start: 0, duration: 6) },
                set: { v in if let i = session.project.cintillos.firstIndex(where: { $0.id == id }) { session.project.cintillos[i] = v } })
    }

    var body: some View {
        if let cin = current { editor(cin) }
    }

    @ViewBuilder
    private func editor(_ cin: DirectorCintillo) -> some View {
        HStack {
            Label("Cintillo · " + (cin.style == "clean" ? "Limpio" : cin.style == "sponsor" ? "Sponsor" : "Noticiero"), systemImage: "rectangle.bottomthird.inset.filled").font(.headline)
            if cin.fromDirector { Text("del director").font(.caption).foregroundStyle(Theme.secondary) }
            Spacer()
            Button { session.duplicateCintillo(cin.id) } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.borderless).help("Duplicar donde está el video")
            Button(role: .destructive) { session.removeCintillo(cin.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Quitar")
            Button { session.selectedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
        }
        HStack(spacing: 8) {
            Text("Estilo").frame(width: 72, alignment: .leading)
            Picker("", selection: c.style) {
                Text("Noticiero").tag("news"); Text("Limpio").tag("clean"); Text("Sponsor").tag("sponsor")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
        }
        .font(.callout)
        HStack(spacing: 8) {
            Text(cin.style == "sponsor" ? "Sponsor" : "Título").frame(width: 72, alignment: .leading)
            TextField("", text: c.title).textFieldStyle(.roundedBorder)
        }
        .font(.callout)
        HStack(spacing: 8) {
            Text("Texto").frame(width: 72, alignment: .leading)
            TextField("", text: c.text).textFieldStyle(.roundedBorder)
        }
        .font(.callout)
        if cin.style != "clean" {
            HStack(spacing: 6) {
                Text("Etiqueta").frame(width: 72, alignment: .leading)
                ForEach(Self.tags, id: \.self) { t in
                    Button(t.isEmpty ? "Sin etiqueta" : t) { c.wrappedValue.tag = t }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .tint(cin.tagText == t ? Theme.accent : nil)
                }
                TextField("Otra…", text: Binding(get: { Self.tags.contains(cin.tagText) ? "" : cin.tagText },
                                                  set: { c.wrappedValue.tag = $0.uppercased() }))
                    .textFieldStyle(.roundedBorder).frame(width: 90).controlSize(.small)
            }
            .font(.callout)
        }
        HStack(spacing: 8) {
            Text("Color").frame(width: 72, alignment: .leading)
            Button { c.wrappedValue.color = nil } label: {
                Text("Del podcast").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(cin.color == nil ? Theme.accent.opacity(0.35) : Theme.panelStrong))
            }
            .buttonStyle(.plain)
            ForEach(Self.colors, id: \.self) { col in
                Button { c.wrappedValue.color = col } label: {
                    Circle().fill(Color(hex: col)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(cin.color == col ? Theme.accent : Color.white.opacity(0.3), lineWidth: cin.color == col ? 2.5 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        if cin.style != "clean" {
            HStack(spacing: 8) {
                Text("Logo").frame(width: 72, alignment: .leading)
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.panelStrong)
                    if let f = cin.logoFile, let img = NSImage(contentsOf: ProjectStore.url(f, in: session.project.id)) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(2)
                    } else {
                        Text(String(cin.title.prefix(1)).uppercased()).font(.caption.bold())
                    }
                }
                .frame(width: 36, height: 26)
                if let pl = session.project.logoFile {
                    Button("Del podcast") { c.wrappedValue.logoFile = pl }.controlSize(.small)
                }
                Button("Elegir…") { session.chooseCintilloLogo(cin.id) }.controlSize(.small)
                Button("Sin logo") { c.wrappedValue.logoFile = nil }.controlSize(.small)
                Text(cin.logoFile == nil ? "Sin logo sale la inicial del título." : "").font(.caption2).foregroundStyle(Theme.secondary)
            }
            .font(.callout)
        }
        HStack(spacing: 6) {
            Text("Empieza").frame(width: 72, alignment: .leading)
            Button("−1 s") { c.wrappedValue.start = max(0, cin.start - 1) }
            Text(EditEngine.clock(cin.start)).monospacedDigit().frame(width: 56)
            Button("+1 s") { c.wrappedValue.start = min(session.project.duration, cin.start + 1) }
            Button("Aquí") { c.wrappedValue.start = session.playheadTimeline }.help("Donde está el video ahora")
            Spacer().frame(width: 10)
            Text("Dura").frame(width: 36)
            Slider(value: c.duration, in: 2...20, step: 0.5).frame(maxWidth: 160)
            Text(String(format: "%.0f s", cin.duration)).monospacedDigit().frame(width: 32, alignment: .trailing)
        }
        .font(.callout).controlSize(.small)
        HStack {
            Toggle("Sonido al entrar y salir (bajo)", isOn: c.sound).toggleStyle(.checkbox).font(.callout)
            Spacer()
            Button { session.seek(timeline: max(0, cin.start - 0.5), play: true) } label: { Label("Ver", systemImage: "play.fill") }.controlSize(.small)
        }
        Text("Abajo a la izquierda, encima del video y debajo de los subtítulos. Entra con el logo, se despliegan las barras y aparece el texto; sale a la izquierda. Si hay dos a la vez, el segundo sube.")
            .font(.caption2).foregroundStyle(Theme.secondary)
    }
}
