import Foundation
import AVFoundation
import CoreImage
import Vision
import AppKit

/// Finds the best frames for the cover: episode moments where everyone
/// on camera is smiling, with eyes open and a sharp image. Looks at each lane
/// separately (each person comes in their own video) and combines per episode second.
///
/// How each face is scored: smile (CIDetector), open eyes (CIDetector) and face quality
/// (Vision: sharpness, light, pose). A second is worth what its worst person is worth: if one isn't smiling,
/// that second doesn't win.
enum CoverScout {
    struct Sample {
        var time: Double
        var score: Double
        var allSmiling: Bool
        var faces: Int
    }

    struct LaneSource {
        let laneId: Int
        let url: URL
        let lane: Lane
    }

    /// How many candidates are returned and the minimum separation between them.
    static let maxCandidates = 12
    static let minGap = 8.0

    private static let detector: CIDetector? = CIDetector(
        ofType: CIDetectorTypeFace, context: CIContext(options: [.useSoftwareRenderer: false]),
        options: [CIDetectorAccuracy: CIDetectorAccuracyLow, CIDetectorTracking: false])

    /// Walks the episode every `step` seconds (skipping what's cut) and returns the best seconds.
    static func scan(project: Project, step: Double = 2.0,
                     progress: @escaping (Double, String) -> Void) async throws -> [Sample] {
        let sources: [LaneSource] = project.lanesOnScreen.compactMap { lane in
            guard let clip = lane.clips.first, let m = project.mediaItem(clip.mediaId), m.kind == .video, m.hasVideo else { return nil }
            return LaneSource(laneId: lane.id, url: ProjectStore.url(m.file, in: project.id), lane: lane)
        }
        guard !sources.isEmpty else { return [] }

        let cuts = project.enabledCuts.map { ($0.start, $0.end) }
        var times: [Double] = []
        var t = 1.0
        while t < project.duration - 1 {
            if !cuts.contains(where: { t >= $0.0 && t <= $0.1 }) { times.append(t) }
            t += step
        }
        guard !times.isEmpty else { return [] }

        // Per lane: face score at each requested second
        var perLane: [[Double: FaceScore]] = []
        for (i, src) in sources.enumerated() {
            try Task.checkCancellation()
            let name = project.laneName(src.laneId)
            let scores = try await scoreLane(src, times: times) { f in
                progress((Double(i) + f) / Double(sources.count), String(localized: "Mirando a \(name)…"))
            }
            perLane.append(scores)
        }

        // Combine: a second is worth its worst person
        var samples: [Sample] = []
        for t in times {
            var worst = 1.0, faces = 0, allSmiling = true, any = false
            for scores in perLane {
                guard let s = scores[t] else { continue }
                any = true
                if s.faces == 0 { worst = min(worst, 0.05); allSmiling = false; continue }
                faces += s.faces
                allSmiling = allSmiling && s.smiling
                worst = min(worst, s.total)
            }
            guard any, faces > 0 else { continue }
            samples.append(Sample(time: t, score: worst, allSmiling: allSmiling, faces: faces))
        }

        // The best ones, separated from each other: first those where everyone smiles, then by score
        let ranked = samples.sorted { a, b in
            if a.allSmiling != b.allSmiling { return a.allSmiling }
            return a.score > b.score
        }
        var picked: [Sample] = []
        for s in ranked where picked.count < maxCandidates {
            if picked.contains(where: { abs($0.time - s.time) < minGap }) { continue }
            picked.append(s)
        }
        return picked.sorted { $0.time < $1.time }
    }

    struct FaceScore {
        var faces: Int
        var smiling: Bool
        var eyesOpen: Bool
        var quality: Double     // 0…1 (Vision)
        var total: Double       // combined 0…1
    }

    /// Decodes a lane's frames (small, fast) and scores the face in each.
    private static func scoreLane(_ src: LaneSource, times: [Double],
                                  progress: @escaping (Double) -> Void) async throws -> [Double: FaceScore] {
        let asset = AVURLAsset(url: src.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Episode second → second in this person's file
        var map: [(src: Double, tl: Double)] = []
        for t in times {
            for p in src.lane.placed where t >= p.tlStart && t < p.tlEnd {
                map.append((p.clip.srcIn + (t - p.tlStart), t)); break
            }
        }
        guard !map.isEmpty else { return [:] }

        var out: [Double: FaceScore] = [:]
        let cmTimes = map.map { CMTime(seconds: $0.src, preferredTimescale: 600) }
        var i = 0
        for await result in gen.images(for: cmTimes) {
            try Task.checkCancellation()
            defer { i += 1; if i % 10 == 0 { progress(Double(i) / Double(map.count)) } }
            guard i < map.count, case .success(_, let cg, _) = result else { continue }
            out[map[i].tl] = score(cg)
        }
        return out
    }

    /// Scores a frame of a person.
    static func score(_ cg: CGImage) -> FaceScore {
        let ci = CIImage(cgImage: cg)
        let feats = (detector?.features(in: ci, options: [CIDetectorSmile: true, CIDetectorEyeBlink: true]) ?? [])
            .compactMap { $0 as? CIFaceFeature }
        guard let face = feats.max(by: { $0.bounds.width < $1.bounds.width }) else {
            return FaceScore(faces: 0, smiling: false, eyesOpen: false, quality: 0, total: 0)
        }
        let smiling = face.hasSmile
        let eyesOpen = !(face.leftEyeClosed || face.rightEyeClosed)
        // Face quality according to Vision (sharpness, light, pose), 0…1
        var quality = 0.5
        let req = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        if (try? handler.perform([req])) != nil, let best = req.results?.max(by: { ($0.faceCaptureQuality ?? 0) < ($1.faceCaptureQuality ?? 0) }),
           let q = best.faceCaptureQuality {
            quality = Double(q)
        }
        // Face size in the frame: very small is no good for a cover
        let sizeFrac = Double(face.bounds.width / CGFloat(cg.width))
        let sizeScore = min(1, sizeFrac / 0.22)
        var total = 0.15 + 0.45 * quality + 0.25 * sizeScore
        if smiling { total += 0.15 }
        if !eyesOpen { total *= 0.4 }
        return FaceScore(faces: feats.count, smiling: smiling, eyesOpen: eyesOpen, quality: quality, total: min(1, total))
    }

    /// Draws the cover as it looks (layout, logo, background) at that episode second. 16:9 JPEG.
    static func render(project: Project, at tl: Double, energy: EnergyMap?, maxSize: CGFloat = 1920) async throws -> CGImage {
        let built = try await CompositionBuilder.build(project: project, format: .landscape, window: nil, energy: energy)
        let gen = AVAssetImageGenerator(asset: built.asset)
        gen.videoComposition = built.videoComposition
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let outT = (EditEngine.toOutput(tl, keep: built.keep) ?? tl) + built.introDuration
        let (img, _) = try await gen.image(at: CMTime(seconds: max(0.1, outT), preferredTimescale: 600))
        return img
    }

    /// Draws several candidates with a single composition (faster than one by one).
    static func renderAll(project: Project, times: [Double], energy: EnergyMap?, maxSize: CGFloat,
                          progress: @escaping (Double) -> Void) async throws -> [Double: CGImage] {
        let built = try await CompositionBuilder.build(project: project, format: .landscape, window: nil, energy: energy)
        let gen = AVAssetImageGenerator(asset: built.asset)
        gen.videoComposition = built.videoComposition
        gen.maximumSize = CGSize(width: maxSize, height: maxSize)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var out: [Double: CGImage] = [:]
        for (i, tl) in times.enumerated() {
            try Task.checkCancellation()
            let outT = (EditEngine.toOutput(tl, keep: built.keep) ?? tl) + built.introDuration
            if let (img, _) = try? await gen.image(at: CMTime(seconds: max(0.1, outT), preferredTimescale: 600)) {
                out[tl] = img
            }
            progress(Double(i + 1) / Double(times.count))
        }
        return out
    }

    static func jpeg(_ cg: CGImage, quality: Double = 0.88) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
