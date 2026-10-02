import SwiftUI

/// Timeline del episodio (como el de postPod web, para ver y moverse):
/// una fila por persona con cuándo habla, lo que se corta, momentos/reels, sponsors y efectos.
/// Clic o arrastre para mover el video; zoom para ver detalle.
struct EpisodeTimeline: View {
    @ObservedObject var session: ProjectSession
    @State private var zoom: Double = 1
    @State private var collapsed = false
    @State private var selection: (start: Double, end: Double)?   // trozo marcado con el ratón (tiempo del episodio)
    @State private var dragAnchor: Double?

    static let palette: [Color] = [
        Color(red: 0.353, green: 0.545, blue: 1.0),    // azul prePod
        Color(red: 0.078, green: 0.722, blue: 0.651),  // teal amaPod
        Color(red: 1.0, green: 0.42, blue: 0.42),
        Color(red: 0.72, green: 0.55, blue: 1.0),
        Color(red: 0.45, green: 0.85, blue: 0.5),
        Color(red: 1.0, green: 0.62, blue: 0.3),
    ]

    private let labelWidth: CGFloat = 132
    private let rulerH: CGFloat = 18
    private let marksH: CGFloat = 16
    private let laneH: CGFloat = 36
    private let fxH: CGFloat = 12
    private let ovH: CGFloat = 14

    var body: some View {
        let p = session.project
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeOut(duration: 0.2)) { collapsed.toggle() } } label: {
                    Label("Timeline", systemImage: collapsed ? "chevron.right" : "chevron.down").font(.callout.bold())
                }
                .buttonStyle(.plain)
                if !collapsed {
                    legend
                    Text(p.normalizeLoudness ? "Volumen final: −16 LUFS al exportar" : "Volumen final: sin ajuste")
                        .font(.caption2).foregroundStyle(p.normalizeLoudness ? Theme.secondary : .orange)
                        .help("Lo que piden Spotify y YouTube. Se mide y se corrige al exportar; se apaga en Exportar.")
                    Spacer()
                    if let sel = selection, sel.end - sel.start > 0.05 {
                        HStack(spacing: 8) {
                            Text("\(EditEngine.clock(sel.start)) – \(EditEngine.clock(sel.end)) · \(String(format: "%.1f s", sel.end - sel.start))")
                                .font(.caption).monospacedDigit()
                            Button { session.seek(timeline: sel.start, play: true) } label: { Label("Oír", systemImage: "play.fill") }
                                .controlSize(.small)
                            Button(role: .destructive) { session.cutRange(sel.start, sel.end); selection = nil } label: { Label("Cortar este trozo", systemImage: "scissors") }
                                .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                            Button { selection = nil } label: { Image(systemName: "xmark") }.controlSize(.small)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelStrong))
                    } else {
                        Text("Clic: ir ahí · arrastra: marcar un trozo para cortarlo").font(.caption2).foregroundStyle(Theme.secondary)
                    }
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondary)
                    Slider(value: $zoom, in: 1...30).frame(width: 140)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.secondary)
                } else {
                    Spacer()
                }
            }
            if !collapsed && p.duration > 0 {
                let rows = rowLayout(p)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: rulerH + marksH)
                        ForEach(Array(p.lanes.enumerated()), id: \.element.id) { i, lane in
                            let sel = session.selectedTrack == .lane(lane.id)
                            let color = Self.palette[i % Self.palette.count]
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 3) {
                                    Button {
                                        session.selectedTrack = sel ? nil : .lane(lane.id)
                                    } label: {
                                        Text(p.laneName(lane.id)).lineLimit(1).font(.caption)
                                            .foregroundStyle(p.laneAudible(lane) ? color : Theme.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 3)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(sel ? Color.white.opacity(0.14) : .clear))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Toca para editar esta pista (volumen, fades, desfase)")
                                    LaneToggle(letter: "S", on: lane.solo, onColor: Theme.accent, help: "Solo: se oye solo esta persona") {
                                        session.toggleSolo(lane.id)
                                    }
                                    LaneToggle(letter: "M", on: lane.muted, onColor: .red, help: "Mudo: esta persona no suena") {
                                        session.toggleMute(lane.id)
                                    }
                                }
                                LaneMeter(session: session, laneId: lane.id, color: color)
                            }
                            .frame(width: labelWidth - 8, height: laneH, alignment: .leading)
                        }
                        Text("Efectos").font(.caption2).foregroundStyle(Theme.secondary)
                            .frame(width: labelWidth - 8, height: fxH, alignment: .leading)
                        if !p.overlays.isEmpty || !p.brolls.isEmpty {
                            Text(p.brolls.isEmpty ? "Textos" : "Textos · b-roll").font(.caption2).foregroundStyle(Theme.secondary)
                                .frame(width: labelWidth - 8, height: ovH, alignment: .leading)
                        }
                    }
                    .frame(width: labelWidth)
                    GeometryReader { geo in
                        let width = max(geo.size.width, geo.size.width * zoom)
                        let pps = width / p.duration
                        ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                            ZStack(alignment: .topLeading) {
                                TimelineCanvas(model: TimelineModel(project: p, energy: session.energy, selectedOverlay: selectedOverlay, selectedBRoll: selectedBRoll), pps: pps,
                                               rulerH: rulerH, marksH: marksH, laneH: laneH, fxH: fxH, ovH: ovH)
                                    .equatable()
                                if let sel = selection {
                                    Rectangle().fill(Color.white.opacity(0.18))
                                        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                                        .frame(width: max(1, CGFloat(sel.end - sel.start) * pps), height: rows)
                                        .offset(x: CGFloat(sel.start) * pps)
                                        .allowsHitTesting(false)
                                }
                                PlayheadLayer(session: session, pps: pps, height: rows)
                            }
                            .frame(width: width, height: rows)
                            .contentShape(Rectangle())
                            .highPriorityGesture(DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let t = min(max(0, Double(g.location.x / pps)), p.duration)
                                    if dragAnchor == nil {
                                        dragAnchor = min(max(0, Double(g.startLocation.x / pps)), p.duration)
                                    }
                                    let a = dragAnchor ?? t
                                    if abs(g.translation.width) > 4 {
                                        selection = (min(a, t), max(a, t))
                                    }
                                }
                                .onEnded { g in
                                    let t = min(max(0, Double(g.location.x / pps)), p.duration)
                                    if abs(g.translation.width) <= 4 {
                                        selection = nil
                                        // Clic en la fila de textos: elegir esa capa para editarla
                                        let oy = rulerH + marksH + CGFloat(p.lanes.count) * laneH + fxH
                                        if (!p.overlays.isEmpty || !p.brolls.isEmpty), g.location.y >= oy, g.location.y <= oy + ovH {
                                            if let o = p.overlays.filter({ t >= $0.start - 0.3 && t <= $0.end + 0.3 }).max(by: { $0.start < $1.start }) {
                                                session.selectedTrack = .overlay(o.id)
                                                if session.step != .layers { session.step = .layers }
                                            } else if let b = p.brolls.filter({ t >= $0.start - 0.3 && t <= $0.end + 0.3 }).max(by: { $0.start < $1.start }) {
                                                session.selectedTrack = .broll(b.id)
                                                if session.step != .layers { session.step = .layers }
                                            }
                                        }
                                        seek(to: t, duration: p.duration)
                                    } else if let a = dragAnchor {
                                        selection = (min(a, t), max(a, t))
                                        session.seek(timeline: min(a, t), play: false)
                                    }
                                    dragAnchor = nil
                                })
                        }
                    }
                    .frame(height: rows)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(Color.red.opacity(0.55), "Se corta")
            legendItem(Theme.accent, "Momento / reel")
            legendItem(Color.purple.opacity(0.8), "Sponsor")
            legendItem(Color.white.opacity(0.8), "Efecto")
            legendItem(Color.yellow.opacity(0.75), "Texto")
        }
        .font(.caption2)
        .foregroundStyle(Theme.secondary)
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8); Text(t) }
    }

    private func rowLayout(_ p: Project) -> CGFloat {
        rulerH + marksH + CGFloat(p.lanes.count) * laneH + fxH + ((p.overlays.isEmpty && p.brolls.isEmpty) ? 0 : ovH) + 4
    }

    private var selectedOverlay: Int? {
        if case .overlay(let id) = session.selectedTrack { return id }
        return nil
    }
    private var selectedBRoll: Int? {
        if case .broll(let id) = session.selectedTrack { return id }
        return nil
    }

    private func seek(to t: Double, duration: Double) {
        var t = min(max(0, t), duration)
        if let w = session.previewWindow { t = min(max(t, w.start), w.end) }   // viendo un reel: dentro del reel
        session.seek(timeline: t, play: false)
    }
}

/// Datos ya calculados para dibujar (no cambian mientras se reproduce).
struct TimelineModel: Equatable {
    var duration: Double
    var lanes: [[ClosedRange<Double>]]          // tramos con voz por persona
    var waves: [[Float]]                        // dB cada 100 ms por persona (forma de onda), vacío si no hay análisis
    var audible: [Bool]
    var cuts: [ClosedRange<Double>]
    var moments: [Double]
    var reels: [ClosedRange<Double>]
    var sponsors: [ClosedRange<Double>]
    var effects: [ClosedRange<Double>]
    var overlays: [ClosedRange<Double>]
    var brolls: [ClosedRange<Double>]
    var selectedOverlay: ClosedRange<Double>?

    init(project p: Project, energy: EnergyMap?, selectedOverlay: Int? = nil, selectedBRoll: Int? = nil) {
        overlays = p.overlays.map { $0.start...$0.end }
        brolls = p.brolls.map { $0.start...$0.end }
        self.selectedOverlay = p.overlays.first { $0.id == selectedOverlay }.map { $0.start...$0.end }
            ?? p.brolls.first { $0.id == selectedBRoll }.map { $0.start...$0.end }
        duration = p.duration
        cuts = p.cuts.filter(\.enabled).map { $0.start...max($0.start, $0.end) }
        moments = p.moments.map(\.time)
        reels = p.reels.map { $0.start...max($0.start, $0.end) }
        sponsors = (p.showSponsors ? p.sponsorAppearances().map { $0.start...max($0.start, $0.end) } : [])
            + (p.showCintillos ? p.cintillos.map { $0.start...($0.start + $0.duration) } : [])
        effects = p.audioLane.map { $0.tlStart...($0.loop ? max($0.tlStart + 0.3, p.duration) : min(p.duration, $0.tlStart + max(0.3, $0.srcOut - $0.srcIn))) }
        waves = p.lanes.map { energy?.lanes[$0.id] ?? [] }
        audible = p.lanes.map { p.laneAudible($0) }
        lanes = p.lanes.map { lane in
            if let arr = energy?.lanes[lane.id], !arr.isEmpty {
                return Self.runs(arr.enumerated().filter { $0.element > -38 }.map { Double($0.offset) * EnergyMap.hop },
                                 step: EnergyMap.hop, gap: 0.6)
            }
            let words = p.words.filter { $0.lane == lane.id }
            if !words.isEmpty {
                return Self.merge(words.map { $0.s...max($0.s, $0.e) }, gap: 0.8)
            }
            return lane.placed.map { $0.tlStart...$0.tlEnd }
        }
    }

    private static func runs(_ times: [Double], step: Double, gap: Double) -> [ClosedRange<Double>] {
        merge(times.map { $0...($0 + step) }, gap: gap)
    }

    private static func merge(_ spans: [ClosedRange<Double>], gap: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for s in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, s.lowerBound <= last.upperBound + gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, s.upperBound)
            } else { out.append(s) }
        }
        return out
    }
}

private struct TimelineCanvas: View, Equatable {
    let model: TimelineModel
    let pps: CGFloat
    let rulerH, marksH, laneH, fxH, ovH: CGFloat

    var body: some View {
        Canvas { ctx, size in
            func x(_ t: Double) -> CGFloat { CGFloat(t) * pps }
            func band(_ r: ClosedRange<Double>, y: CGFloat, h: CGFloat, _ c: Color, radius: CGFloat = 2) {
                let w = max(1, x(r.upperBound) - x(r.lowerBound))
                ctx.fill(Path(roundedRect: CGRect(x: x(r.lowerBound), y: y, width: w, height: h), cornerRadius: radius), with: .color(c))
            }

            // Regla
            let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600]
            let stepT = steps.first { CGFloat($0) * pps >= 70 } ?? 600
            var t = 0.0
            while t <= model.duration {
                ctx.fill(Path(CGRect(x: x(t), y: rulerH - 5, width: 1, height: 5)), with: .color(.white.opacity(0.35)))
                ctx.draw(Text(EditEngine.clock(t)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: x(t) + 3, y: 1), anchor: .topLeading)
                t += stepT
            }

            // Momentos, reels y sponsors
            let my = rulerH
            for r in model.reels { band(r, y: my + 3, h: marksH - 6, Theme.accent.opacity(0.28)) }
            for r in model.sponsors { band(r, y: my + 3, h: marksH - 6, Color.purple.opacity(0.8)) }
            for m in model.moments {
                var flag = Path()
                flag.move(to: CGPoint(x: x(m), y: my + 1)); flag.addLine(to: CGPoint(x: x(m) + 7, y: my + 5))
                flag.addLine(to: CGPoint(x: x(m), y: my + 9)); flag.closeSubpath()
                ctx.fill(flag, with: .color(Theme.accent))
                ctx.fill(Path(CGRect(x: x(m), y: my, width: 1.2, height: size.height - my)), with: .color(Theme.accent.opacity(0.6)))
            }

            // Personas: forma de onda (del análisis, dB cada 100 ms) o, si no hay, los tramos con voz
            for (i, spans) in model.lanes.enumerated() {
                let y = rulerH + marksH + CGFloat(i) * laneH
                ctx.fill(Path(CGRect(x: 0, y: y + 3, width: size.width, height: laneH - 6)), with: .color(.white.opacity(0.04)))
                let base = EpisodeTimeline.palette[i % EpisodeTimeline.palette.count]
                let c = model.audible[i] ? base : Color.white.opacity(0.25)
                let wave = model.waves[i]
                if wave.isEmpty {
                    for s in spans { band(s, y: y + 4, h: laneH - 8, c.opacity(0.85)) }
                } else {
                    let mid = y + laneH / 2, half = (laneH - 8) / 2
                    let colW: CGFloat = 2
                    var path = Path()
                    var px: CGFloat = 0
                    let hopPx = CGFloat(EnergyMap.hop) * pps
                    while px < size.width {
                        let i0 = Int(px / hopPx), i1 = max(i0, Int((px + colW) / hopPx))
                        guard i0 < wave.count else { break }
                        var peak: Float = -120
                        for k in i0...min(i1, wave.count - 1) { peak = max(peak, wave[k]) }
                        let a = CGFloat(min(1, max(0, (peak + 60) / 60)))     // −60 dB → 0, 0 dB → 1
                        let h = max(1, a * a * half * 2)                      // curva: lo bajo se ve bajo
                        path.addRect(CGRect(x: px, y: mid - h / 2, width: colW, height: h))
                        px += colW
                    }
                    ctx.fill(path, with: .color(c.opacity(0.9)))
                }
            }

            // Efectos
            let fy = rulerH + marksH + CGFloat(model.lanes.count) * laneH
            for e in model.effects { band(e, y: fy + 3, h: fxH - 5, .white.opacity(0.8), radius: 3) }

            // Textos, imágenes y stickers
            let oy = fy + fxH
            for b in model.brolls { band(b, y: oy + 2, h: ovH - 4, Color.cyan.opacity(0.7), radius: 3) }
            for o in model.overlays { band(o, y: oy + 2, h: ovH - 4, Color.yellow.opacity(0.75), radius: 3) }
            if let s = model.selectedOverlay {
                let r = CGRect(x: x(s.lowerBound), y: oy + 1, width: max(2, x(s.upperBound) - x(s.lowerBound)), height: ovH - 2)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
            }

            // Lo que se corta, encima de todo
            let top = rulerH + marksH
            for c in model.cuts { band(c, y: top, h: size.height - top, Color.red.opacity(0.38), radius: 0) }
        }
    }
}

/// Solo la línea de reproducción se redibuja mientras suena el video.
private struct PlayheadLayer: View {
    @ObservedObject var session: ProjectSession
    let pps: CGFloat
    let height: CGFloat

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let x = CGFloat(session.playheadTimeline) * pps
            Rectangle().fill(Color.white).frame(width: 1.5, height: height)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }
}


/// Botón chico S / M de cada persona en el timeline.
struct LaneToggle: View {
    let letter: String
    let on: Bool
    let onColor: Color
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(letter).font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? onColor : Color.white.opacity(0.08)))
                .foregroundStyle(on ? .black : Theme.secondary)
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Medidor de nivel de una persona: lo que suena ahora (del análisis, con el volumen de la pista aplicado).
struct LaneMeter: View {
    @ObservedObject var session: ProjectSession
    let laneId: Int
    let color: Color
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let level = session.laneLevel(laneId)       // 0…1
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [color, color, Theme.accent, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, g.size.width * level))
                }
            }
            .frame(height: 5)
        }
    }
}
