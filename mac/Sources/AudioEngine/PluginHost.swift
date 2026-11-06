import AVFoundation
import AudioToolbox
import AppKit
import CoreAudioKit

/// Plugins Audio Unit de terceros (y del sistema) en la cadena de voz: buscar los instalados, instanciar,
/// guardar y restaurar su estado, y abrir su ventana.
///
/// Los AUv3 corren fuera de proceso (lo pide `.loadOutOfProcess`): si uno falla, no cae la app. Los AUv2
/// corren dentro; se avisa en la lista.
enum PluginHost {
    struct Available: Identifiable, Hashable {
        let name: String
        let vendor: String
        let type: UInt32
        let subtype: UInt32
        let manufacturer: UInt32
        let isV3: Bool
        var id: String { "\(type)-\(subtype)-\(manufacturer)" }
        var insert: PluginInsert { PluginInsert(type: type, subtype: subtype, manufacturer: manufacturer, name: name, vendor: vendor) }
    }

    /// Efectos instalados en esta Mac (sin los que ya usa la cadena por dentro).
    static func available() -> [Available] {
        var out: [Available] = []
        for t in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: t, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                // Los que ya forman la cadena no se ofrecen (estarían duplicados)
                if d.componentManufacturer == kAudioUnitManufacturer_Apple,
                   [kAudioUnitSubType_NBandEQ, kAudioUnitSubType_DynamicsProcessor, kAudioUnitSubType_PeakLimiter].contains(d.componentSubType) { continue }
                out.append(Available(name: c.name, vendor: c.manufacturerName, type: d.componentType, subtype: d.componentSubType,
                                     manufacturer: d.componentManufacturer, isV3: d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0))
            }
        }
        return out.sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
    }

    // MARK: Usados hace poco (los últimos 6 que se metieron en una cadena, en esta Mac)

    private static let usedKey = "estudio.plugins.usados"
    static func noteUsed(_ a: Available) {
        var ids = (UserDefaults.standard.stringArray(forKey: usedKey) ?? []).filter { $0 != a.id }
        ids.insert(a.id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(6)), forKey: usedKey)
    }
    static func favorites(from avail: [Available]) -> [Available] {
        (UserDefaults.standard.stringArray(forKey: usedKey) ?? []).compactMap { id in avail.first { $0.id == id } }
    }

    static func description(_ p: PluginInsert) -> AudioComponentDescription {
        AudioComponentDescription(componentType: p.type, componentSubType: p.subtype, componentManufacturer: p.manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    /// Instancia el plugin (fuera de proceso si se puede). Espera como mucho 5 s. Nil si no está instalado o falla.
    static func instantiate(_ p: PluginInsert) -> AudioUnit? {
        var desc = description(p)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var result: AudioUnit?
        let sem = DispatchSemaphore(value: 0)
        AudioComponentInstantiate(comp, [.loadOutOfProcess]) { unit, _ in
            result = unit
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut { return nil }
        if result == nil {
            // Algunos AUv2 no aceptan fuera de proceso: dentro entonces
            var u: AudioUnit?
            if AudioComponentInstanceNew(comp, &u) == noErr { result = u }
        }
        return result
    }

    /// Formato y tamaño de bloque como el resto de la cadena. Falso si el plugin no acepta ese formato.
    static func configure(_ u: AudioUnit, format: inout AudioStreamBasicDescription, maxFrames: UInt32) -> Bool {
        var frames = maxFrames
        let sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let a = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sz)
        let b = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sz)
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        return a == noErr && b == noErr
    }

    static func setBypass(_ u: AudioUnit, _ bypass: Bool) {
        var v: UInt32 = bypass ? 1 : 0
        AudioUnitSetProperty(u, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &v, UInt32(MemoryLayout<UInt32>.size))
    }

    /// El estado completo del plugin (sus parámetros y preset), como plist binario.
    static func state(of u: AudioUnit) -> Data? {
        var plist: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioUnitGetProperty(u, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, &size) == noErr,
              let obj = plist?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
    }

    static func restore(_ data: Data?, into u: AudioUnit) {
        guard let data, let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return }
        var plist: Unmanaged<CFPropertyList>? = Unmanaged.passUnretained(obj as CFPropertyList)
        AudioUnitSetProperty(u, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &plist, UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size))
    }

    // MARK: La ventana del plugin

    /// Una instancia «de edición» por plugin abierto: su interfaz vive aquí; cada cambio se guarda en el
    /// proyecto y las cadenas que suenan lo reciben (`restore`). Así la ventana sobrevive a que la vista
    /// previa se rearme.
    @MainActor
    final class Editor {
        let insert: PluginInsert
        private var unit: AVAudioUnit?
        private var window: NSWindow?
        private var token: AUParameterObserverToken?
        private var pushTask: Task<Void, Never>?
        private let onChange: (Data) -> Void

        init(insert: PluginInsert, onChange: @escaping (Data) -> Void) {
            self.insert = insert
            self.onChange = onChange
        }

        func open(title: String) {
            if let w = window { w.makeKeyAndOrderFront(nil); return }
            let desc = PluginHost.description(insert)
            AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { [weak self] unit, error in
                guard let self else { return }
                Task { @MainActor in
                    guard let unit else {
                        let a = NSAlert(); a.messageText = String(localized: "No se pudo abrir \(self.insert.name)"); a.informativeText = error?.localizedDescription ?? ""; a.runModal(); return
                    }
                    self.unit = unit
                    let au = unit.auAudioUnit
                    if let st = self.insert.state, let dict = (try? PropertyListSerialization.propertyList(from: st, options: [], format: nil)) as? [String: Any] {
                        au.fullState = dict
                    }
                    // Cada cambio de parámetro → guardar estado (con un respiro para no saturar)
                    self.token = au.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
                        Task { @MainActor in self?.scheduleSave() }
                    })
                    au.requestViewController { [weak self] vc in
                        Task { @MainActor in self?.show(vc, title: title) }
                    }
                }
            }
        }

        private func show(_ vc: NSViewController?, title: String) {
            let content: NSViewController
            if let vc { content = vc } else {
                let v = NSTextField(labelWithString: String(localized: "Este plugin no trae interfaz propia: usa sus presets o sus parámetros desde la consola."))
                v.frame = NSRect(x: 0, y: 0, width: 420, height: 60)
                let c = NSViewController(); c.view = v; content = c
            }
            let w = NSWindow(contentViewController: content)
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closed() }
            }
            w.makeKeyAndOrderFront(nil)
            window = w
        }

        private func scheduleSave() {
            pushTask?.cancel()
            pushTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self.save()
            }
        }

        private func save() {
            guard let au = unit?.auAudioUnit, let st = au.fullState,
                  let data = try? PropertyListSerialization.data(fromPropertyList: st, format: .binary, options: 0) else { return }
            onChange(data)
        }

        private func closed() {
            save()
            if let t = token { unit?.auAudioUnit.parameterTree?.removeParameterObserver(t) }
            token = nil
            unit = nil
            window = nil
            PluginHost.editors[insert.id] = nil
        }
    }

    /// Las ventanas abiertas, por id de insert.
    @MainActor static var editors: [UUID: Editor] = [:]

    @MainActor static func openEditor(_ insert: PluginInsert, title: String, onChange: @escaping (Data) -> Void) {
        if let e = editors[insert.id] { e.open(title: title); return }
        let e = Editor(insert: insert, onChange: onChange)
        editors[insert.id] = e
        e.open(title: title)
    }
}
