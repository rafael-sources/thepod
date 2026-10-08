import Foundation
import SwiftUI

// Teleprompter en la sala (0.11.0). Mismo contrato que la web:
// {"type":"teleprompter","action":"show"|"hide","target":"all"|identity,"title","text",
//  "speed":"slow|normal|fast","size":"quarter|half|full","countdown":3,"event_id"}
// Todos ven el aviso ("Viene X en 3 s · ATENTO PATRICIO"); el texto solo le aparece a quien le toca.
// Quien lee avisa cuando el texto terminó de correr (pausas incluidas) o lo cerró:
// {"type":"teleprompter_done","event_id"}. Quien creó la sala suelta ahí el siguiente encadenado.

struct TPNotice: Equatable {
    var title: String
    var who: String          // nombre en mayúsculas, vacío si es para todos
    var remaining: Int
}

struct TPActive: Equatable {
    var id: String
    var title: String
    var text: String
    var speed: String        // slow | normal | fast
    var size: String         // quarter | half | full
    var paused = false
    var startedAt = Date()
    var pausedAt: Date?
    var pausedAccum: TimeInterval = 0
    var duration: TimeInterval

    static let wpm: [String: Double] = ["slow": 95, "normal": 135, "fast": 180]

    static func duration(text: String, speed: String) -> TimeInterval {
        let words = max(8, text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
        return Double(words) / (wpm[speed] ?? 135) * 60 + 2.5
    }

    /// 0…1: cuánto del texto ya corrió.
    func progress(at now: Date) -> Double {
        let end = pausedAt ?? now
        let e = end.timeIntervalSince(startedAt) - pausedAccum
        return min(1, max(0, e / duration))
    }
}

/// Sección del guion de prePod marcada para teleprompter.
struct TPSection {
    let id: Int
    let speaker: String          // etiqueta para mostrar
    let speakerKey: String       // usuario del conductor o nombre del invitado (para elegir a quién va)
    let content: String
    let offset: Double
    let speed: String
    let size: String
    var afterPrev = false        // «después del anterior»: sale cuando el anterior termina de verdad
    var gap = 0.5
    var run: Double = 0          // lo que dura corriendo (calculado), para el plan B
}

extension ProdStudio {

    // MARK: Recibir

    func handleTeleprompter(_ m: [String: Any]) {
        let action = m["action"] as? String ?? "show"
        if action == "hide" {
            let eid = m["event_id"] as? String
            if eid == nil || tpActive?.id == eid { tpActive = nil }
            tpNotice = nil
            tpNoticeTask?.cancel(); tpShowTask?.cancel()
            return
        }
        let target = m["target"] as? String ?? "all"
        let mine = target == "all" || target == myIdentity
        let secs = max(0, (m["countdown"] as? Int) ?? Int((m["countdown"] as? Double) ?? 0))
        tpNoticeTask?.cancel(); tpShowTask?.cancel()
        if secs > 0 {
            let who = target == "all" ? "" : (people.first { $0.id == target }?.name ?? tpPeople[target] ?? "").uppercased()
            tpNotice = TPNotice(title: m["title"] as? String ?? "Teleprompter", who: who, remaining: secs)
            let endsAt = Date().addingTimeInterval(Double(secs))
            tpNoticeTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, !Task.isCancelled else { return }
                    let r = Int(ceil(endsAt.timeIntervalSinceNow))
                    if r <= 0 { self.tpNotice = nil; return }
                    self.tpNotice?.remaining = r
                }
            }
            if mine {
                tpShowTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.tpShow(m)
                }
            }
        } else if mine {
            tpShow(m)
        }
    }

    private func tpShow(_ m: [String: Any]) {
        tpHideTask?.cancel(); tpDoneTask?.cancel()
        let text = m["text"] as? String ?? ""
        let speed = m["speed"] as? String ?? "normal"
        let id = (m["event_id"] as? String) ?? (m["event_id"] as? Int).map(String.init) ?? UUID().uuidString
        tpActive = TPActive(id: id, title: m["title"] as? String ?? "", text: text, speed: speed,
                            size: m["size"] as? String ?? "half",
                            duration: TPActive.duration(text: text, speed: speed))
        // Se va solo cuando termina de correr (más 4 s), salvo que lo cierren antes.
        let d = tpActive!.duration + 4
        tpHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            guard !Task.isCancelled, let self, self.tpActive?.id == id, self.tpActive?.paused == false else { return }
            self.tpActive = nil
        }
        // Avisa cuando el texto terminó de correr (la pausa y «desde el inicio» lo corren).
        tpDoneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled, let a = self.tpActive, a.id == id else { return }
                if a.progress(at: Date()) >= 1 { self.tpReportDone(id); return }
            }
        }
    }

    private func tpReportDone(_ id: String) {
        guard !tpReported.contains(id) else { return }
        tpReported.insert(id)
        send(["type": "teleprompter_done", "event_id": id])
        tpDoneReceived(id)          // por si quien lee es quien creó la sala
    }

    /// Alguien terminó de leer un teleprompter del guion: suelta el encadenado que venga.
    func tpDoneReceived(_ eid: String?) {
        guard let eid, eid.hasPrefix("s"), let n = Int(eid.dropFirst()) else { return }
        tpDone.insert(n)
        if recording { tickTeleprompter(Date().timeIntervalSince(recordStart)) }
    }

    func tpPause() {
        guard var a = tpActive else { return }
        if a.paused {
            if let p = a.pausedAt { a.pausedAccum += Date().timeIntervalSince(p) }
            a.pausedAt = nil; a.paused = false
        } else {
            a.pausedAt = Date(); a.paused = true
        }
        tpActive = a
    }

    func tpRestart() {
        guard var a = tpActive else { return }
        a.startedAt = Date(); a.pausedAt = nil; a.pausedAccum = 0; a.paused = false
        tpActive = a
    }

    func tpClose() {
        if let a = tpActive { tpReportDone(a.id) }
        tpActive = nil
        tpHideTask?.cancel(); tpDoneTask?.cancel()
    }

    // MARK: Guion (solo quien creó la sala dispara los del guion)

    func loadTeleprompterScript() async {
        tpScript = []; tpFired = [:]; tpDone = []; tpPeople = [:]
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(session.id)/teleprompter"),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        for p in j["participants"] as? [[String: Any]] ?? [] {
            if let id = p["identity"] as? String {
                tpPeople[id] = p["display_name"] as? String ?? ""
                if let u = p["username"] as? String { tpUsernames[id] = u }
            }
        }
        tpScript = (j["sections"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["id"] as? Int,
                  let off = (s["offset_seconds"] as? Double) ?? (s["offset_seconds"] as? Int).map(Double.init) else { return nil }
            let label = s["speaker"] as? String ?? ""
            func num(_ k: String) -> Double? { (s[k] as? Double) ?? (s[k] as? Int).map(Double.init) }
            var sec = TPSection(id: id, speaker: label, speakerKey: (s["speaker_key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label,
                                content: s["content"] as? String ?? "",
                                offset: off, speed: s["speed"] as? String ?? "normal", size: s["size"] as? String ?? "half")
            sec.afterPrev = s["after_prev"] as? Bool ?? false
            sec.gap = num("gap_seconds") ?? 0.5
            sec.run = max(0, (num("ends_seconds") ?? off) - off)
            return sec
        }
        if !tpScript.isEmpty { flash("\(tpScript.count) teleprompter del guion listos") }
    }

    /// Igual que la web: primero usuario o nombre exacto (lo que eligió prePod en «lo lee»), luego parecido por nombre.
    func tpIdentity(for speaker: String) -> String {
        let sp = speaker.trimmingCharacters(in: .whitespaces).lowercased()
        guard !sp.isEmpty else { return "all" }
        for (id, name) in tpPeople where name.lowercased() == sp || (tpUsernames[id] ?? "").lowercased() == sp { return id }
        for (id, name) in tpPeople {
            let n = name.lowercased()
            guard !n.isEmpty else { continue }
            if n.hasPrefix(sp) || sp.hasPrefix(n) || n.split(separator: " ").first == sp.split(separator: " ").first { return id }
        }
        return "all"
    }

    /// Llamado cada décima mientras se graba, con el segundo actual de la grabación.
    func tickTeleprompter(_ t: Double) {
        guard isOwner, !tpScript.isEmpty else { return }
        for (i, s) in tpScript.enumerated() where tpFired[s.id] == nil {
            var countdown = 3
            if s.afterPrev, i > 0, let prevAt = tpFired[tpScript[i - 1].id] {
                // «Después del anterior»: sale cuando quien lo lee avisa que terminó.
                // Si nadie avisa (versión vieja, se cayó), sale 15 s después de lo calculado.
                let prev = tpScript[i - 1]
                guard tpDone.contains(prev.id) || t >= prevAt + 3 + prev.run + 15 else { continue }
                countdown = max(3, Int(s.gap.rounded()))
            } else {
                let at = s.offset - 3            // 3 s de aviso antes
                guard t >= at, t <= at + 2 else { continue }
            }
            tpFired[s.id] = t
            let msg: [String: Any] = ["type": "teleprompter", "action": "show", "event_id": "s\(s.id)",
                                      "target": tpIdentity(for: s.speakerKey), "title": "Guion · \(s.speaker)",
                                      "text": s.content, "speed": s.speed, "size": s.size, "countdown": countdown]
            send(msg)
            handleTeleprompter(msg)      // también para mí
        }
    }
}

// MARK: Capa visual (host e invitado)

struct TeleprompterLayer: View {
    @ObservedObject var studio: ProdStudio

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                if let n = studio.tpNotice {
                    HStack(spacing: 14) {
                        Text("\(n.remaining)")
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Viene **\(n.title)** en \(n.remaining) s").font(.title3.weight(.semibold))
                            if !n.who.isEmpty { Text("ATENTO \(n.who)").font(.headline.weight(.black)).tracking(1.5) }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.85, green: 0.35, blue: 0.1).opacity(0.95)))
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let a = studio.tpActive {
                    panel(a, height: g.size.height * (a.size == "quarter" ? 0.28 : a.size == "full" ? 0.92 : 0.5))
                        .frame(maxWidth: min(g.size.width - 40, 1100))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.25), value: studio.tpNotice)
        .animation(.easeOut(duration: 0.25), value: studio.tpActive?.id)
    }

    private func panel(_ a: TPActive, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(a.title.isEmpty ? "Teleprompter" : a.title, systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Button(a.paused ? "Seguir" : "Pausa", systemImage: a.paused ? "play.fill" : "pause.fill") { studio.tpPause() }
                Button("Desde el inicio", systemImage: "arrow.counterclockwise") { studio.tpRestart() }
                Button { studio.tpClose() } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.black.opacity(0.35))
            GeometryReader { g in
                TimelineView(.animation(minimumInterval: 1 / 30, paused: a.paused)) { ctx in
                    let fontSize: CGFloat = a.size == "quarter" ? 26 : a.size == "full" ? 40 : 32
                    ScrollingText(text: a.text, fontSize: fontSize, width: g.size.width - 48,
                                  viewHeight: g.size.height, progress: a.progress(at: ctx.date))
                }
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.86)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(a.paused ? 0.5 : 0.15), lineWidth: 1.5))
    }
}

/// El texto sube de abajo hacia arriba según el progreso (0: todavía fuera por abajo; 1: ya salió por arriba).
private struct ScrollingText: View {
    let text: String
    let fontSize: CGFloat
    let width: CGFloat
    let viewHeight: CGFloat
    let progress: Double

    @State private var textHeight: CGFloat = 0

    var body: some View {
        let travel = viewHeight + textHeight
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineSpacing(fontSize * 0.35)
            .multilineTextAlignment(.center)
            .frame(width: max(10, width))
            .background(GeometryReader { p in
                Color.clear.onAppear { textHeight = p.size.height }
                    .onChange(of: p.size.height) { _, h in textHeight = h }
            })
            .offset(y: viewHeight - CGFloat(progress) * travel)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
    }
}
