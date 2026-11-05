import AVFoundation
import AppKit
import CoreImage

/// Pruebas de Studio · Video. Se corren sin archivos de video: la escena se arma con imágenes de color y se
/// dibuja con el mismo `RenderScene` que usa el export, así lo que se comprueba es lo que sale.
///
/// `--video-studio-test`: keyframes, transiciones, cortes de cámara, permanencia mínima, guardar/cargar.
/// `--studio-tests`: todas las pruebas de Studio seguidas (audio y video).
enum StudioTests {
    private static let ctx = CIContext(options: [.cacheIntermediates: false])

    /// Color medio (r, g, b) de un recuadro del cuadro dibujado (fracciones del cuadro, y desde arriba).
    private static func mean(_ img: CIImage, _ box: CGRect, size: CGSize) -> (r: Double, g: Double, b: Double) {
        let W = size.width, H = size.height
        let r = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    private static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ size: CGSize) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Una escena de dos personas (1 = roja, 2 = verde) sin nombres, subtítulos ni logo.
    private static func scene(layout: LayoutTemplate, switches: [SpeakerSwitch]) -> RenderScene {
        var style = CaptionStyle(); style.enabled = false
        return RenderScene(renderSize: CGSize(width: 640, height: 360), format: .landscape, layout: layout, laneOrder: [1, 2],
                           trackIDs: [:], captions: [], style: style, switches: switches,
                           names: [:], showNames: false, cropX: [:], logo: nil, background: nil, title: "prueba")
    }

    static func videoStudioTest() -> Bool {
        let size = CGSize(width: 640, height: 360)
        let frames: [Int: CIImage] = [1: solid(1, 0, 0, CGSize(width: 1280, height: 720)), 2: solid(0, 1, 0, CGSize(width: 1280, height: 720))]
        var ok = true
        func check(_ cond: Bool, _ what: String) { print((cond ? "  ok  " : "  FAIL") + " " + what); if !cond { ok = false } }

        // 1) Interpolación de keyframes: lineal, suave y pausa
        var a = LayerAnimation()
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .linear); a.write(LayerAnimation.x, t: 10, v: 1)
        check(abs((a.value(LayerAnimation.x, at: 5) ?? -1) - 0.5) < 1e-9, "keyframe lineal: a mitad de camino vale 0,5")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .smooth)
        let sm = a.value(LayerAnimation.x, at: 2.5) ?? -1
        check(sm > 0.1 && sm < 0.25, "keyframe suave: arranca despacio (\(String(format: "%.3f", sm)) a un cuarto)")
        a.write(LayerAnimation.x, t: 0, v: 0, ease: .hold)
        check(abs((a.value(LayerAnimation.x, at: 9.9) ?? -1) - 0) < 1e-9 && abs((a.value(LayerAnimation.x, at: 10) ?? -1) - 1) < 1e-9, "keyframe pausa: salta justo en el siguiente")
        check(a.value(LayerAnimation.y, at: 3) == nil, "un parámetro sin keyframes devuelve nil (usa el valor fijo)")

        // 2) Una capa con keyframes de posición se mueve en el cuadro dibujado
        let s1 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let blue = solid(0, 0, 1, CGSize(width: 120, height: 120))
        var anim = LayerAnimation()
        anim.write(LayerAnimation.x, t: 0, v: 0.15, ease: .linear); anim.write(LayerAnimation.x, t: 10, v: 0.85)
        anim.write(LayerAnimation.opacity, t: 0, v: 1, ease: .linear); anim.write(LayerAnimation.opacity, t: 10, v: 1)
        var card = RenderScene.OverlayCard(id: 7, start: 0, end: 10, image: blue, cx: 0.5, cy: 0.5, animate: false)
        card.anim = anim; card.baseScale = 1
        s1.overlays = [card]
        let f0 = s1.render(frames: frames, time: 0.5), f9 = s1.render(frames: frames, time: 9.5)
        let leftAt0 = mean(f0, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        let leftAt9 = mean(f9, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        let rightAt9 = mean(f9, CGRect(x: 0.78, y: 0.4, width: 0.14, height: 0.2), size: size)
        check(leftAt0.b > 0.7 && leftAt0.r < 0.3, "capa con keyframes: al inicio está a la izquierda (azul sobre rojo)")
        check(leftAt9.r > 0.7 && leftAt9.b < 0.3 && rightAt9.b > 0.7, "capa con keyframes: al final está a la derecha")
        // opacidad a 0 → no se ve
        anim.write(LayerAnimation.opacity, t: 0, v: 0, ease: .hold); anim.write(LayerAnimation.opacity, t: 10, v: 0)
        card.anim = anim; s1.overlays = [card]
        let fo = s1.render(frames: frames, time: 0.5)
        let hidden = mean(fo, CGRect(x: 0.08, y: 0.4, width: 0.14, height: 0.2), size: size)
        check(hidden.r > 0.7 && hidden.b < 0.3, "keyframe de opacidad 0: la capa no se ve")

        // 3) Cortes de cámara a mano ganan a quién habla, y la plantilla del tramo también
        let sw = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 5, lane: 2)]
        let s2 = scene(layout: .solo, switches: sw)
        s2.cameraSpans = [RenderScene.CameraSpan(start: 6, end: 8, lane: 1, template: nil),
                          RenderScene.CameraSpan(start: 8, end: 9, lane: nil, template: .sideBySide)]
        let c5 = mean(s2.render(frames: frames, time: 5.5), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        let c7 = mean(s2.render(frames: frames, time: 7), CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(c5.g > 0.7 && c5.r < 0.3, "sin tramo a mano: a los 5,5 s se ve a quien habla (verde)")
        check(c7.r > 0.7 && c7.g < 0.3, "tramo a mano 6–8 s: se ve la persona fijada (roja) aunque hable la otra")
        let f8 = s2.render(frames: frames, time: 8.5)
        let l8 = mean(f8, CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), size: size), r8 = mean(f8, CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2), size: size)
        check(l8.r > 0.6 && r8.g > 0.6, "tramo a mano con plantilla Lado a lado: rojo a la izquierda, verde a la derecha")
        check(s2.activeLane(at: 7).lane == 1 && s2.activeLane(at: 9.5).lane == 2, "fuera del tramo vuelve el automático")

        // 4) Permanencia mínima: los cambios muy seguidos se posponen o se saltan; apagado «sigue a quien habla» = una cámara
        let rapid = [SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2), SpeakerSwitch(time: 1.8, lane: 1), SpeakerSwitch(time: 6, lane: 2)]
        var st = StudioVideoSettings(); st.minHold = 2.5
        let held = AudioAnalysis.cameraSwitches(rapid, settings: st)
        check(held.count == 2 && held[1].lane == 2 && held[1].time == 6, "permanencia 2,5 s: el ida y vuelta de 1 s se salta, queda 0→1 y 6→2 (\(held.map { "\($0.time):\($0.lane)" }))")
        var st2 = StudioVideoSettings(); st2.minHold = 2.5
        let late = AudioAnalysis.cameraSwitches([SpeakerSwitch(time: 0, lane: 1), SpeakerSwitch(time: 1, lane: 2)], settings: st2)
        check(late.count == 2 && abs(late[1].time - 2.5) < 1e-9, "un cambio a 1 s se pospone a 2,5 s")
        st2.followSpeaker = false
        check(AudioAnalysis.cameraSwitches(rapid, settings: st2).count == 1, "sin seguir a quien habla: una sola cámara")

        // 5) Transición «a negro» en un b-roll: a mitad de la transición el cuadro está oscuro; «corte» entra entero
        let s3 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let white = solid(1, 1, 1, CGSize(width: 1280, height: 720))
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .black, duration: 1))]
        let mid = mean(s3.render(frames: frames, time: 2.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        let after = mean(s3.render(frames: frames, time: 3.5), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(mid.r < 0.15 && mid.g < 0.15 && mid.b < 0.15, "transición a negro: a mitad está oscuro (\(String(format: "%.2f", mid.r)))")
        check(after.r > 0.9 && after.g > 0.9, "después de la transición el b-roll se ve entero")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .cut, duration: 1))]
        let cutIn = mean(s3.render(frames: frames, time: 2.05), CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), size: size)
        check(cutIn.r > 0.9, "transición corte: entra entero desde el primer cuadro")
        s3.brolls = [RenderScene.BRoll(trackID: nil, image: white, start: 2, end: 6, fill: true, placement: "full", transition: Transition(kind: .slide, duration: 1))]
        let slide = s3.render(frames: frames, time: 2.5)
        let sl = mean(slide, CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2), size: size), sr = mean(slide, CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2), size: size)
        check(sl.r > 0.9 && sl.g > 0.9 && sr.g < 0.3, "transición deslizar: a mitad ya cubre la izquierda y aún no la derecha")

        // 5b) Entradas y salidas de un título: subir deja la capa más abajo a mitad de camino; escribir la revela de izquierda
        //     a derecha; fundido al salir la apaga; sin entrada elegida, la salida simple sigue
        let s4 = scene(layout: .solo, switches: [SpeakerSwitch(time: 0, lane: 1)])
        let wide = solid(0, 0, 1, CGSize(width: 320, height: 60))
        var tc = RenderScene.OverlayCard(id: 9, start: 2, end: 8, image: wide, cx: 0.5, cy: 0.5, animate: true)
        tc.enter = TitleMotion(kind: .rise, duration: 1)
        s4.overlays = [tc]
        let risen = s4.render(frames: frames, time: 2.3)        // un tercio de la subida
        let centerY = mean(risen, CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        let belowY = mean(risen, CGRect(x: 0.45, y: 0.56, width: 0.1, height: 0.08), size: size)
        check(belowY.b > 0.3 && belowY.b > centerY.b, "entrada «subir»: a un tercio la capa está más abajo que su sitio")
        let settled = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(settled.b > 0.7, "después de la entrada la capa está en su sitio y entera")
        tc.enter = TitleMotion(kind: .reveal, duration: 1)
        s4.overlays = [tc]
        let half = s4.render(frames: frames, time: 2.5)
        let leftHalf = mean(half, CGRect(x: 0.27, y: 0.46, width: 0.08, height: 0.08), size: size)
        let rightHalf = mean(half, CGRect(x: 0.65, y: 0.46, width: 0.08, height: 0.08), size: size)
        check(leftHalf.b > 0.7 && rightHalf.r > 0.7, "entrada «escribir»: a mitad se ve la izquierda y aún no la derecha")
        tc.enter = nil; tc.exit = TitleMotion(kind: .fade, duration: 1)
        s4.overlays = [tc]
        let fading = mean(s4.render(frames: frames, time: 7.8), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        let shown = mean(s4.render(frames: frames, time: 5), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), size: size)
        check(fading.b < shown.b - 0.3, "salida «fundido»: al final la capa se va apagando")

        // 6) Guardar y cargar: el proyecto conserva keyframes, transiciones y cortes; uno viejo (sin esos campos) abre igual
        var p = Project(id: "prueba-studio", name: "Prueba", podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        var layer = VideoLayer(id: 1, kind: .text, start: 3, text: "Hola")
        layer.animation = anim
        layer.enter = TitleMotion(kind: .wipe, duration: 0.3)
        p.overlays = [layer]
        var br = BRollClip(id: 1, file: "broll/x.mp4", isVideo: true, start: 10)
        br.transitionIn = Transition(kind: .zoom, duration: 0.8)
        p.brolls = [br]
        p.studioVideo.cuts = [CameraCut(start: 6, end: 8, lane: 1, template: .pip)]
        p.studioVideo.minHold = 3
        do {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            let data = try enc.encode(p)
            let back = try dec.decode(Project.self, from: data)
            check(back.overlays.first?.animation == anim && back.overlays.first?.enter?.kind == .wipe && back.brolls.first?.transitionIn?.kind == .zoom
                  && back.studioVideo.cuts.first?.template == .pip && back.studioVideo.minHold == 3, "guardar y cargar conserva todo lo de Studio · Video")
            check(back.videoTunedInStudio && !Project(id: "x", name: "x", podcastName: nil, createdAt: Date(), importedFrom: "tracks").videoTunedInStudio, "«ajustado en Studio» se detecta solo cuando hay algo")
            // un proyecto sin los campos nuevos
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            obj["studioVideo"] = nil
            var ov = obj["overlays"] as! [[String: Any]]; ov[0]["animation"] = nil; ov[0]["enter"] = nil; obj["overlays"] = ov
            var bs = obj["brolls"] as! [[String: Any]]; bs[0]["transitionIn"] = nil; obj["brolls"] = bs
            let old = try dec.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
            check(old.overlays.first?.animation == nil && old.overlays.first?.enter == nil && old.brolls.first?.transitionIn == nil && old.studioVideo.isDefault, "un proyecto viejo abre con los valores de siempre")
        } catch { check(false, "guardar/cargar: \(error)") }

        print(ok ? "OK Studio · Video: keyframes, cortes de cámara, permanencia, transiciones, entradas de título y guardado" : "FAIL Studio · Video")
        return ok
    }
}
