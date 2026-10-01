import AVFoundation
import Foundation

/// Texto a voz con las voces de la Mac (sin internet). Escribe un archivo de audio listo para ponerlo en el episodio.
enum Speech {
    struct Voice: Identifiable, Hashable {
        let id: String          // identificador de AVSpeechSynthesisVoice
        let name: String
        let language: String
        let quality: String     // "mejorada" | "premium" | ""
    }

    /// Voces en español primero (la Mac trae varias; las mejoradas se bajan en Ajustes del Sistema → Accesibilidad → Contenido hablado).
    static func voices() -> [Voice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        func q(_ v: AVSpeechSynthesisVoice) -> String {
            switch v.quality { case .premium: return "premium"; case .enhanced: return "mejorada"; default: return "" }
        }
        let es = all.filter { $0.language.hasPrefix("es") }
        let rest = all.filter { !$0.language.hasPrefix("es") && ($0.language.hasPrefix("en") || $0.language.hasPrefix("pt")) }
        return (es + rest).map { Voice(id: $0.identifier, name: $0.name, language: $0.language, quality: q($0)) }
    }

    /// Voz por defecto: la mejor en español que haya.
    static func defaultVoice() -> Voice? {
        let v = voices()
        // Primero la mejor calidad; a igual calidad, español de América (es-MX) antes que es-ES
        let es = v.filter { $0.language.hasPrefix("es") }
        for q in ["premium", "mejorada", ""] {
            if let m = es.first(where: { $0.quality == q && $0.language == "es-MX" }) ?? es.first(where: { $0.quality == q }) { return m }
        }
        return v.first
    }

    /// Genera `text` con `voice` en un .caf (PCM) en `url`. `rate` 0.3…0.7 (0.5 = normal).
    static func synthesize(_ text: String, voice: Voice?, rate: Float = 0.5, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let job = Job()
        try await job.run(text: text, voiceId: voice?.id, rate: rate, url: url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "thePod.speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "La Mac no generó audio para ese texto. Prueba otra voz."])
        }
    }

    /// Mantiene vivo el sintetizador hasta que avisa que terminó (el callback de `write` no siempre manda el búfer vacío final).
    private final class Job: NSObject, AVSpeechSynthesizerDelegate {
        private let synth = AVSpeechSynthesizer()
        private var file: AVAudioFile?
        private var failure: Error?
        private var cont: CheckedContinuation<Void, Error>?
        private var finished = false

        func run(text: String, voiceId: String?, rate: Float, url: URL) async throws {
            let utterance = AVSpeechUtterance(string: text)
            if let voiceId, let v = AVSpeechSynthesisVoice(identifier: voiceId) { utterance.voice = v }
            else { utterance.voice = AVSpeechSynthesisVoice(language: "es-MX") ?? AVSpeechSynthesisVoice(language: "es-ES") }
            utterance.rate = max(0.2, min(0.8, rate))
            utterance.prefersAssistiveTechnologySettings = false
            synth.delegate = self
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                cont = c
                synth.write(utterance) { [weak self] buffer in
                    guard let self, !self.finished else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 { self.finish(); return }
                    do {
                        if self.file == nil {
                            self.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                        commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                        }
                        try self.file?.write(from: pcm)
                    } catch { self.failure = error }
                }
                // Por si la voz nunca avisa que terminó: 2 s por cada 10 palabras, mínimo 20 s
                let words = max(1, text.split(separator: " ").count)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(20, Double(words) * 0.2 + 5)) { [weak self] in
                    self?.finish(timeout: true)
                }
            }
        }

        private func finish(timeout: Bool = false) {
            guard !finished else { return }
            finished = true
            file = nil
            synth.delegate = nil
            if timeout && failure == nil {
                failure = NSError(domain: "thePod.speech", code: 2, userInfo: [NSLocalizedDescriptionKey: "La voz tardó demasiado. Prueba con un texto más corto u otra voz."])
            }
            if let failure { cont?.resume(throwing: failure) } else { cont?.resume() }
            cont = nil
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
    }
}
