import Foundation

/// Plantillas de título de Studio · Video: el estilo, color, posición, tamaño, entrada y salida de una capa de texto,
/// guardados con nombre. Viven en el podcast (prePod, `title_presets`) para que viajen a cualquier Mac con la cuenta;
/// aquí queda una copia por podcast para trabajar sin conexión, y las que no son de ningún podcast («mías») solo en esta Mac.
/// Una plantilla no lleva el texto ni el momento: eso es de cada capa.
enum TitlePresets {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var style: VideoLayer.Style = .title
        var color: String = "#FFFFFF"
        var x: Double = 0.5
        var y: Double = 0.5
        var scale: Double = 1
        var enter: TitleMotion?
        var exit: TitleMotion?
        var duration: Double = 5

        init(name: String, from layer: VideoLayer) {
            self.name = name
            style = layer.style; color = layer.color; x = layer.x; y = layer.y; scale = layer.scale
            enter = layer.enter; exit = layer.exit; duration = layer.duration
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decode(String.self, forKey: .name)
            style = try c.decodeIfPresent(VideoLayer.Style.self, forKey: .style) ?? .title
            color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
            scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
            enter = try c.decodeIfPresent(TitleMotion.self, forKey: .enter)
            exit = try c.decodeIfPresent(TitleMotion.self, forKey: .exit)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
        }

        /// Aplica la plantilla a una capa: todo menos el texto, el momento y los keyframes propios.
        func apply(to layer: inout VideoLayer) {
            layer.style = style; layer.color = color; layer.x = x; layer.y = y; layer.scale = scale
            layer.enter = enter; layer.exit = exit
            if duration > 0 { layer.duration = duration }
        }
    }

    private static func key(_ slug: String?) -> String { slug.map { "estudio.titulos.\($0)" } ?? "estudio.titulos" }

    static func all(podcast slug: String? = nil) -> [Item] {
        guard let d = UserDefaults.standard.data(forKey: key(slug)), let v = try? JSONDecoder().decode([Item].self, from: d) else { return [] }
        return v
    }
    static func save(_ items: [Item], podcast slug: String? = nil) {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key(slug)) }
        if let slug, PrePodClient.isConfigured {
            Task { try? await PrePodClient.shared.setTitlePresets(slug, items) }
        }
    }
    static func add(name: String, from layer: VideoLayer, podcast slug: String? = nil) {
        var items = all(podcast: slug).filter { $0.name != name }
        items.append(Item(name: name, from: layer))
        save(items, podcast: slug)
    }
    static func remove(_ id: UUID, podcast slug: String? = nil) { save(all(podcast: slug).filter { $0.id != id }, podcast: slug) }

    /// Trae las del podcast desde prePod y actualiza la copia local (si prePod no responde, queda la copia).
    static func refresh(podcast slug: String) async {
        guard PrePodClient.isConfigured, let items = try? await PrePodClient.shared.titlePresets(slug) else { return }
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key(slug)) }
    }
}
