import Foundation
import AVFoundation

/// Imports either:
///  • a postPod bundle (.zip with proyecto.sqlite + media/ from "export-bundle"), or
///  • raw prodPod tracks (a *_tracks.zip, a folder, or loose video/audio files).
/// WebM (VP8/VP9/Opus) is converted once to H.264/AAC MP4 with VideoToolbox so AVFoundation can play it.
enum Importer {
    typealias Progress = @Sendable (_ stage: String, _ fraction: Double) -> Void

    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    static let audioExts: Set<String> = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "ogg", "opus", "flac"]
    static let nativeExts: Set<String> = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac", "aif", "aiff"]

    enum Failure: LocalizedError {
        case nothingToImport
        var errorDescription: String? {
            "No encontramos videos ni audios para importar. Arrastra el paquete .zip de postPod o los archivos de tu grabación."
        }
    }

    static func importItems(_ urls: [URL], progress: @escaping Progress) async throws -> Project {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("postpod-import-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        var roots: [URL] = []
        var suggestedName: String?
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                progress("Abriendo el paquete…", 0.02)
                let dest = temp.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                try await unzip(url, to: dest)
                roots.append(descend(dest))
                suggestedName = suggestedName ?? prettyName(url.deletingPathExtension().lastPathComponent)
            } else {
                roots.append(url)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    suggestedName = suggestedName ?? prettyName(url.lastPathComponent)
                }
            }
        }

        if roots.count == 1, fm.fileExists(atPath: roots[0].appendingPathComponent("proyecto.sqlite").path) {
            return try await importBundle(root: roots[0], progress: progress)
        }

        var files: [URL] = []
        for r in roots { files.append(contentsOf: mediaFiles(in: r)) }
        guard !files.isEmpty else { throw Failure.nothingToImport }
        let name = suggestedName ?? prettyName(files[0].deletingPathExtension().lastPathComponent)
        return try await importTracks(files: files, name: name, progress: progress)
    }

    // MARK: - Raw tracks

    static func importTracks(files: [URL], name: String, progress: @escaping Progress) async throws -> Project {
        let slug = ProjectStore.uniqueSlug(for: name)
        let folder = ProjectStore.folder(for: slug)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)

        var project = Project(id: slug, name: name, podcastName: nil, createdAt: Date(), importedFrom: "tracks")
        let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var nextId = 1
        var laneId = 1
        for (i, file) in sorted.enumerated() {
            let stem = file.deletingPathExtension().lastPathComponent
            let isSoundboard = stem.lowercased().contains("soundboard")
            let base = Double(i) / Double(sorted.count)
            let span = 1.0 / Double(sorted.count)
            let donors = sorted.filter { $0 != file && ["webm", "mkv"].contains($0.pathExtension.lowercased()) }
            let media = try await prepareMedia(file, id: nextId, slug: slug, donors: donors) { stage, f in
                progress("\(stage) \(personName(from: stem)) (\(i + 1) de \(sorted.count))", 0.05 + 0.9 * (base + span * f))
            }
            nextId += 1
            project.media.append(media)
            if isSoundboard {
                project.audioLane.append(AudioLaneClip(id: media.id, mediaId: media.id, tlStart: 0, srcIn: 0, srcOut: media.duration, volume: 0.8))
            } else if media.kind != .image {
                let person = personName(from: stem)
                let participant = Participant(id: laneId, name: person, role: laneId == 1 ? "host" : "guest", track: laneId)
                project.participants.append(participant)
                project.lanes.append(Lane(id: laneId, name: person, participantId: participant.id,
                                          clips: [LaneClip(mediaId: media.id, srcIn: 0, srcOut: media.duration)],
                                          offset: media.startOffset))
                laneId += 1
            }
        }
        progress("Listo", 1)
        try ProjectStore.save(project)
        return project
    }

    // MARK: - postPod bundle

    static let compositeMarker = "[composite_podcast_hstack]"

    static func importBundle(root: URL, progress: @escaping Progress) async throws -> Project {
        let fm = FileManager.default
        var meta: [String: Any] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("proyecto.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta = obj
        }
        let name = (meta["name"] as? String) ?? prettyName(root.lastPathComponent)
        let slug = ProjectStore.uniqueSlug(for: (meta["slug"] as? String) ?? name)
        let folder = ProjectStore.folder(for: slug)
        try fm.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)

        var project = Project(id: slug, name: name, createdAt: Date(), importedFrom: "postpod-bundle")
        if let source = meta["source"] as? [String: Any], let podcast = source["podcast"] as? [String: Any] {
            project.podcastName = podcast["name"] as? String
        }

        let db = try SQLiteReader(url: root.appendingPathComponent("proyecto.sqlite"))
        let mediaRows = try db.query("SELECT * FROM media_files ORDER BY id")
        struct MF { var id: Int; var filename: String; var original: String; var type: String; var duration: Double }
        let mfs: [MF] = mediaRows.compactMap { r in
            guard let id = r.int("id"), let fn = r.string("filename") else { return nil }
            return MF(id: id, filename: fn, original: r.string("original_name") ?? fn,
                      type: r.string("file_type") ?? "video", duration: r.double("duration") ?? 0)
        }
        func path(_ m: MF) -> URL { root.appendingPathComponent("media/\(m.type)/\(m.filename)") }
        let isComposite: (MF) -> Bool = { $0.original.hasPrefix(compositeMarker) }
        let individualVideos = mfs.filter { $0.type == "video" && !isComposite($0) && !$0.original.contains("_screen_") }

        // Timeline clips → lanes
        struct TC { var mediaId: Int; var start: Double; var end: Double?; var track: Int; var volume: Double; var position: Int }
        let tcs: [TC] = db.tableExists("timeline_clips") ? try db.query("SELECT * FROM timeline_clips ORDER BY position, id").compactMap { r in
            guard let mid = r.int("media_file_id") else { return nil }
            return TC(mediaId: mid, start: r.double("start_offset") ?? 0, end: r.double("end_offset"),
                      track: r.int("track") ?? 1, volume: r.double("volume") ?? 1, position: r.int("position") ?? 0)
        } : []

        var laneDefs: [Int: [(mediaId: Int, srcIn: Double, srcOut: Double?, volume: Double)]] = [:]
        let usesComposite = tcs.contains { tc in mfs.first { $0.id == tc.mediaId }.map(isComposite) ?? false }
        if tcs.isEmpty || (usesComposite && individualVideos.count >= 2) {
            // No usable timeline (or only the pre-baked side-by-side): one lane per individual track,
            // keeping the composite's trims since the composite is an hstack of the same recordings.
            let trims = tcs.first.map { ($0.start, $0.end) } ?? (0, nil)
            let sources = individualVideos.isEmpty ? mfs.filter { $0.type != "image" && !isComposite($0) } : individualVideos
            for (i, m) in sources.prefix(4).enumerated() {
                laneDefs[i + 1] = [(m.id, trims.0, trims.1, 1.0)]
            }
        } else {
            for tc in tcs { laneDefs[tc.track, default: []].append((tc.mediaId, tc.start, tc.end, tc.volume)) }
        }

        // Audio lane
        var laneAudio: [(id: Int, mediaId: Int, tl: Double, s: Double, e: Double?, vol: Double)] = []
        if db.tableExists("audio_lane_clips") {
            for r in try db.query("SELECT * FROM audio_lane_clips ORDER BY tl_start, id") {
                guard let id = r.int("id"), let mid = r.int("media_file_id") else { continue }
                laneAudio.append((id, mid, r.double("tl_start") ?? 0, r.double("start_offset") ?? 0, r.double("end_offset"), r.double("volume") ?? 0.7))
            }
        }

        // Convert every media item we actually need.
        var needed = Set(laneDefs.values.flatMap { $0.map(\.mediaId) })
        needed.formUnion(laneAudio.map(\.mediaId))
        let neededList = mfs.filter { needed.contains($0.id) }
        var converted: [Int: SourceMedia] = [:]
        for (i, m) in neededList.enumerated() {
            let src = path(m)
            guard fm.fileExists(atPath: src.path) else { continue }
            let base = Double(i) / Double(max(1, neededList.count))
            let span = 1.0 / Double(max(1, neededList.count))
            var media = try await prepareMedia(src, id: m.id, slug: slug) { stage, f in
                progress("\(stage) \(personName(from: m.original)) (\(i + 1) de \(neededList.count))", 0.05 + 0.85 * (base + span * f))
            }
            media.originalName = m.original
            converted[m.id] = media
        }
        project.media = converted.values.sorted { $0.id < $1.id }

        for track in laneDefs.keys.sorted() {
            let clips: [LaneClip] = laneDefs[track]!.compactMap { d in
                guard let media = converted[d.mediaId] else { return nil }
                let out = min(d.srcOut ?? media.duration, media.duration)
                return LaneClip(mediaId: d.mediaId, srcIn: d.srcIn, srcOut: out > d.srcIn ? out : media.duration, volume: d.volume)
            }
            guard !clips.isEmpty else { continue }
            let media = converted[clips[0].mediaId]!
            let offset = clips.count == 1 && clips[0].srcIn == 0 ? media.startOffset : 0
            project.lanes.append(Lane(id: track, name: personName(from: media.originalName), participantId: nil,
                                      clips: clips, offset: offset))
        }
        project.audioLane = laneAudio.compactMap { a in
            guard let media = converted[a.mediaId] else { return nil }
            return AudioLaneClip(id: a.id, mediaId: a.mediaId, tlStart: a.tl, srcIn: a.s, srcOut: a.e ?? media.duration, volume: a.vol)
        }

        // Participants
        if db.tableExists("project_participants") {
            for r in try db.query("SELECT * FROM project_participants ORDER BY id") {
                guard let id = r.int("id"), let n = r.string("name") else { continue }
                project.participants.append(Participant(id: id, name: n, role: r.string("role") ?? "guest", track: r.int("track"),
                                                        instagram: r.string("social_instagram"), twitter: r.string("social_twitter"),
                                                        youtube: r.string("social_youtube"), tiktok: r.string("social_tiktok")))
            }
        }
        for i in project.lanes.indices {
            let laneId = project.lanes[i].id
            if let p = project.participants.first(where: { $0.track == laneId }) {
                project.lanes[i].participantId = p.id
            } else if let p = project.participants.first(where: { project.lanes[i].name.localizedCaseInsensitiveContains($0.name) }) {
                project.lanes[i].participantId = p.id
            }
        }

        // Transcripts: words.json sidecars are in source time of each media file.
        progress("Leyendo transcripciones…", 0.92)
        var words: [Word] = []
        for lane in project.lanes {
            for placed in lane.placed {
                guard let m = mfs.first(where: { $0.id == placed.clip.mediaId }) else { continue }
                let dir = root.appendingPathComponent("media/\(m.type)")
                let candidates = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .filter { $0.hasPrefix("\(m.id).") && $0.hasSuffix(".words.json") }
                guard let file = candidates.sorted().first else { continue }
                let lang = file.split(separator: ".").dropFirst().first.map(String.init) ?? "es"
                project.language = lang
                for w in parseWordsJSON(dir.appendingPathComponent(file)) {
                    guard w.s >= placed.clip.srcIn - 0.01, w.e <= placed.clip.srcOut + 0.01 else { continue }
                    let offset = placed.tlStart - placed.clip.srcIn
                    words.append(Word(w: w.w, s: w.s + offset, e: w.e + offset, p: w.p, lane: lane.id))
                }
                if !project.transcribedLanes.contains(lane.id) { project.transcribedLanes.append(lane.id) }
            }
        }
        project.words = Transcripts.merge(words)

        // Cuts made in the web transcript editor / silence tool.
        if db.tableExists("transcript_cuts") {
            project.cuts = try db.query("SELECT * FROM transcript_cuts ORDER BY start_seconds").compactMap { r in
                guard let s = r.double("start_seconds"), let e = r.double("end_seconds"), e > s else { return nil }
                return Cut(start: s, end: e, kind: .imported, label: r.string("label") ?? "Corte de postPod web")
            }
        }

        // Subtitle style
        if db.tableExists("subtitle_styles"), let r = try db.query("SELECT * FROM subtitle_styles ORDER BY id LIMIT 1").first {
            var st = CaptionStyle()
            st.preset = "postpod"
            switch r.string("font_family") ?? "" {
            case "serif": st.fontName = "Georgia-Bold"
            case "monospace", "mono": st.fontName = "Menlo-Bold"
            case "display": st.fontName = "Bangers-Regular"
            default: st.fontName = "HelveticaNeue-Bold"
            }
            st.size = CaptionStyle.Size(rawValue: r.string("font_size") ?? "medium") ?? .medium
            st.textColor = r.string("text_color") ?? st.textColor
            st.outlineColor = r.string("outline_color") ?? st.outlineColor
            st.backgroundColor = r.string("background_color")
            st.highlightColor = r.string("highlight_color") ?? st.highlightColor
            st.position = CaptionStyle.Position(rawValue: r.string("position") ?? "bottom") ?? .bottom
            project.captionStyle = st
        }

        // Branding
        for (key, file) in [("logo", meta["logo_filename"] as? String), ("background", meta["background_filename"] as? String)] {
            guard let file else { continue }
            let src = root.appendingPathComponent("branding/\(file)")
            guard fm.fileExists(atPath: src.path) else { continue }
            let rel = "branding/\(file)"
            let dest = folder.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: src, to: dest)
            if key == "logo" { project.logoFile = rel } else { project.backgroundFile = rel }
        }

        progress("Listo", 1)
        try ProjectStore.save(project)
        return project
    }

    // MARK: - Media preparation

    static func prepareMedia(_ src: URL, id: Int, slug: String, donors: [URL] = [],
                             progress: @escaping (String, Double) -> Void) async throws -> SourceMedia {
        let ext = src.pathExtension.lowercased()
        let isVideoExt = videoExts.contains(ext)
        let folder = ProjectStore.folder(for: slug)
        let mediaDir = folder.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let stem = "\(id)_" + ProjectStore.slugify(src.deletingPathExtension().lastPathComponent)

        if nativeExts.contains(ext), await isPlayable(src) {
            progress("Copiando", 0.1)
            let dest = mediaDir.appendingPathComponent("\(stem).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)   // APFS clone when on the same volume
            progress("Copiando", 1)
            return try await describe(dest, id: id, original: src.lastPathComponent, slug: slug)
        }

        // Needs conversion (WebM/MKV/Opus…)
        var input = src
        var repairedTemp: URL?
        defer { if let repairedTemp { try? FileManager.default.removeItem(at: repairedTemp) } }
        if ["webm", "mkv"].contains(ext), !(await canOpen(src)) {
            progress("Reparando", 0)
            let temp = ProjectStore.cacheFolder(for: slug).appendingPathComponent("repaired_\(id).webm")
            guard let fixed = WebMRepair.repair(src, donors: donors, to: temp), await canOpen(fixed) else {
                throw NSError(domain: "import", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "El archivo \(src.lastPathComponent) está dañado (le falta el encabezado) y no pudimos repararlo. Impórtalo junto a otra pista de la misma grabación para intentarlo."])
            }
            input = fixed
            repairedTemp = fixed
        }
        progress("Midiendo", 0)
        let duration = try await FFmpeg.probeDuration(input)
        let hasVideo = isVideoExt ? await FFmpeg.hasStream("Video", in: input) : false
        let starts = await FFmpeg.streamStarts(input)
        // Recordings that lost their head keep absolute timestamps. Instead of padding with black,
        // we trim to the first frame and remember the offset so the lane starts later on the timeline.
        let vS = max(0, starts.video ?? 0), aS = max(0, starts.audio ?? 0)
        let base = hasVideo ? min(vS, starts.audio == nil ? vS : aS) : aS
        let startOffset = base > 0.5 ? base : 0
        let dest = mediaDir.appendingPathComponent("\(stem).\(hasVideo ? "mp4" : "m4a")")
        var args = ["-fflags", "+genpts+discardcorrupt", "-err_detect", "ignore_err", "-i", input.path]
        if hasVideo {
            let vStart = max(0, vS - startOffset)
            var vf = startOffset > 0 ? "setpts=PTS-STARTPTS,format=yuv420p" : "format=yuv420p"
            if vStart > 0.1 {
                vf = "setpts=PTS-STARTPTS,tpad=start_duration=\(String(format: "%.3f", vStart)):color=black,format=yuv420p"
            }
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", vf,
                     "-c:v", "h264_videotoolbox", "-b:v", "8M", "-maxrate", "12M", "-bufsize", "16M",
                     "-profile:v", "high", "-fps_mode", "cfr", "-r", "30", "-g", "60"]
        } else {
            args += ["-vn", "-map", "0:a:0"]
        }
        let aStart = max(0, aS - startOffset)
        let af = aStart > 0.1
            ? "asetpts=PTS-STARTPTS,adelay=delays=\(Int(aStart * 1000)):all=1,aresample=async=1"
            : (startOffset > 0 ? "asetpts=PTS-STARTPTS,aresample=async=1" : "aresample=async=1:first_pts=0")
        args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-af", af, "-movflags", "+faststart", dest.path]
        try await FFmpeg.run(args, duration: max(1, duration - startOffset)) { f in progress("Convirtiendo", f) }
        var media = try await describe(dest, id: id, original: src.lastPathComponent, slug: slug)
        media.startOffset = startOffset
        return media
    }

    static func describe(_ url: URL, id: Int, original: String, slug: String) async throws -> SourceMedia {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let v = try await asset.loadTracks(withMediaType: .video)
        let a = try await asset.loadTracks(withMediaType: .audio)
        let rel = "media/\(url.lastPathComponent)"
        return SourceMedia(id: id, originalName: original, file: rel,
                           kind: v.isEmpty ? .audio : .video,
                           duration: duration.isFinite ? duration : 0,
                           hasAudio: !a.isEmpty, hasVideo: !v.isEmpty)
    }

    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable else { return false }
        let d = (try? await asset.load(.duration).seconds) ?? 0
        return d.isFinite && d > 0 && d < 86_400      // Safari MediaRecorder MP4s report absurd durations
    }

    // MARK: - Helpers

    static func canOpen(_ url: URL) async -> Bool {
        let log = await FFmpeg.inspect(url)
        return log.contains("Stream #") && !log.contains("Error opening input")
    }

    static func unzip(_ zip: URL, to dest: URL) async throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { c.resume() }
                else { c.resume(throwing: NSError(domain: "unzip", code: Int(proc.terminationStatus),
                                                  userInfo: [NSLocalizedDescriptionKey: "No se pudo descomprimir \(zip.lastPathComponent)"])) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    /// If a folder only contains one sub-folder (typical zips), step into it.
    static func descend(_ url: URL) -> URL {
        let items = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return descend(items[0])
        }
        return url
    }

    static func mediaFiles(in url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        let isMedia: (URL) -> Bool = { u in
            let e = u.pathExtension.lowercased()
            return (videoExts.contains(e) || audioExts.contains(e)) && !u.lastPathComponent.hasPrefix(".")
        }
        if !isDir.boolValue { return isMedia(url) ? [url] : [] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = e?.nextObject() as? URL {
            if u.pathComponents.contains("__MACOSX") { continue }
            if isMedia(u) { out.append(u) }
        }
        return out
    }

    static func parseWordsJSON(_ url: URL) -> [Word] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let dict = obj as? [String: Any], let w = dict["words"] as? [[String: Any]] { list = w }
        else if let arr = obj as? [[String: Any]] { list = arr }
        else { return [] }
        return list.compactMap { d in
            guard let w = d["w"] as? String, let s = (d["s"] as? NSNumber)?.doubleValue,
                  let e = (d["e"] as? NSNumber)?.doubleValue else { return nil }
            return Word(w: w, s: s, e: e, p: (d["p"] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// "Karelia_video_60" → "Karelia"
    static func personName(from stem: String) -> String {
        var s = (stem as NSString).deletingPathExtension
        for marker in ["_video_", "_audio_", "_track_", "-video-", "-audio-"] {
            if let r = s.range(of: marker, options: .caseInsensitive) { s = String(s[..<r.lowerBound]) }
        }
        s = s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? stem : s
    }

    static func prettyName(_ s: String) -> String {
        var n = s
        for suffix in ["_tracks", "_bundle", "-tracks", "-bundle"] where n.lowercased().hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
        }
        n = n.replacingOccurrences(of: "_", with: " ")
        return n.trimmingCharacters(in: .whitespaces)
    }
}


/// MediaRecorder uploads that lost their first chunk have no EBML header, so nothing can open them.
/// The clusters are intact, so we borrow the header (EBML + Segment + Tracks) from another track of the
/// same recording (same browser → same track layout) and append the orphan clusters.
enum WebMRepair {
    static let clusterID = Data([0x1F, 0x43, 0xB6, 0x75])
    static let ebmlID = Data([0x1A, 0x45, 0xDF, 0xA3])

    static func repair(_ broken: URL, donors: [URL], to dest: URL) -> URL? {
        guard let bh = try? FileHandle(forReadingFrom: broken) else { return nil }
        defer { try? bh.close() }
        let head = (try? bh.read(upToCount: 32 << 20)) ?? Data()
        guard !head.starts(with: ebmlID), let firstCluster = head.range(of: clusterID)?.lowerBound else { return nil }
        for donor in donors {
            guard let dh = try? FileHandle(forReadingFrom: donor) else { continue }
            let dhead = (try? dh.read(upToCount: 4 << 20)) ?? Data()
            try? dh.close()
            guard dhead.starts(with: ebmlID), let c = dhead.range(of: clusterID)?.lowerBound else { continue }
            let header = dhead.prefix(upTo: c)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let out = try? FileHandle(forWritingTo: dest) else { return nil }
            defer { try? out.close() }
            out.write(header)
            try? bh.seek(toOffset: UInt64(firstCluster))
            while let chunk = try? bh.read(upToCount: 64 << 20), !chunk.isEmpty { out.write(chunk) }
            return dest
        }
        return nil
    }
}
