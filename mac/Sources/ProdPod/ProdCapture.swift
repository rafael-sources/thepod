import Foundation
import AVFoundation
import VideoToolbox
import CoreAudio
import LiveKit

// MARK: - Cámara: una sola captura, dos salidas (grabación 1080p y sala 720p)

final class CameraPipe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "thepod.camera")
    private let audioQueue = DispatchQueue(label: "thepod.camera.audio")
    private let lock = NSLock()
    var sink: BufferCapturer? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }
    private var _sink: BufferCapturer?
    /// Grabación de prod: recibe la cámara completa y, con audífonos, el micrófono directo.
    var recorder: FragmentRecorder? {
        get { lock.withLock { _recorder } }
        set { lock.withLock { _recorder = newValue } }
    }
    private var _recorder: FragmentRecorder?
    var recordRawAudio: Bool {
        get { lock.withLock { _recordRawAudio } }
        set { lock.withLock { _recordRawAudio = newValue } }
    }
    private var _recordRawAudio = true
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var started = false
    private(set) var recordedFrames = 0
    private(set) var sentFrames = 0

    struct Size { let width: Int32; let height: Int32 }

    /// Tamaño que se manda a la sala (la grabación siempre usa la captura completa).
    var target: (width: Int, height: Int) {
        get { lock.withLock { _target } }
        set { lock.withLock { if _target != newValue { _target = newValue; pool = nil } } }
    }
    private var _target: (width: Int, height: Int) = (1280, 720)
    /// Para la vista previa de la pantalla previa.
    var captureSession: AVCaptureSession { session }
    private weak var audioConnection: AVCaptureConnection?

    /// Nivel del micrófono en dB (−160 … 0); nil si no hay micrófono.
    var micLevel: Float? {
        guard let c = audioConnection, let ch = c.audioChannels.first else { return nil }
        return ch.averagePowerLevel
    }
    /// Pico reciente del micrófono en dB; nil si no hay micrófono.
    var micPeak: Float? {
        guard let c = audioConnection, let ch = c.audioChannels.first else { return nil }
        return ch.peakHoldLevel
    }

    func start(device: AVCaptureDevice, mic micDevice: AVCaptureDevice? = AVCaptureDevice.default(for: .audio)) throws -> Size {
        session.beginConfiguration()
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PrePodClient.Failure(message: String(localized: "No se pudo usar la cámara")) }
        session.addInput(input)
        if let micDev = micDevice, let mic = try? AVCaptureDeviceInput(device: micDev), session.canAddInput(mic) {
            session.addInput(mic)
        }

        // El formato más cercano a 1080p a 30 cuadros, sin pasar de 1080p
        let best = device.formats
            .filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                return d.height <= 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
        // La cámara queda bloqueada hasta después de arrancar: si no, macOS vuelve a su modo automático
        // y con poca luz baja a 15 cuadros por segundo.
        try device.lockForConfiguration()
        if let best { device.activeFormat = best }
        let fps30 = CMTime(value: 1, timescale: 30)
        let canDo30 = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameDuration <= fps30 && $0.maxFrameDuration >= fps30 }
        if canDo30 {
            device.activeVideoMinFrameDuration = fps30
            device.activeVideoMaxFrameDuration = fps30
        }

        let vOut = AVCaptureVideoDataOutput()
        vOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        vOut.alwaysDiscardsLateVideoFrames = true
        vOut.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(vOut) { session.addOutput(vOut) }
        let aOut = AVCaptureAudioDataOutput()
        aOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(aOut) { session.addOutput(aOut) }
        session.commitConfiguration()
        audioConnection = aOut.connection(with: .audio)
        session.startRunning()
        if canDo30 {
            device.activeVideoMinFrameDuration = fps30
            device.activeVideoMaxFrameDuration = fps30
        }
        device.unlockForConfiguration()

        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return Size(width: d.width, height: d.height)
    }

    func stop() {
        session.stopRunning()
        sink = nil
    }

    // MARK: Grabación

    func startRecording(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        a.expectsMediaDataInRealTime = true
        if w.canAdd(v) { w.add(v) }
        if w.canAdd(a) { w.add(a) }
        lock.withLock {
            writer = w; videoIn = v; audioIn = a; started = false; recordedFrames = 0
        }
    }

    func stopRecording() {
        let w: AVAssetWriter? = lock.withLock {
            let w = writer
            writer = nil
            return w
        }
        guard let w, w.status == .writing else { w?.cancelWriting(); return }
        videoIn?.markAsFinished(); audioIn?.markAsFinished()
        w.finishWriting {}
    }

    // MARK: Cuadros

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        lock.lock()
        if let w = writer {
            if !started, isVideo {
                if w.startWriting() {
                    w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    started = true
                }
            }
            if started {
                if isVideo, let v = videoIn, v.isReadyForMoreMediaData { if v.append(sampleBuffer) { recordedFrames += 1 } }
                if !isVideo, let a = audioIn, a.isReadyForMoreMediaData { a.append(sampleBuffer) }
            }
        }
        let sink = _sink
        let rec = _recorder
        let rawAudio = _recordRawAudio
        lock.unlock()

        if let rec {
            if isVideo { rec.appendVideo(sampleBuffer) } else if rawAudio { rec.appendAudio(sampleBuffer) }
        }

        guard isVideo, let sink, let src = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let small = scaled(src) {
            let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
            sink.capture(small, timeStampNs: ts)
            sentFrames += 1
        }
    }

    /// Reduce al tamaño de la sala (con el chip de video de la Mac).
    private func scaled(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let (tw, th) = lock.withLock { _target }
        if w <= tw { return src }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: tw, kCVPixelBufferHeightKey as String: th,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let transfer, let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, VTPixelTransferSessionTransferImage(transfer, from: src, to: out) == noErr else { return nil }
        return out
    }
}

// MARK: - Voz tal como sale hacia la sala (después de quitar el eco)

final class VoiceTap: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?

    func start(_ url: URL) { lock.withLock { self.url = url; file = nil } }
    func stop() { lock.withLock { file = nil; url = nil } }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings,
                                    commonFormat: pcmBuffer.format.commonFormat, interleaved: pcmBuffer.format.isInterleaved)
        }
        try? file?.write(from: pcmBuffer)
    }
}

// MARK: - Dispositivos

enum AVDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    /// El mismo micrófono para la sala (LiveKit usa sus propios identificadores).
    static func useForRoom(_ mic: AVCaptureDevice) {
        let list = AudioManager.shared.inputDevices
        if let d = list.first(where: { $0.deviceId == mic.uniqueID }) ?? list.first(where: { $0.name == mic.localizedName }) {
            AudioManager.shared.inputDevice = d
        }
    }

    /// ¿Parece que el sonido sale por audífonos? (Bluetooth, USB de auriculares, o el conector de audífonos)
    static var headphonesLikely: Bool {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn {
            var source = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            addr.mSelector = kAudioDevicePropertyDataSource
            addr.mScope = kAudioDevicePropertyScopeOutput
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr {
                return source == 0x6864706E   // 'hdpn' = audífonos en el conector
            }
            return false
        }
        // USB u otros: por el nombre
        var name: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioObjectPropertyName
        addr.mScope = kAudioObjectPropertyScopeGlobal
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        let n = (name as String).lowercased()
        return ["headphone", "headset", "auricular", "audífono", "audifono", "airpods", "buds", "beats"].contains { n.contains($0) }
    }
}
