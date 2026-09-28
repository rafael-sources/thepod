import AppKit
import AVFoundation

/// Al cerrar thePod suena la firma de thePod al revés (y la ventana se desvanece mientras suena).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var player: AVAudioPlayer?

    static var soundOnQuit: Bool {
        get { UserDefaults.standard.object(forKey: "sonidoAlCerrar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sonidoAlCerrar") }
    }

    /// Cerrar la ventana con la X cierra thePod (y suena igual que con ⌘Q).
    private var leavingRoom = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !SelfTest.isRequested }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Si estás en una sala de prod: salir bien (termina la grabación y avisa a prodPod)
        if let studio = ProdStudio.current, studio.phase == .inRoom, !leavingRoom {
            if studio.recording {
                let a = NSAlert()
                a.messageText = "Estás grabando"
                a.informativeText = "Si cierras thePod se detiene tu grabación. Lo grabado queda en tu Mac y se termina de subir la próxima vez que abras prod."
                a.addButton(withTitle: "Cerrar igual")
                a.addButton(withTitle: "Seguir grabando")
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
