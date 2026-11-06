import SwiftUI
import AVFoundation

/// thePod intro on app launch: the official sound ("cambur pintón" in four parts) and the four
/// icons that light up with their note and finally join into the thePod disc.
/// With each note two of the eight stars appear (like those on the Venezuelan flag), in an arc over the disc.
/// Timings taken from ThePodSound.timing('cambur') in the design handoff.
struct IntroView: View {
    let onFinish: () -> Void
    var transparent = false          // to export the animation without background
    var silent = false

    private enum Pod: Int, CaseIterable { case pre, prod, ama, post }
    // Seconds since the audio starts (the WAV starts sounding at 0.02 s).
    private static let noteTimes: [Pod: Double] = [.pre: 0.02, .ama: 0.24, .post: 0.46, .prod: 0.68]
    private static let bloom = 1.164
    private static let total = bloom + 1.5

    @State private var lit: Set<Pod> = []
    @State private var stars = 0            // how many stars have appeared (0…8), two per note
    @State private var twinkle = false      // at the end: a short shine on all eight
    @State private var allOn = false
    @State private var showName = false
    @State private var player: AVAudioPlayer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !transparent { Color(red: 0.102, green: 0.082, blue: 0.063).ignoresSafeArea() }     // #1A1510
            VStack(spacing: 28) {
                ZStack {
                    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow { tile(.pre); tile(.prod) }
                        GridRow { tile(.post); tile(.ama) }
                    }
                    starsArc
                }
                .frame(width: 300, height: 260)
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

    /// Eight stars in an arc over the disc, as on the flag. They come out from the outside in, two per note.
    private var starsArc: some View {
        // Order of appearance: symmetric pairs from the arc's tips towards the center
        let order = [0, 7, 1, 6, 2, 5, 3, 4]
        let radius: CGFloat = 132
        return ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Angle.degrees(162 - Double(i) * (144.0 / 7))   // from 162° to 18°, over the top
                let x = cos(angle.radians) * radius
                let y = -sin(angle.radians) * radius + 26                   // the arc centered slightly above the disc
                let on = (order.firstIndex(of: i) ?? 8) < stars
                Image(systemName: "star.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(twinkle ? 0.9 : 0.45), radius: twinkle ? 9 : 4)
                    .scaleEffect(on ? (twinkle ? 1.18 : 1) : 0.2)
                    .opacity(on ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.55), value: on)
                    .animation(.easeInOut(duration: 0.25), value: twinkle)
                    .offset(x: x, y: y)
            }
        }
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
        if !silent, let url = Bundle.main.url(forResource: "thepod-login", withExtension: "wav"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            p.prepareToPlay()
            p.play()
            player = p
        }
        let t0 = Date()
        func at(_ t: Double, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, t - Date().timeIntervalSince(t0)), execute: action)
        }
        for (pod, t) in Self.noteTimes { at(t) { lit.insert(pod); stars = min(8, stars + 2) } }
        at(Self.bloom - 0.04) { lit = [] }
        at(Self.bloom + 0.05) { allOn = true; stars = 8; twinkle = true; withAnimation(.easeIn(duration: 0.4)) { showName = true } }
        at(Self.bloom + 0.5) { twinkle = false }
        at(Self.total) { finish() }
    }

    private func finish() {
        onFinish()
    }
}
