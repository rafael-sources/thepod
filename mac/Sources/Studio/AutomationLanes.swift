import SwiftUI

/// Carriles de automatización del estudio: una tira por parámetro automatizado de cada persona, sobre todo
/// el episodio. Arrastrar mueve el punto (tiempo y valor); doble clic lo borra; clic en el fondo va a ese segundo.
struct AutomationLanes: View {
    @ObservedObject var session: ProjectSession

    private var rows: [(laneIndex: Int, lane: Lane, param: String, points: [AutoPoint])] {
        var out: [(Int, Lane, String, [AutoPoint])] = []
        for (i, lane) in session.project.lanes.enumerated() {
            let c = lane.effectiveChain
            for (param, pts) in c.automation.sorted(by: { $0.key < $1.key }) where !pts.isEmpty {
                out.append((i, lane, param, pts.sorted { $0.t < $1.t }))
            }
        }
        return out
    }

    var body: some View {
        let rows = rows
        if rows.isEmpty {
            Text("Sin automatización todavía. En un insert, enciende «Escribir» y mueve un control mientras suena, o usa el botón Ⓐ de un parámetro.")
                .font(.caption).foregroundStyle(Theme.secondary).padding(.horizontal, 12).padding(.vertical, 6)
        } else {
            VStack(spacing: 4) {
                ForEach(rows, id: \.param) { r in
                    AutomationStrip(session: session, laneIndex: r.laneIndex, param: r.param,
                                    color: EpisodeTimeline.palette[r.laneIndex % EpisodeTimeline.palette.count])
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

struct AutomationStrip: View {
    @ObservedObject var session: ProjectSession
    let laneIndex: Int
    let param: String
    let color: Color
    @State private var dragging: UUID?
    private let labelW: CGFloat = 132
    private let h: CGFloat = 44

    private var lane: Lane { session.project.lanes[laneIndex] }
    private var chain: ChainSettings { lane.effectiveChain }
    private var points: [AutoPoint] { (chain.automation[param] ?? []).sorted { $0.t < $1.t } }
    private var duration: Double { max(1, session.project.duration) }

    /// Rango del parámetro, para dibujar y para limitar el arrastre.
    private var range: ClosedRange<Double> {
        switch param {
        case ChainSettings.compThreshold: return -60...0
        case ChainSettings.compRatio: return 1...20
        case ChainSettings.compMakeup: return 0...18
        case ChainSettings.deesserAmount: return 0...1
        case ChainSettings.gateThreshold: return -80...(-20)
        default: return param.hasSuffix(".freq") ? 20...20_000 : -18...18
        }
    }
    private var label: String {
        switch param {
        case ChainSettings.compThreshold: return "Compresor · umbral"
        case ChainSettings.compRatio: return "Compresor · relación"
        case ChainSettings.compMakeup: return "Compresor · compensación"
        case ChainSettings.deesserAmount: return "De-esser · cantidad"
        case ChainSettings.gateThreshold: return "Puerta · umbral"
        default:
            let parts = param.split(separator: ".")
            if parts.count == 3, let id = UUID(uuidString: String(parts[1])), let i = chain.bands.firstIndex(where: { $0.id == id }) {
                return "EQ · banda \(i + 1) · \(parts[2] == "gain" ? "ganancia" : "frecuencia")"
            }
            return param
        }
    }
    private func fmt(_ v: Double) -> String {
        switch param {
        case ChainSettings.compRatio: return String(format: "%.1f:1", v)
        case ChainSettings.deesserAmount: return String(format: "%.2f", v)
        default: return param.hasSuffix(".freq") ? String(format: "%.0f Hz", v) : String(format: "%+.1f dB", v)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(session.project.laneName(lane.id)).font(.caption.bold()).lineLimit(1) }
                Text(label).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                Text("\(points.count) puntos").font(.caption2).foregroundStyle(Theme.secondary)
            }
            .frame(width: labelW, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3))
                    Path { p in
                        guard let f = points.first else { return }
                        p.move(to: CGPoint(x: 0, y: y(f.v)))
                        for pt in points { p.addLine(to: CGPoint(x: x(pt.t, w), y: y(pt.v))) }
                        p.addLine(to: CGPoint(x: w, y: y(points.last!.v)))
                    }
                    .stroke(Theme.accent, lineWidth: 1.5)
                    ForEach(points) { pt in
                        Circle().fill(dragging == pt.id ? Color.white : Theme.accent).frame(width: 9, height: 9)
                            .position(x: x(pt.t, w), y: y(pt.v))
                            .help("\(EditEngine.clock(pt.t)) · \(fmt(pt.v)) — arrastra para mover, doble clic para quitar")
                            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                                dragging = pt.id
                                let t = max(0, min(duration, Double(v.location.x / w) * duration))
                                let val = value(forY: v.location.y)
                                update { pts in if let i = pts.firstIndex(where: { $0.id == pt.id }) { pts[i].t = t; pts[i].v = val } }
                            }.onEnded { _ in dragging = nil })
                            .onTapGesture(count: 2) { update { pts in pts.removeAll { $0.id == pt.id } } }
                    }
                    // cabeza de reproducción
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1)
                            .offset(x: x(session.playheadTimeline, w))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { loc in session.seek(timeline: Double(loc.x / w) * duration, play: false) }
            }
            .frame(height: h)
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / duration) * w }
    private func y(_ v: Double) -> CGFloat {
        let r = range
        let f = (v - r.lowerBound) / (r.upperBound - r.lowerBound)
        return h - 5 - CGFloat(max(0, min(1, f))) * (h - 10)
    }
    private func value(forY py: CGFloat) -> Double {
        let r = range
        let f = Double((h - 5 - py) / (h - 10))
        return r.lowerBound + max(0, min(1, f)) * (r.upperBound - r.lowerBound)
    }
    private func update(_ f: (inout [AutoPoint]) -> Void) {
        var c = chain
        var pts = c.automation[param] ?? []
        f(&pts)
        c.automation[param] = pts.isEmpty ? nil : pts.sorted { $0.t < $1.t }
        Lane.store(c, in: &session.project.lanes[laneIndex])
    }
}
