import Foundation
import AVFoundation
import ScreenCaptureKit
import LiveKit

/// Screen sharing: macOS shows its own picker (a screen or a window).
/// The image goes to the room (unless it's "solo grabar") and is recorded on the Mac to upload separately.
@MainActor
final class ScreenShare: NSObject, ObservableObject {
    @Published var active = false
    @Published var recordOnly = false
    @Published var label = ""

    private var stream: SCStream?
    private let output = ScreenOutput()
    private var track: LocalVideoTrack?
    private var publication: LocalTrackPublication?
    private var onPicked: ((SCContentFilter) -> Void)?
    private var onCancel: (() -> Void)?

    /// Opens the macOS picker. Returns the selection or nil if cancelled.
    func pick() async -> SCContentFilter? {
        await withCheckedContinuation { (c: CheckedContinuation<SCContentFilter?, Never>) in
            var done = false
            onPicked = { f in if !done { done = true; c.resume(returning: f) } }
            onCancel = { if !done { done = true; c.resume(returning: nil) } }
            let picker = SCContentSharingPicker.shared
            var cfg = SCContentSharingPickerConfiguration()
            cfg.allowedPickerModes = [.singleWindow, .singleDisplay]
            picker.defaultConfiguration = cfg
            picker.add(self)
            picker.isActive = true
            picker.present()
        }
    }

    func start(filter: SCContentFilter, room: Room?, recorder: FragmentRecorder?, recordOnly: Bool) async throws {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        var w = rect.width * scale, h = rect.height * scale
        let fit = min(1, min(1920 / max(w, 1), 1080 / max(h, 1)))
        w = (w * fit).rounded(); h = (h * fit).rounded()
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w) & ~1
        cfg.height = Int(h) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 6

        if !recordOnly, room != nil {
            let t = await LocalVideoTrack.createBufferTrack(
                name: "screen", source: .screenShareVideo,
                options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(cfg.width), height: Int32(cfg.height)), fps: 18))
            output.sink = t.capturer as? BufferCapturer
            track = t
        }
        output.recorder = recorder
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "thepod.screen"))
        try await s.startCapture()
        stream = s
        if let t = track, let room {
            try await Task.sleep(nanoseconds: 300_000_000)      // at least one frame before publishing
            publication = try await room.localParticipant.publish(
                videoTrack: t,
                options: VideoPublishOptions(name: "screen", screenShareEncoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 18),
                                             simulcast: false, preferredCodec: .vp8))
        }
        self.recordOnly = recordOnly
        active = true
    }

    func attach(_ r: FragmentRecorder?) { output.recorder = r }

    func stop(room: Room?) async {
        try? await stream?.stopCapture()
        stream = nil
        output.recorder = nil
        output.sink = nil
        if let pub = publication, let room { try? await room.localParticipant.unpublish(publication: pub) }
        publication = nil
        track = nil
        active = false
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
    }
}

extension ScreenShare: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.onPicked?(filter); self.onPicked = nil }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.onCancel?(); self.onCancel = nil }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.onCancel?(); self.onCancel = nil }
    }
}

final class ScreenOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _sink: BufferCapturer?
    private var _recorder: FragmentRecorder?
    var sink: BufferCapturer? { get { lock.withLock { _sink } } set { lock.withLock { _sink = newValue } } }
    var recorder: FragmentRecorder? { get { lock.withLock { _recorder } } set { lock.withLock { _recorder = newValue } } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        recorder?.appendVideo(sb)
        sink?.capture(sb)
    }
}
