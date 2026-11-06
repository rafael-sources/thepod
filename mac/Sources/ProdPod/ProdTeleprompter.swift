import Foundation
import SwiftUI

// Teleprompter in the room (0.11.0). Same contract as the web:
// {"type":"teleprompter","action":"show"|"hide","target":"all"|identity,"title","text",
//  "speed":"slow|normal|fast","size":"quarter|half|full","countdown":3,"event_id"}
// Everyone sees the notice ("Viene X en 3 s · ATENTO ALEX"); the text only appears for whoever it's for.
// The reader notifies when the text has finished scrolling (pauses included) or was closed:
// {"type":"teleprompter_done","event_id"}. The room creator then releases the next chained one.

struct TPNotice: Equatable {
    var title: String
    var who: String          // name in uppercase, empty if it's for everyone
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

    /// 0…1: how much of the text has scrolled.
    func progress(at now: Date) -> Double {
        let end = pausedAt ?? now
        let e = end.timeIntervalSince(startedAt) - pausedAccum
        return min(1, max(0, e / duration))
    }
}

/// prePod script section marked for teleprompter.
struct TPSection {
    let id: Int
    let speaker: String          // label to display
    let speakerKey: String       // host username or guest name (to choose who it goes to)
    let content: String
    let offset: Double
    let speed: String
    let size: String
    var afterPrev = false        // «después del anterior»: goes out when the previous one has truly finished
    var gap = 0.5
    var run: Double = 0          // how long it takes to scroll (computed), for plan B
}

extension ProdStudio {

    // MARK: Receive

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
            tpNotice = TPNotice(title: m["title"] as? String ?? String(localized: "Teleprompter"), who: who, remaining: secs)
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
        // It goes away by itself when it finishes scrolling (plus 4 s), unless closed earlier.
        let d = tpActive!.duration + 4
        tpHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            guard !Task.isCancelled, let self, self.tpActive?.id == id, self.tpActive?.paused == false else { return }
            self.tpActive = nil
        }
        // Notifies when the text finished scrolling (pause and «desde el inicio» shift it).
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
        tpDoneReceived(id)          // in case the reader is the room creator
    }

    /// Someone finished reading a script teleprompter: releases the next chained one.
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

    // MARK: Script (only the room creator fires the script ones)

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
        if !tpScript.isEmpty { flash(String(localized: "\(tpScript.count) teleprompter del guion listos")) }
    }

    /// Same as the web: first exact username or name (what prePod chose in «lo lee»), then a fuzzy name match.
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

    /// Called every tenth of a second while recording, with the current recording second.
    func tickTeleprompter(_ t: Double) {
        guard isOwner, !tpScript.isEmpty else { return }
        for (i, s) in tpScript.enumerated() where tpFired[s.id] == nil {
            var countdown = 3
            if s.afterPrev, i > 0, let prevAt = tpFired[tpScript[i - 1].id] {
                // «Después del anterior»: goes out when the reader notifies they finished.
                // If nobody notifies (old version, dropped), it goes out 15 s after the computed time.
                let prev = tpScript[i - 1]
                guard tpDone.contains(prev.id) || t >= prevAt + 3 + prev.run + 15 else { continue }
                countdown = max(3, Int(s.gap.rounded()))
            } else {
                let at = s.offset - 3            // 3 s notice beforehand
                guard t >= at, t <= at + 2 else { continue }
            }
            tpFired[s.id] = t
            let msg: [String: Any] = ["type": "teleprompter", "action": "show", "event_id": "s\(s.id)",
                                      "target": tpIdentity(for: s.speakerKey), "title": String(localized: "Guion · \(s.speaker)"),
                                      "text": s.content, "speed": s.speed, "size": s.size, "countdown": countdown]
            send(msg)
            handleTeleprompter(msg)      // for me too
        }
    }
}

// MARK: Visual layer (host and guest)

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
                            Text(String(localized: "Viene **\(n.title)** en \(n.remaining) s")).font(.title3.weight(.semibold))
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
                Label(a.title.isEmpty ? String(localized: "Teleprompter") : a.title, systemImage: "text.viewfinder")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                Button(a.paused ? String(localized: "Seguir") : String(localized: "Pausa"), systemImage: a.paused ? "play.fill" : "pause.fill") { studio.tpPause() }
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

/// The text scrolls from bottom to top with progress (0: still out below; 1: already out the top).
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
