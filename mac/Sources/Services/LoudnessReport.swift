import AVFoundation
import AppKit

/// Informe de sonoridad por export: la medida real (EBU R128 con ffmpeg) del archivo entregado —sonoridad
/// integrada, pico real, rango de sonoridad— y si cumple lo que pide cada destino. Va en PDF junto al archivo.
enum LoudnessReport {
    struct Measure: Equatable {
        var integrated: Double          // LUFS
        var truePeak: Double            // dBTP
        var range: Double               // LU (LRA)
        var duration: Double
    }

    struct Target {
        let name: String
        let lufs: Double
        let tolerance: Double
        let maxPeak: Double             // dBTP
        var passes: (Measure) -> Bool { { m in abs(m.integrated - lufs) <= tolerance && m.truePeak <= maxPeak } }
    }
    /// Lo que piden los destinos más comunes (valores públicos de cada plataforma).
    static let targets: [Target] = [
        Target(name: "Spotify (podcasts)", lufs: -16, tolerance: 1, maxPeak: -1),
        Target(name: "Apple Podcasts", lufs: -16, tolerance: 1, maxPeak: -1),
        Target(name: "YouTube · Instagram · TikTok", lufs: -14, tolerance: 1, maxPeak: -1),
        Target(name: "Radio · EBU R128", lufs: -23, tolerance: 1, maxPeak: -1),
    ]

    /// Mide el archivo con ffmpeg (ebur128 con pico real). Nil si no hay ffmpeg o no se pudo leer.
    static func measure(_ url: URL) async -> Measure? {
        guard let out = try? await FFmpeg.run(["-i", url.path, "-vn", "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"], allowFailure: true) else { return nil }
        return parse(out, duration: (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0)
    }

    /// Lee el resumen final de ffmpeg: "I: -16.3 LUFS", "LRA: 7.2 LU", "Peak: -1.4 dBFS" (el pico real).
    static func parse(_ out: String, duration: Double) -> Measure? {
        func num(_ pattern: String) -> Double? {
            guard let r = out.range(of: pattern, options: [.regularExpression, .backwards]) else { return nil }
            let s = String(out[r])
            guard let m = s.range(of: #"-?[0-9]+(\.[0-9]+)?"#, options: .regularExpression) else { return nil }
            return Double(s[m])
        }
        guard let i = num(#"I:\s+-?[0-9.]+ LUFS"#) else { return nil }
        let lra = num(#"LRA:\s+-?[0-9.]+ LU"#) ?? 0
        let peak = num(#"Peak:\s+-?[0-9.]+ dBFS"#) ?? 0
        return Measure(integrated: i, truePeak: peak, range: lra, duration: duration)
    }

    static func line(_ m: Measure, target: Double) -> String {
        String(format: "%.1f LUFS integrados · pico real %.1f dBTP · rango %.1f LU · objetivo %.0f", m.integrated, m.truePeak, m.range, target)
    }

    /// El PDF de una página junto al archivo exportado. Devuelve su ruta, o nil si no se pudo escribir.
    @discardableResult
    static func writePDF(project p: Project, file: URL, format: ExportFormat, measure m: Measure, target: Double) -> URL? {
        let pdf = file.deletingPathExtension().appendingPathExtension("sonoridad.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        guard let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        func text(_ s: String, size: CGFloat, bold: Bool = false, color: NSColor = .black, at y: CGFloat, x: CGFloat = 56) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        func rule(_ y: CGFloat) { ctx.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor); ctx.setLineWidth(0.8); ctx.move(to: CGPoint(x: 56, y: y)); ctx.addLine(to: CGPoint(x: 539, y: y)); ctx.strokePath() }
        let accent = NSColor(red: 0.957, green: 0.780, blue: 0.439, alpha: 1)
        var y: CGFloat = 770
        text("INFORME DE SONORIDAD", size: 10, bold: true, color: NSColor(white: 0.45, alpha: 1), at: y); y -= 26
        text(Exporter.episodeTitle(p), size: 18, bold: true, at: y); y -= 20
        text((p.podcastName ?? "") + " · " + format.title, size: 11, color: NSColor(white: 0.35, alpha: 1), at: y); y -= 16
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short; df.locale = Locale(identifier: "es")
        text("Archivo: \(file.lastPathComponent) · " + df.string(from: Date()), size: 10, color: NSColor(white: 0.45, alpha: 1), at: y); y -= 24
        rule(y); y -= 30
        // Medidas grandes
        func big(_ value: String, _ label: String, x: CGFloat) {
            text(value, size: 26, bold: true, at: y, x: x)
            text(label, size: 9, color: NSColor(white: 0.45, alpha: 1), at: y - 14, x: x)
        }
        big(String(format: "%.1f LUFS", m.integrated), "sonoridad integrada (BS.1770-4)", x: 56)
        big(String(format: "%.1f dBTP", m.truePeak), "pico real", x: 236)
        big(String(format: "%.1f LU", m.range), "rango de sonoridad (LRA)", x: 416)
        y -= 50
        let mins = Int(m.duration / 60), secs = Int(m.duration) % 60
        text(String(format: "Duración %d:%02d · objetivo del export %.0f LUFS · medido con EBU R128 sobre el archivo final", mins, secs, target), size: 10, color: NSColor(white: 0.35, alpha: 1), at: y); y -= 28
        rule(y); y -= 24
        text("Cumplimiento por destino", size: 12, bold: true, at: y); y -= 22
        for t in targets {
            let ok = t.passes(m)
            ctx.setFillColor((ok ? NSColor(red: 0.35, green: 0.70, blue: 0.45, alpha: 1) : NSColor(red: 0.85, green: 0.45, blue: 0.40, alpha: 1)).cgColor)
            ctx.fillEllipse(in: CGRect(x: 58, y: y + 3, width: 8, height: 8))
            text(t.name, size: 11, at: y, x: 74)
            let diff = m.integrated - t.lufs
            let why = ok ? "cumple" : (abs(diff) > t.tolerance ? String(format: "%@%.1f dB respecto a %.0f LUFS", diff > 0 ? "+" : "", diff, t.lufs) : String(format: "pico real %.1f dBTP (máximo %.0f)", m.truePeak, t.maxPeak))
            text(why, size: 11, color: ok ? NSColor(white: 0.35, alpha: 1) : NSColor(red: 0.6, green: 0.2, blue: 0.15, alpha: 1), at: y, x: 300)
            y -= 20
        }
        y -= 10; rule(y); y -= 24
        text("Qué significa", size: 12, bold: true, at: y); y -= 18
        let notes = [
            "Sonoridad integrada: el volumen percibido de todo el episodio, como lo miden las plataformas. Cada una lo lleva a su objetivo al reproducir; entregar ya en el objetivo evita que lo suban (más ruido) o lo bajen.",
            "Pico real: el nivel máximo de la señal tras convertirla a analógico. Por encima de −1 dBTP los códecs (MP3, AAC) pueden distorsionar.",
            "Rango de sonoridad: cuánto varía el volumen a lo largo del episodio. Para voz, entre 5 y 10 LU se escucha cómodo en el coche o la calle.",
        ]
        for n in notes {
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor(white: 0.3, alpha: 1), .paragraphStyle: para]
            let r = NSRect(x: 56, y: y - 36, width: 483, height: 40)
            (n as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attr)
            y -= 42
        }
        ctx.setFillColor(accent.cgColor)
        ctx.fill(CGRect(x: 56, y: 44, width: 483, height: 2))
        text("thePod · postPod para Mac", size: 9, color: NSColor(white: 0.45, alpha: 1), at: 30)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return pdf
    }
}
