import Foundation
import CoreImage
import AppKit

/// Corrección de color de Studio · Video: por clip de b-roll, por cámara (toda la persona) o por pista (todo el episodio).
/// Todo son filtros de Core Image del sistema: exposición, contraste, temperatura, saturación, piel (vibrance) y,
/// si hay, un look en forma de LUT `.cube` con su intensidad. Se aplica igual en la vista previa y al exportar.
struct ColorGrade: Codable, Equatable {
    var exposure: Double = 0        // EV, −2 … +2
    var contrast: Double = 0        // −50 … +50 (%)
    var temperature: Double = 0     // −100 (frío) … +100 (cálido)
    var saturation: Double = 0      // −100 … +100 (%)
    var skin: Double = 0            // −50 … +50: realza o calma los colores apagados sin pasarse con la piel (vibrance)
    var lut: String?                // archivo .cube en la biblioteca de looks de esta Mac
    var amount: Double = 1          // intensidad del look (LUT) 0 … 1
    var look: String?               // nombre del look aplicado (para mostrarlo), si vino de uno

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        skin = try c.decodeIfPresent(Double.self, forKey: .skin) ?? 0
        lut = try c.decodeIfPresent(String.self, forKey: .lut)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1
        look = try c.decodeIfPresent(String.self, forKey: .look)
    }

    var isEmpty: Bool {
        abs(exposure) < 1e-6 && abs(contrast) < 1e-6 && abs(temperature) < 1e-6 && abs(saturation) < 1e-6 && abs(skin) < 1e-6 && (lut == nil || amount < 1e-6)
    }

    /// Looks de serie (paramétricos, sin archivos): sirven como punto de partida.
    static let builtIn: [(name: String, grade: ColorGrade)] = [
        (String(localized: "Cálido Studio"), { var g = ColorGrade(); g.temperature = 12; g.contrast = 10; g.saturation = 8; g.exposure = 0.1; g.look = String(localized: "Cálido Studio"); return g }()),
        (String(localized: "Frío noche"), { var g = ColorGrade(); g.temperature = -18; g.contrast = 12; g.saturation = -10; g.look = String(localized: "Frío noche"); return g }()),
        ("Documental", { var g = ColorGrade(); g.saturation = -22; g.contrast = 8; g.exposure = -0.05; g.look = "Documental"; return g }()),
    ]

    /// Aplica la corrección a un cuadro. Orden: exposición → temperatura → contraste/saturación → piel → LUT (con intensidad).
    func apply(to img: CIImage) -> CIImage {
        if isEmpty { return img }
        var out = img
        if abs(exposure) > 1e-6 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if abs(temperature) > 1e-6 {
            // 6500 K neutro; hacia cálido baja la temperatura objetivo, hacia frío la sube
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - CGFloat(temperature) * 25, y: 0)])
        }
        if abs(contrast) > 1e-6 || abs(saturation) > 1e-6 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + contrast / 100,
                kCIInputSaturationKey: max(0, 1 + saturation / 100)])
        }
        if abs(skin) > 1e-6 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": skin / 50]) }
        if let lut, amount > 1e-6, let cube = LUTLibrary.filter(named: lut) {
            cube.setValue(out, forKey: kCIInputImageKey)
            if let graded = cube.outputImage {
                out = amount >= 0.999 ? graded
                    : graded.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputTimeKey: 1 - amount])
            }
        }
        return out.cropped(to: img.extent)
    }
}

/// Biblioteca de looks `.cube` de esta Mac (`~/Library/Application Support/thePod/looks/`). Importar copia el archivo;
/// los filtros se arman una vez por archivo y se reutilizan en todos los cuadros.
enum LUTLibrary {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let f = base.appendingPathComponent("thePod/looks", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }
    static func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".cube") }.sorted()
    }
    /// Copia un .cube a la biblioteca (si ya hay uno con ese nombre, lo reemplaza). Devuelve el nombre o nil si no es un LUT válido.
    @discardableResult
    static func importCube(_ url: URL) -> String? {
        guard parse(url) != nil else { return nil }
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        lock.lock(); cache[url.lastPathComponent] = nil; lock.unlock()
        return url.lastPathComponent
    }
    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        lock.lock(); cache[name] = nil; lock.unlock()
    }

    private static var cache: [String: (size: Int, data: Data)] = [:]
    private static let lock = NSLock()

    /// Lee un .cube (LUT_3D_SIZE N y N³ filas r g b, el rojo variando más rápido) a los datos que pide Core Image (RGBA float).
    static func parse(_ url: URL) -> (size: Int, data: Data)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0
        var floats: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0; continue
            }
            if line.uppercased().hasPrefix("TITLE") || line.uppercased().hasPrefix("DOMAIN") || line.uppercased().hasPrefix("LUT_1D") { continue }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count >= 3 { floats.append(parts[0]); floats.append(parts[1]); floats.append(parts[2]); floats.append(1) }
        }
        guard size >= 2, size <= 64, floats.count == size * size * size * 4 else { return nil }
        return (size, floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    static func filter(named name: String) -> CIFilter? {
        lock.lock()
        var entry = cache[name]
        if entry == nil, let p = parse(folder.appendingPathComponent(name)) { cache[name] = p; entry = p }
        lock.unlock()
        guard let entry, let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(entry.size, forKey: "inputCubeDimension")
        f.setValue(entry.data, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        return f
    }
}

/// Igualar cámaras: con el color medio (r, g, b en 0–255) del centro del cuadro de cada cámara, acercar las demás a
/// la de referencia: una ganancia por canal (balance de blancos) y una exposición en EV (brillo).
enum CameraMatch {
    struct Fix: Equatable { var gain: [Double]; var exposure: Double }
    static func fix(camera a: [Double], reference ref: [Double]) -> Fix {
        func luma(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
        let la = max(1, luma(a)), lr = max(1, luma(ref))
        let ev = min(1, max(-1, log2(lr / la)))
        // La ganancia por canal iguala el tinte una vez compensado el brillo
        let k = pow(2, ev)
        let gain = (0..<3).map { min(1.3, max(0.75, ref[$0] / max(1, a[$0] * k))) }
        return Fix(gain: gain, exposure: (ev * 100).rounded() / 100)
    }
}
