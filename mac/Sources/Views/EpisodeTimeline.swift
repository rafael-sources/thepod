import SwiftUI

/// Episode timeline (like postPod web's, to view and navigate):
/// one row per person with when they speak, what's cut, moments/reels, sponsors and effects.
/// Click or drag to move the video; zoom to see detail.
struct EpisodeTimeline: View {
    @ObservedObject var session: ProjectSession
    @State private var zoom: Double = 1
    @State private var collapsed = false
    @State private var selection: (start: Double, end: Double)?   // span marked with the mouse (episode time)
    @State private var dragAnchor: Double?

    static let palette: [Color] = [
        Color(red: 0.353, green: 0.545, blue: 1.0),    // prePod blue
        Color(red: 0.078, green: 0.722, blue: 0.651),  // amaPod teal
        Color(red: 1.0, green: 0.42, blue: 0.42),
        Color(red: 0.72, green: 0.55, blue: 1.0),
        Color(red: 0.45, green: 0.85, blue: 0.5),
        Color(red: 1.0, green: 0.62, blue: 0.3),
    ]

    private let labelWidth: CGFloat = 132
    @State private var dragPoint: (lane: Int, id: UUID)?
    @State private var lastClick: (at: Date, x: CGFloat, y: CGFloat)?
    @State private var selectionLane: Int?          // person where the drag started (for «solo a esta persona»)
    @State private var dragDB: Double?
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
                    Text(p.normalizeLoudness ? String(localized: "Volumen final: −16 LUFS el audio · −14 el video") : String(localized: "Volumen final: sin ajuste"))
                        .font(.caption2).foregroundStyle(p.normalizeLoudness ? Theme.secondary : .orange)
                        .help("Lo que piden Spotify y YouTube. Se mide y se corrige al exportar; se apaga en Exportar.")
                    Spacer()
                    if let sel = selection, sel.end - sel.start > 0.05 {
                        HStack(spacing: 8) {
                            Text("\(EditEngine.clock(sel.start)) – \(EditEngine.clock(sel.end)) · \(String(format: "%.1f s", sel.end - sel.start))")
                                .font(.caption).monospacedDigit()
                            Button { session.seek(timeline: sel.start, play: true) } label: { Label("Oír", systemImage: "play.fill") }
                                .controlSize(.small)
                            if let laneId = selectionLane {
                                Button { session.shapeVolume(laneId: laneId, from: sel.start, to: sel.end, db: VolumePoint.minDB); selection = nil } label: {
                                    Label("Silenciar solo a \(p.laneName(laneId))", systemImage: "speaker.slash")
                                }
                                .controlSize(.small)
                                Button { session.shapeVolume(laneId: laneId, from: sel.start, to: sel.end, db: -6); selection = nil } label: {
                                    Label("−6 dB a \(p.laneName(laneId))", systemImage: "speaker.minus")
                                }
                                .controlSize(.small)
                            }
                            Button(role: .destructive) { session.cutRange(sel.start, sel.end); selection = nil } label: { Label("Cortar de todos", systemImage: "scissors") }
                                .controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
                            Button { selection = nil } label: { Image(systemName: "xmark") }.controlSize(.small)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelStrong))
                    } else {
                        Text(dragDB.map { String(format: String(localized: "Volumen %+.0f dB"), $0) } ?? String(localized: "Clic: ir ahí · arrastra: marcar un trozo · doble clic en una persona: punto de volumen")).font(.caption2).foregroundStyle(Theme.secondary)
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
                                    LaneToggle(letter: "S", on: lane.solo, onColor: Theme.accent, help: String(localized: "Solo: se oye solo esta persona")) {
                                        session.toggleSolo(lane.id)
                                    }
                                    LaneToggle(letter: "M", on: lane.muted, onColor: .red, help: String(localized: "Mudo: esta persona no suena")) {
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
                            Text(p.brolls.isEmpty ? String(localized: "Textos") : String(localized: "Textos · b-roll")).font(.caption2).foregroundStyle(Theme.secondary)
                                .frame(width: labelWidth - 8, height: ovH, alignment: .leading)
                        }
                    }
                    .frame(width: labelWidth)
                    GeometryReader { geo in
                        let width = max(geo.size.width, geo.size.width * zoom)
                        let pps = width / p.duration
                        ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                            ZStack(alignment: .topLeading) {
                                TimelineCanvas(model: TimelineModel(project: p, energy: session.energy, selectedOverlay: selectedOverlay, selectedBRoll: selectedBRoll, selectedPoint: session.selectedVolumePoint?.id), pps: pps,
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
                                    if dragAnchor == nil && dragPoint == nil {
                                        // Did it start on a volume line point? Then the point is moved
                                        if let hit = hitPoint(p, at: g.startLocation, pps: pps) {
                                            dragPoint = hit
                                            session.selectedVolumePoint = hit
                                        } else {
                                            dragAnchor = min(max(0, Double(g.startLocation.x / pps)), p.duration)
                                            selectionLane = laneAt(p, y: g.startLocation.y)
                                        }
                                    }
                                    if let dp = dragPoint {
                                        let db = dbAt(p, y: g.location.y, laneId: dp.lane)
                                        dragDB = db
                                        session.moveVolumePoint(laneId: dp.lane, id: dp.id, t: t, db: db)
                                        return
                                    }
                                    let a = dragAnchor ?? t
                                    if abs(g.translation.width) > 4 {
                                        selection = (min(a, t), max(a, t))
                                    }
                                }
                                .onEnded { g in
                                    let t = min(max(0, Double(g.location.x / pps)), p.duration)
                                    if dragPoint != nil { dragPoint = nil; dragDB = nil; dragAnchor = nil; return }
                                    if abs(g.translation.width) <= 4 {
                                        selection = nil
                                        // Double-click on a person: adds a volume point there, AT THE SAME volume it already had.
                                        // It used to take the click height: a double-click near the bottom edge (when placing
                                        // a stinger, when looking for an instant) left that person almost muted from there on.
                                        // Now the point changes nothing until it's dragged up or down.
                                        if let lc = lastClick, Date().timeIntervalSince(lc.at) < 0.4, abs(lc.x - g.location.x) < 6, abs(lc.y - g.location.y) < 6,
                                           let laneId = laneAt(p, y: g.location.y),
                                           let lane = p.lanes.first(where: { $0.id == laneId }) {
                                            _ = session.addVolumePoint(laneId: laneId, t: t, db: lane.automationDB(at: t))
                                            lastClick = nil; dragAnchor = nil
                                            return
                                        }
                                        lastClick = (Date(), g.location.x, g.location.y)
                                        session.selectedVolumePoint = nil
                                        // Click on the texts row: select that layer to edit it
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
            legendItem(Color.red.opacity(0.55), String(localized: "Se corta"))
            legendItem(Theme.accent, String(localized: "Reel"))
            legendItem(Color.purple.opacity(0.8), String(localized: "Sponsor"))
            legendItem(Color.white.opacity(0.8), String(localized: "Efecto"))
            legendItem(Color.yellow.opacity(0.75), String(localized: "Texto"))
            HStack(spacing: 4) { Rectangle().fill(Theme.accent).frame(width: 10, height: 1.5); Text("Volumen") }.fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(Theme.secondary)
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 8); Text(t) }.fixedSize()
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

    /// Person (id) in the row where `y` is, or nil if it isn't a person row.
    private func laneAt(_ p: Project, y: CGFloat) -> Int? {
        let top = rulerH + marksH
        guard y >= top else { return nil }
        let i = Int((y - top) / laneH)
        return i >= 0 && i < p.lanes.count ? p.lanes[i].id : nil
    }
    private func laneTop(_ p: Project, laneId: Int) -> CGFloat {
        let i = p.lanes.firstIndex { $0.id == laneId } ?? 0
        return rulerH + marksH + CGFloat(i) * laneH
    }
    /// dB corresponding to height `y` within that person's row.
    private func dbAt(_ p: Project, y: CGFloat, laneId: Int) -> Double {
        let top = laneTop(p, laneId: laneId)
        let u = Double(1 - min(1, max(0, (y - top - 4) / (laneH - 8))))
        let db = VolumePoint.minDB + u * (VolumePoint.maxDB - VolumePoint.minDB)
        return (db / 1).rounded()      // in 1 dB steps
    }
    private func hitPoint(_ p: Project, at loc: CGPoint, pps: CGFloat) -> (lane: Int, id: UUID)? {
        guard let laneId = laneAt(p, y: loc.y), let lane = p.lanes.first(where: { $0.id == laneId }) else { return nil }
        let top = laneTop(p, laneId: laneId)
        for pt in lane.volumePoints {
            let px = CGFloat(pt.t) * pps
            let py = top + laneH - 4 - CGFloat((pt.db - VolumePoint.minDB) / (VolumePoint.maxDB - VolumePoint.minDB)) * (laneH - 8)
            if abs(px - loc.x) <= 7 && abs(py - loc.y) <= 7 { return (laneId, pt.id) }
        }
        return nil
    }

    private func seek(to t: Double, duration: Double) {
        var t = min(max(0, t), duration)
        if let w = session.previewWindow { t = min(max(t, w.start), w.end) }   // viewing a reel: within the reel
        session.seek(timeline: t, play: false)
    }
}

/// Precomputed drawing data (doesn't change while playing).
struct TimelineModel: Equatable {
    var duration: Double
    var lanes: [[ClosedRange<Double>]]          // voiced spans per person
    var waves: [[Float]]                        // dB every 100 ms per person (waveform), empty if there's no analysis
    var audible: [Bool]
    var automation: [[VolumePoint]]             // volume line per person
    var selectedPoint: UUID?
    var cuts: [ClosedRange<Double>]
    var moments: [Double]
    struct ReviewMark: Equatable { let t: Double; let resolved: Bool }
    var reviewMarks: [ReviewMark] = []
    var reels: [ClosedRange<Double>]
    var sponsors: [ClosedRange<Double>]
    var effects: [ClosedRange<Double>]
    var overlays: [ClosedRange<Double>]
    var brolls: [ClosedRange<Double>]
    var selectedOverlay: ClosedRange<Double>?

    init(project p: Project, energy: EnergyMap?, selectedOverlay: Int? = nil, selectedBRoll: Int? = nil, selectedPoint: UUID? = nil) {
        automation = p.lanes.map { $0.volumePoints.sorted { $0.t < $1.t } }
        self.selectedPoint = selectedPoint
        overlays = p.overlays.map { $0.start...$0.end }
        brolls = p.brolls.map { $0.start...$0.end }
        self.selectedOverlay = p.overlays.first { $0.id == selectedOverlay }.map { $0.start...$0.end }
            ?? p.brolls.first { $0.id == selectedBRoll }.map { $0.start...$0.end }
        duration = p.duration
        cuts = p.cuts.filter(\.enabled).map { $0.start...max($0.start, $0.end) }
        moments = p.moments.map(\.time)
        reviewMarks = (p.review?.comments ?? []).map { ReviewMark(t: p.review!.timelineTime($0), resolved: $0.resolved) }
        reels = p.reels.map { $0.start...max($0.start, $0.end) }
        sponsors = (p.showSponsors ? p.sponsorAppearances().map { $0.start...max($0.start, $0.end) } : [])
            + (p.showCintillos ? p.cintillos.map { $0.start...($0.start + $0.duration) } : [])
        effects = p.audioLane.map { $0.tlStart...($0.loop ? max($0.tlStart + 0.3, p.duration) : min(p.duration, $0.tlStart + max(0.3, $0.length))) }
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

            // Ruler
            let steps: [Double] = [5, 10, 15, 30, 60, 120, 300, 600]
            let stepT = steps.first { CGFloat($0) * pps >= 70 } ?? 600
            var t = 0.0
            while t <= model.duration {
                ctx.fill(Path(CGRect(x: x(t), y: rulerH - 5, width: 1, height: 5)), with: .color(.white.opacity(0.35)))
                ctx.draw(Text(EditEngine.clock(t)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.55)),
                         at: CGPoint(x: x(t) + 3, y: 1), anchor: .topLeading)
                t += stepT
            }

            // Moments, reels and sponsors
            let my = rulerH
            for r in model.reels { band(r, y: my + 3, h: marksH - 6, Theme.accent.opacity(0.28)) }
            for r in model.sponsors { band(r, y: my + 3, h: marksH - 6, Color.purple.opacity(0.8)) }
            // Shared review comments: an orange bubble (gray if resolved)
            for rm in model.reviewMarks {
                let col = rm.resolved ? Color.gray.opacity(0.6) : Color.orange
                ctx.fill(Path(ellipseIn: CGRect(x: x(rm.t) - 4, y: my + 1, width: 8, height: 8)), with: .color(col))
                ctx.fill(Path(CGRect(x: x(rm.t), y: my, width: 1, height: size.height - my)), with: .color(col.opacity(0.5)))
            }
            for m in model.moments {
                var flag = Path()
                flag.move(to: CGPoint(x: x(m), y: my + 1)); flag.addLine(to: CGPoint(x: x(m) + 7, y: my + 5))
                flag.addLine(to: CGPoint(x: x(m), y: my + 9)); flag.closeSubpath()
                ctx.fill(flag, with: .color(Theme.accent))
                ctx.fill(Path(CGRect(x: x(m), y: my, width: 1.2, height: size.height - my)), with: .color(Theme.accent.opacity(0.6)))
            }

            // People: waveform (from the analysis, dB every 100 ms) or, if none, the voiced spans
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
                        let h = max(1, a * a * half * 2)                      // curve: quiet looks quiet
                        path.addRect(CGRect(x: px, y: mid - h / 2, width: colW, height: h))
                        px += colW
                    }
                    ctx.fill(path, with: .color(c.opacity(0.9)))
                }
                // Volume line (yellow) with its points
                let pts = model.automation[i]
                if !pts.isEmpty {
                    func py(_ db: Double) -> CGFloat { y + laneH - 4 - CGFloat((db - VolumePoint.minDB) / (VolumePoint.maxDB - VolumePoint.minDB)) * (laneH - 8) }
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: py(pts[0].db)))
                    for pt in pts { line.addLine(to: CGPoint(x: x(pt.t), y: py(pt.db))) }
                    line.addLine(to: CGPoint(x: size.width, y: py(pts[pts.count - 1].db)))
                    ctx.stroke(line, with: .color(Theme.accent.opacity(0.95)), lineWidth: 1.5)
                    for pt in pts {
                        let r: CGFloat = pt.id == model.selectedPoint ? 5 : 3.5
                        let rect = CGRect(x: x(pt.t) - r, y: py(pt.db) - r, width: 2 * r, height: 2 * r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(pt.id == model.selectedPoint ? .white : Theme.accent))
                        ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1)
                    }
                }
            }

            // Effects
            let fy = rulerH + marksH + CGFloat(model.lanes.count) * laneH
            for e in model.effects { band(e, y: fy + 3, h: fxH - 5, .white.opacity(0.8), radius: 3) }

            // Texts, images and stickers
            let oy = fy + fxH
            for b in model.brolls { band(b, y: oy + 2, h: ovH - 4, Color.cyan.opacity(0.7), radius: 3) }
            for o in model.overlays { band(o, y: oy + 2, h: ovH - 4, Color.yellow.opacity(0.75), radius: 3) }
            if let s = model.selectedOverlay {
                let r = CGRect(x: x(s.lowerBound), y: oy + 1, width: max(2, x(s.upperBound) - x(s.lowerBound)), height: ovH - 2)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
            }

            // What's cut, on top of everything
            let top = rulerH + marksH
            for c in model.cuts { band(c, y: top, h: size.height - top, Color.red.opacity(0.38), radius: 0) }
        }
    }
}

/// Only the playhead is redrawn while the video plays.
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


/// Small S / M button for each person in the timeline.
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

/// A person's level meter: what actually sounds while playing; when paused, an estimate.
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
