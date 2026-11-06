import AppKit
import AVFoundation

/// When thePod closes, thePod's signature plays backwards (and the window fades out while it plays).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer?

    static var soundOnQuit: Bool {
        get { UserDefaults.standard.object(forKey: "sonidoAlCerrar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sonidoAlCerrar") }
    }

    /// Closing the window with the X quits thePod (and sounds the same as ⌘Q).
    private var leavingRoom = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !SelfTest.isRequested }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If you're in a prod room: leave cleanly (stops the recording and notifies prodPod)
        if let studio = ProdStudio.current, studio.phase == .inRoom, !leavingRoom {
            if studio.recording {
                let a = NSAlert()
                a.messageText = String(localized: "Estás grabando")
                a.informativeText = String(localized: "Si cierras thePod se detiene tu grabación. Lo grabado queda en tu Mac y se termina de subir la próxima vez que abras prod.")
                a.addButton(withTitle: String(localized: "Cerrar igual"))
                a.addButton(withTitle: String(localized: "Seguir grabando"))
                if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            }
            leavingRoom = true
            Task { @MainActor in
                await studio.leave()
                sender.terminate(nil)
            }
            return .terminateCancel
        }
        if let ama = AmaStudio.current, ama.phase == .live, !leavingRoom {
            leavingRoom = true
            Task { @MainActor in await ama.leave(); sender.terminate(nil) }
            return .terminateCancel
        }
        if let dir = DirectorStudio.current, dir.connected, !leavingRoom {
            leavingRoom = true
            Task { @MainActor in await dir.leave(); sender.terminate(nil) }
            return .terminateCancel
        }
        guard Self.soundOnQuit, !SelfTest.isRequested, player == nil,
              let url = Bundle.main.url(forResource: "thepod-logout", withExtension: "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return .terminateNow }
        player = p
        p.play()
        let duration = p.duration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            for w in sender.windows where w.isVisible { w.animator().alphaValue = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
