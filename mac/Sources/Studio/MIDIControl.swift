import CoreMIDI
import Combine
import Foundation

/// Superficie de control MIDI para la consola de Studio: faders, M/S, reproducir y A/B desde un controlador
/// (o un Stream Deck que mande MIDI). Escucha todos los dispositivos conectados.
///
/// Mapa por defecto = Korg nanoKONTROL2 (el más común): faders CC 0–7, S CC 32–39, M CC 48–55, Play CC 41,
/// Stop CC 42, Rec CC 45 (A/B). Cualquier otro aparato se asigna con «Aprender»: eliges qué controlar y mueves
/// el control. El mapa queda guardado en esta Mac.
@MainActor
final class MIDIControl: ObservableObject {
    static let shared = MIDIControl()

    enum Action: Codable, Equatable, Hashable {
        case fader(Int), mute(Int), solo(Int), play, stop, ab
        var name: String {
            switch self {
            case .fader(let i): return String(localized: "Fader \(i + 1)"); case .mute(let i): return String(localized: "Mute \(i + 1)"); case .solo(let i): return String(localized: "Solo \(i + 1)")
            case .play: return String(localized: "Reproducir / pausa"); case .stop: return String(localized: "Parar"); case .ab: return "A/B"
            }
        }
    }
    /// Un control: "cc:<n>" o "note:<n>" (sin canal: los aparatos chicos usan uno solo)
    @Published var map: [String: Action] = [:]
    @Published var connected = false
    @Published var sources: [String] = []
    @Published var learning: Action?
    @Published var lastControl: String?
    /// Quien recibe las acciones (la sesión abierta).
    var handler: ((Action, Double) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var started = false
    private var lastFader: [Int: Date] = [:]

    static let nanoKontrol2: [String: Action] = {
        var m: [String: Action] = [:]
        for i in 0..<8 { m["cc:\(i)"] = .fader(i); m["cc:\(32 + i)"] = .solo(i); m["cc:\(48 + i)"] = .mute(i) }
        m["cc:41"] = .play; m["cc:42"] = .stop; m["cc:45"] = .ab
        return m
    }()

    private init() {
        if let d = UserDefaults.standard.data(forKey: "midi.map"), let m = try? JSONDecoder().decode([String: Action].self, from: d) { map = m }
        else { map = Self.nanoKontrol2 }
    }

    func start() {
        guard !started else { return }
        started = true
        let status = MIDIClientCreateWithBlock("thePod" as CFString, &client) { [weak self] notification in
            // Un aparato se conectó o se fue: volver a enlazar las fuentes
            let id = notification.pointee.messageID
            if id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgSetupChanged { Task { @MainActor in self?.connectSources() } }
        }
        guard status == noErr else { return }
        let ps = MIDIInputPortCreateWithProtocol(client, "entrada" as CFString, ._1_0, &port) { [weak self] eventList, _ in
            let packets = eventList.unsafeSequence()
            var found: [(UInt32)] = []
            for p in packets {
                let words = MIDIEventPacket.WordCollection(p)
                for w in words { found.append(w) }
            }
            Task { @MainActor in self?.handle(words: found) }
        }
        guard ps == noErr else { return }
        connectSources()
    }

    private func connectSources() {
        let n = MIDIGetNumberOfSources()
        var names: [String] = []
        for i in 0..<n {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            var cf: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cf)
            names.append(cf?.takeRetainedValue() as String? ?? String(localized: "MIDI \(i + 1)"))
        }
        sources = names
        connected = n > 0
    }

    /// Palabras UMP del protocolo 1.0: tipo 2 = mensaje de canal; estado en bits 16–23, datos en 8–15 y 0–7.
    func handle(words: [UInt32]) {
        for w in words {
            guard (w >> 28) & 0xF == 0x2 else { continue }
            let status = UInt8((w >> 16) & 0xFF), d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
            let kind = status & 0xF0
            let key: String
            let value: Double
            switch kind {
            case 0xB0: key = "cc:\(d1)"; value = Double(d2) / 127
            case 0x90: key = "note:\(d1)"; value = d2 > 0 ? 1 : 0
            case 0x80: key = "note:\(d1)"; value = 0
            default: continue
            }
            lastControl = key
            if let l = learning {
                // Aprender: el primer control que se mueve queda asignado
                map = map.filter { $0.value != l }
                map[key] = l
                learning = nil
                save()
                continue
            }
            guard let action = map[key] else { continue }
            switch action {
            case .fader:
                handler?(action, value)
            case .mute, .solo, .play, .stop, .ab:
                // botones: solo al pulsar (valor > 0)
                if value > 0.5 { handler?(action, 1) }
            }
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: "midi.map") }
    }
    func resetToNanoKontrol() { map = Self.nanoKontrol2; save() }
    func clear() { map = [:]; save() }

    /// Valor de fader MIDI (0…1) → volumen lineal de la pista: 0 = silencio, ~0,79 = 0 dB, 1 = +6 dB.
    static func volume(forFader v: Double) -> Double {
        guard v > 0.002 else { return 0 }
        let db = v < 0.79 ? -40 + (v / 0.79) * 40 : (v - 0.79) / 0.21 * 6
        return pow(10, db / 20)
    }
}
