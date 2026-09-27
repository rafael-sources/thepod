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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !SelfTest.isRequested }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
