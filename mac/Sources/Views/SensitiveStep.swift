import SwiftUI

/// Preparar → Palabras sensibles: groserías y temas que las redes bajan de alcance.
/// Para cada una: pitido encima y/o cambiar el subtítulo por el eufemismo de redes.
struct SensitiveStep: View {
    @ObservedObject var session: ProjectSession
    @State private var newWord = ""
    @State private var filter: SensitiveWords.Category? = nil

    var body: some View {
        let p = session.project
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(title: String(localized: "Palabras sensibles"),
                               subtitle: String(localized: "Groserías y palabras que las redes bajan de alcance. Pitido encima, subtítulo cambiado, o las dos cosas. El audio original no se toca."),
                               step: .sensitive)

                    if !p.isTranscribed {
                        EmptyHint(symbol: "captions.bubble", title: String(localized: "Primero los subtítulos"),
                                  text: String(localized: "Esta sección busca en la transcripción. Ve a Subtítulos y transcribe el episodio."))
                    } else {
                        HStack(spacing: 10) {
                            Button { session.scanSensitive() } label: {
                                Label(p.sensitiveScanned ? "Buscar de nuevo" : "Buscar palabras sensibles", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            if p.sensitiveScanned {
                                Text(summary(p)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }

                        if p.sensitiveScanned && !p.sensitive.isEmpty {
                            Card {
                                Text("Para todas").font(.headline)
                                HStack(spacing: 8) {
                                    Button("Pitido en groserías") { session.setAllSensitive(bleep: true, category: .groseria) }
                                    Button("Pitido en todas") { session.setAllSensitive(bleep: true) }
                                    Button("Sin pitido") { session.setAllSensitive(bleep: false) }
                                }
                                HStack(spacing: 8) {
                                    Button("Cambiar subtítulo en todas") { session.setAllSensitive(replace: true) }
                                    Button("No cambiar subtítulos") { session.setAllSensitive(replace: false) }
                                }
                                .controlSize(.small)
                                Text("Groserías: pitido y subtítulo suavizado. Temas sensibles (muerte, drogas, sexo, armas…): solo cambia el subtítulo, se oye igual. Lo puedes cambiar palabra por palabra.")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }

                            HStack(spacing: 6) {
                                Picker("", selection: $filter) {
                                    Text("Todas").tag(SensitiveWords.Category?.none)
                                    Text("Groserías").tag(SensitiveWords.Category?.some(.groseria))
                                    Text("Temas sensibles").tag(SensitiveWords.Category?.some(.sensible))
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                                Spacer()
                            }

                            VStack(spacing: 8) {
                                ForEach(p.sensitive.filter { filter == nil || $0.category == filter }) { m in
                                    SensitiveRow(session: session, id: m.id)
                                }
                            }
                        }

                        if p.sensitiveScanned && p.sensitive.isEmpty {
                            EmptyHint(symbol: "checkmark.seal", title: String(localized: "Nada que tapar"),
                                      text: String(localized: "No se encontraron groserías ni palabras sensibles en la transcripción. Si falta alguna, agrégala a la derecha y vuelve a buscar."))
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }
            VStack(spacing: 14) {
                PreviewPane(session: session)
                Card {
                    Text("Mis palabras").font(.headline)
                    Text("Palabras que también quieres tapar (nombres, marcas, lo que sea). Se buscan como groserías: pitido y subtítulo con asteriscos.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    HStack {
                        TextField("Escribe una palabra y Enter", text: $newWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addWord() }
                        Button("Agregar") { addWord() }.disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !p.sensitiveCustom.isEmpty {
                        FlowWrap(items: p.sensitiveCustom) { w in
                            HStack(spacing: 4) {
                                Text(w).font(.caption)
                                Button { session.project.sensitiveCustom.removeAll { $0 == w } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                }
            }
            .frame(width: 440)
            .padding(.trailing, 28).padding(.top, 28)
        }
    }

    private func summary(_ p: Project) -> String {
        let live = p.sensitive.filter { !$0.ignored }
        let g = live.filter { $0.category == .groseria }.count, s = live.count - g
        let b = live.filter(\.bleep).count, r = live.filter(\.replace).count
        return String(localized: "\(g) groserías · \(s) temas sensibles · \(b) con pitido · \(r) con subtítulo cambiado")
    }

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !session.project.sensitiveCustom.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { newWord = ""; return }
        session.project.sensitiveCustom.append(w)
        newWord = ""
        if session.project.sensitiveScanned { session.scanSensitive() }
    }
}

private struct SensitiveRow: View {
    @ObservedObject var session: ProjectSession
    let id: String

    var body: some View {
        if let b = session.sensitiveBinding(id) {
            let m = b.wrappedValue
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { session.seek(timeline: max(0, m.s - 1.5), play: true) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless).help("Oír alrededor")
                    Text(Timecode.string(m.s, tenths: false)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    Text(session.project.laneName(m.lane)).font(.caption).foregroundStyle(Theme.secondary)
                    Text(m.word).font(.headline).strikethrough(m.ignored)
                    Text(m.category == .groseria ? "grosería" : "tema sensible")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(m.category == .groseria ? Color.red.opacity(0.25) : Color.orange.opacity(0.25)))
                    Spacer()
                    Button(m.ignored ? "Volver a tapar" : "Está bien así") { b.wrappedValue.ignored.toggle() }
                        .controlSize(.small)
                }
                Text("“\(session.contextAround(m))”").font(.callout).foregroundStyle(Theme.secondary).lineLimit(2)
                if !m.ignored {
                    HStack(spacing: 14) {
                        Toggle("Pitido encima", isOn: b.bleep).toggleStyle(.switch).controlSize(.small)
                        Toggle("Cambiar subtítulo por", isOn: b.replace).toggleStyle(.switch).controlSize(.small)
                        TextField("palabra", text: b.replacement).textFieldStyle(.roundedBorder).frame(width: 170)
                            .disabled(!m.replace)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.opacity(m.ignored ? 0.5 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        }
    }
}

/// Píldoras que bajan de línea.
struct FlowWrap<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content
    var body: some View {
        var width: CGFloat = 0, height: CGFloat = 0
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.self) { item in
                    content(item)
                        .padding(.trailing, 6).padding(.bottom, 6)
                        .alignmentGuide(.leading) { d in
                            if abs(width - d.width) > g.size.width { width = 0; height -= d.height }
                            let r = width
                            if item == items.last { width = 0 } else { width -= d.width }
                            return r
                        }
                        .alignmentGuide(.top) { _ in
                            let r = height
                            if item == items.last { height = 0 }
                            return r
                        }
                }
            }
        }
        .frame(minHeight: 30)
    }
}
