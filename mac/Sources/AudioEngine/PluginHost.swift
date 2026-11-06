import AVFoundation
import AudioToolbox
import AppKit
import CoreAudioKit

/// Third-party (and system) Audio Unit plugins in the voice chain: find the installed ones, instantiate,
/// save and restore their state, and open their window.
///
/// AUv3s run out of process (requested by `.loadOutOfProcess`): if one fails, the app doesn't go down. AUv2s
/// run in process; the list warns about it.
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

    /// Effects installed on this Mac (minus the ones the chain already uses internally).
    static func available() -> [Available] {
        var out: [Available] = []
        for t in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: t, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
                let d = c.audioComponentDescription
                // Those already forming the chain aren't offered (they'd be duplicated)
                if d.componentManufacturer == kAudioUnitManufacturer_Apple,
                   [kAudioUnitSubType_NBandEQ, kAudioUnitSubType_DynamicsProcessor, kAudioUnitSubType_PeakLimiter].contains(d.componentSubType) { continue }
                out.append(Available(name: c.name, vendor: c.manufacturerName, type: d.componentType, subtype: d.componentSubType,
                                     manufacturer: d.componentManufacturer, isV3: d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0))
            }
        }
        return out.sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
    }

    // MARK: Recently used (the last 6 put into a chain, on this Mac)

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

    /// Instantiates the plugin (out of process if possible). Waits at most 5 s. Nil if not installed or it fails.
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
            // Some AUv2s don't accept out-of-process: in process then
            var u: AudioUnit?
            if AudioComponentInstanceNew(comp, &u) == noErr { result = u }
        }
        return result
    }

    /// Format and block size like the rest of the chain. False if the plugin doesn't accept that format.
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

    /// The plugin's full state (its parameters and preset), as a binary plist.
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

    // MARK: The plugin window

    /// One «editing» instance per open plugin: its UI lives here; every change is saved to the
    /// project and the playing chains receive it (`restore`). That way the window survives the
    /// preview being rebuilt.
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
                    // Every parameter change → save state (with a breather so as not to saturate)
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

    /// The open windows, by insert id.
    @MainActor static var editors: [UUID: Editor] = [:]

    @MainActor static func openEditor(_ insert: PluginInsert, title: String, onChange: @escaping (Data) -> Void) {
        if let e = editors[insert.id] { e.open(title: title); return }
        let e = Editor(insert: insert, onChange: onChange)
        editors[insert.id] = e
        e.open(title: title)
    }
}
