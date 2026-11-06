import SwiftUI
import UniformTypeIdentifiers

/// Panel de color de Studio · Video: un look (de serie o un .cube de esta Mac) con su intensidad y los ajustes
/// básicos. Edita un `ColorGrade?` donde se le indique: un clip, una cámara o toda la pista.
struct ColorPanel: View {
    @Binding var grade: ColorGrade?
    var title: String = "Color"
    @State private var tick = 0

    private var g: ColorGrade { grade ?? ColorGrade() }
    private func set(_ f: (inout ColorGrade) -> Void) {
        var v = g; f(&v)
        grade = v.isEmpty ? nil : v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                if grade != nil {
                    Button("Quitar") { grade = nil }.controlSize(.mini).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                }
            }
            HStack {
                Text("Look").font(.caption)
                Spacer()
                Menu {
                    Button("Ninguno") { set { $0.lut = nil; $0.look = nil } }
                    Divider()
                    Text("De serie")
                    ForEach(ColorGrade.builtIn, id: \.name) { l in
                        Button(l.name) { var v = l.grade; v.lut = g.lut; v.amount = g.amount; grade = v }
                    }
                    let cubes = LUTLibrary.names()
                    if !cubes.isEmpty {
                        Divider()
                        Text("De tu Mac (.cube)")
                        ForEach(cubes, id: \.self) { n in Button(n) { set { $0.lut = n; $0.look = n } } }
                        Menu("Borrar un .cube") { ForEach(cubes, id: \.self) { n in Button(n, role: .destructive) { LUTLibrary.remove(n); if g.lut == n { set { $0.lut = nil; $0.look = nil } }; tick += 1 } } }
                    }
                    Divider()
                    Button("Importar .cube…") { importCube() }
                } label: { Text(g.look ?? g.lut ?? "Ninguno").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().id(tick)
            }
            if g.lut != nil {
                row("Intensidad", value: Binding(get: { g.amount }, set: { v in set { $0.amount = v } }), range: 0...1, fmt: { String(format: "%.0f %%", $0 * 100) })
            }
            row("Exposición", value: Binding(get: { g.exposure }, set: { v in set { $0.exposure = v } }), range: -2...2, fmt: { String(format: "%+.1f", $0) })
            row("Contraste", value: Binding(get: { g.contrast }, set: { v in set { $0.contrast = v } }), range: -50...50, fmt: { String(format: "%+.0f", $0) })
            row("Temperatura", value: Binding(get: { g.temperature }, set: { v in set { $0.temperature = v } }), range: -100...100, fmt: { String(format: "%+.0f", $0) })
            row("Saturación", value: Binding(get: { g.saturation }, set: { v in set { $0.saturation = v } }), range: -100...100, fmt: { String(format: "%+.0f", $0) })
            row("Piel", value: Binding(get: { g.skin }, set: { v in set { $0.skin = v } }), range: -50...50, fmt: { String(format: "%+.0f", $0) })
        }
    }

    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: @escaping (Double) -> String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
            Text(fmt(value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
        .contextMenu { Button("Volver a 0") { value.wrappedValue = range.contains(0) ? 0 : range.lowerBound } }
    }

    private func importCube() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = String(localized: "Un look en formato .cube (LUT 3D), como los que exportan Resolve, Premiere o Final Cut")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let name = LUTLibrary.importCube(url) { set { $0.lut = name; $0.look = name }; tick += 1 }
    }
}
