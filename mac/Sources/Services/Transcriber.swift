import Foundation
import WhisperKit

/// On-device transcription with WhisperKit (CoreML on the Neural Engine). Produces postPod-style
/// word timestamps. Each lane (person) is transcribed separately, so every word knows who said it.
actor Transcriber {
    static let shared = Transcriber()
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var pipe: WhisperKit?
    private var loadedModel: String?

    var modelName: String {
        UserDefaults.standard.string(forKey: "whisperModel") ?? Self.defaultModel
    }

    static var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("postPod/whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func load(status: @escaping @Sendable (String) -> Void) async throws -> WhisperKit {
        let model = modelName
        if let pipe, loadedModel == model { return pipe }
        status("Preparando el modelo de voz (la primera vez se descarga, ~600 MB)…")
        let config = WhisperKitConfig(model: model, downloadBase: Self.modelsFolder, verbose: false,
                                      logLevel: .error, prewarm: true, load: true, download: true)
        let kit = try await WhisperKit(config)
        pipe = kit
        loadedModel = model
        return kit
    }

    /// Transcribes one 16 kHz WAV. Returned word times are in SOURCE time of that audio.
    func transcribe(wav: URL, language: String,
                    status: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        let kit = try await load(status: status)
        status("Escuchando y escribiendo…")
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let progressTask = Task {
            while !Task.isCancelled {
                progress(kit.progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { progressTask.cancel() }
        let results = try await kit.transcribe(audioPath: wav.path, decodeOptions: options)
        var words: [Word] = []
        for r in results {
            for seg in r.segments {
                for w in seg.words ?? [] {
                    let text = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                    words.append(Word(w: text, s: Double(w.start), e: Double(max(w.end, w.start + 0.05)), p: Double(w.probability)))
                }
            }
        }
        return words.sorted { $0.s < $1.s }
    }
}
