import SwiftUI
import AppKit

/// Something the director puts on screen: sponsor lower third, podcast lower third, segment, etc.
struct Overlay: Identifiable, Equatable {
    let id: Int                 // server's event_id
    let kind: String            // sponsor | banner | segment | comment | countdown | graphic
    var title: String
    var text: String
    var filePath: String?
    var image: NSImage?
    var expires: Date?
    var endsAt: Date?            // countdown: until when

    static func == (a: Overlay, b: Overlay) -> Bool { a.id == b.id && a.title == b.title && a.text == b.text && (a.image == nil) == (b.image == nil) }

    /// How long it stays on screen (same as the web; 0 = until removed).
    static func seconds(for kind: String) -> Double {
        ["banner": 10, "segment": 12, "comment": 10, "sponsor": 15, "graphic": 10, "countdown": 0][kind] ?? 10
    }

    /// Builds the lower third from the room message.
    static func from(_ m: [String: Any]) -> Overlay? {
        guard let id = m["event_id"] as? Int else { return nil }
        let kind = m["event_type"] as? String ?? "banner"
        let p = m["payload"] as? [String: Any] ?? [:]
        var title = "", text = ""
        switch kind {
        case "sponsor": title = p["sponsor_name"] as? String ?? ""; text = p["sponsor_copy"] as? String ?? ""
        case "banner": title = p["name"] as? String ?? ""; text = p["title"] as? String ?? ""
        case "segment": title = p["title"] as? String ?? ""; text = p["subtitle"] as? String ?? ""
        case "comment": title = p["author"] as? String ?? ""; text = p["text"] as? String ?? ""
        case "countdown": title = p["label"] as? String ?? String(localized: "Volvemos en"); text = "\(p["seconds"] as? Int ?? 180) s"
        default: title = p["caption"] as? String ?? ""
        }
        let secs = (m["duration_seconds"] as? Double) ?? (m["duration_seconds"] as? Int).map(Double.init) ?? seconds(for: kind)
        var o = Overlay(id: id, kind: kind, title: title, text: text,
                        filePath: (m["file_path"] as? String) ?? (p["file_path"] as? String),
                        image: nil, expires: secs > 0 ? Date().addingTimeInterval(secs) : nil)
        if kind == "countdown" { o.endsAt = Date().addingTimeInterval(Double(p["seconds"] as? Int ?? 180)) }
        return o
    }

    var accent: Color {
        switch kind {
        case "sponsor": return Color(red: 0.70, green: 0.45, blue: 1.0)
        case "banner": return .prodPod
        case "segment": return Color(red: 0.40, green: 0.62, blue: 1.0)
        case "comment": return Color(red: 0.35, green: 0.85, blue: 0.55)
        default: return .orange
        }
    }
    var tag: String {
        ["sponsor": String(localized: "PATROCINA"), "banner": String(localized: "AHORA"), "segment": String(localized: "SEGMENTO"), "comment": String(localized: "COMENTARIO"), "countdown": String(localized: "PAUSA")][kind] ?? ""
    }
}

/// News-style lower third: logo on the left, text beside it, at the bottom.
struct Cintillo: View {
    let overlay: Overlay
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 0) {
            if overlay.image != nil || overlay.kind != "segment" { logo }
            bars
        }
        .frame(maxWidth: 760 * scale)
        .clipShape(RoundedRectangle(cornerRadius: 4 * scale))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var logo: some View {
            ZStack {
                Rectangle().fill(.white)
                if let img = overlay.image {
                    Image(nsImage: img).resizable().scaledToFit().padding(6 * scale)
                } else {
                    Text(String(overlay.title.prefix(1)).uppercased())
                        .font(.system(size: 30 * scale, weight: .black, design: .rounded)).foregroundStyle(overlay.accent)
                }
            }
            .frame(width: 78 * scale, height: 78 * scale)
    }

    private var bars: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if !overlay.tag.isEmpty {
                        Text(overlay.tag).font(.system(size: 11 * scale, weight: .heavy))
                            .padding(.horizontal, 6 * scale).padding(.vertical, 2 * scale)
                            .background(Color.black.opacity(0.25)).foregroundStyle(.white)
                    }
                    Text(overlay.title.uppercased()).font(.system(size: 17 * scale, weight: .heavy)).foregroundStyle(.white).lineLimit(1)
                }
                .padding(.horizontal, 12 * scale)
                .frame(maxWidth: .infinity, minHeight: 34 * scale, alignment: .leading)
                .background(overlay.accent)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(displayText(ctx.date))
                    .font(.system(size: 16 * scale, weight: .semibold)).foregroundStyle(.black).lineLimit(2)
                    .padding(.horizontal, 12 * scale)
                    .frame(maxWidth: .infinity, minHeight: 44 * scale, alignment: .leading)
                    .background(Color.white.opacity(0.94))
                }
            }
    }

    private func displayText(_ now: Date) -> String {
        if let end = overlay.endsAt {
            let r = max(0, Int(end.timeIntervalSince(now)))
            return String(format: "%d:%02d", r / 60, r % 60)
        }
        return overlay.text.isEmpty ? " " : overlay.text
    }
}

/// Requests the lower third image (logo) from the server.
enum OverlayImages {
    @MainActor static var cache: [String: NSImage] = [:]
    @MainActor static func load(sessionId: Int, filePath: String?) async -> NSImage? {
        guard let fp = filePath, !fp.isEmpty else { return nil }
        if let i = cache[fp] { return i }
        let name = (fp as NSString).lastPathComponent
        guard let d = try? await ProdPodClient.shared.get("/api/sessions/\(sessionId)/director/assets/\(name)"),
              let img = NSImage(data: d) else { return nil }
        cache[fp] = img
        return img
    }
}
