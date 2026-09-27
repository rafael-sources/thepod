import SwiftUI
import AVFoundation

/// Entrada de thePod al abrir la app: el sonido oficial ("cambur pintón" en cuatro) y los cuatro
/// íconos que se encienden con su nota y al final se unen en el disco de thePod.
/// Tiempos tomados de ThePodSound.timing('cambur') del handoff de diseño.
struct IntroView: View {
    let onFinish: () -> Void

    private enum Pod: Int, CaseIterable { case pre, prod, ama, post }
    // Segundos desde que arranca el audio (el WAV empieza a sonar a los 0.02 s).
    private static let noteTimes: [Pod: Double] = [.pre: 0.02, .ama: 0.24, .post: 0.46, .prod: 0.68]
    private static let bloom = 1.164
    private static let total = bloom + 1.5

    @State private var lit: Set<Pod> = []
    @State private var allOn = false
    @State private var showName = false
    @State private var player: AVAudioPlayer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(red: 0.102, green: 0.082, blue: 0.063).ignoresSafeArea()      // #1A1510
            VStack(spacing: 28) {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { tile(.pre); tile(.prod) }
                    GridRow { tile(.post); tile(.ama) }
                }
                Text("thePod")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.937, green: 0.890, blue: 0.816))   // #EFE3D0
                    .opacity(showName ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear(perform: start)
    }

    private func tile(_ pod: Pod) -> some View {
        let on = allOn || lit.contains(pod)
        return Image("tile-" + ["prepod", "prodpod", "amapod", "postpod"][pod.rawValue])
            .resizable()
            .frame(width: 96, height: 96)
            .opacity(on ? 1 : 0.18)
            .scaleEffect(on && !reduceMotion ? 1.04 : 1)
            .animation(.easeOut(duration: 0.18), value: on)
    }

    private func start() {
        if let url = Bundle.main.url(forResource: "thepod-login", withExtension: "wav"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            p.prepareToPlay()
            p.play()
            player = p
        }
        let t0 = Date()
        func at(_ t: Double, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, t - Date().timeIntervalSince(t0)), execute: action)
        }
        for (pod, t) in Self.noteTimes { at(t) { lit.insert(pod) } }
        at(Self.bloom - 0.04) { lit = [] }
        at(Self.bloom + 0.05) { allOn = true; withAnimation(.easeIn(duration: 0.4)) { showName = true } }
        at(Self.total) { finish() }
    }

    private func finish() {
        onFinish()
    }
}
