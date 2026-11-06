import Foundation
import AppKit
import UserNotifications

/// A job in the export queue: they're processed one after another, in the background,
/// without blocking the app. When all are done, a system notification.
struct ExportJob: Identifiable, Equatable {
    enum Kind: Equatable {
        case format(ExportFormat)
        case reels
        case stems
        var title: String {
            switch self {
            case .format(let f): return f.title
            case .reels: return String(localized: "Reels")
            case .stems: return String(localized: "Pistas por separado (WAV)")
            }
        }
        var symbol: String {
            switch self {
            case .format(let f): return f == .audio ? "waveform" : "film"
            case .reels: return "rectangle.portrait.on.rectangle.portrait"
            case .stems: return "square.stack.3d.down.right"
            }
        }
    }
    enum Status: Equatable {
        case waiting, running, done([URL]), failed(String)
        var isFinished: Bool { if case .waiting = self { return false }; if case .running = self { return false }; return true }
    }
    let id = UUID()
    let kind: Kind
    var status: Status = .waiting
    var title: String { kind.title }
    var files: [URL] { if case .done(let u) = status { return u }; return [] }
}

@MainActor
extension ProjectSession {

    /// Adds a job to the end of the queue and starts processing if it isn't running.
    /// If an identical one is already waiting, it isn't duplicated.
    @discardableResult
    func enqueue(_ kind: ExportJob.Kind) -> Bool {
        if exportQueue.contains(where: { $0.kind == kind && !$0.status.isFinished }) { return false }
        exportQueue.append(ExportJob(kind: kind))
        processExportQueue()
        return true
    }

    /// Everything usually needed to publish: YouTube, MP3 and the marked reels.
    func enqueueAll() {
        enqueue(.format(.landscape))
        enqueue(.format(.audio))
        if project.reels.contains(where: \.selected) { enqueue(.reels) }
    }

    func removeFromQueue(_ id: UUID) {
        exportQueue.removeAll { $0.id == id && $0.status != .running }
    }

    func clearFinishedExports() {
        exportQueue.removeAll { $0.status.isFinished }
    }

    var queuePending: Int { exportQueue.filter { !$0.status.isFinished }.count }

    private func setQueueStatus(_ id: UUID, _ s: ExportJob.Status) {
        if let i = exportQueue.firstIndex(where: { $0.id == id }) { exportQueue[i].status = s }
    }

    /// Processes the queue one at a time. Waits for any other app job to finish (fix,
    /// transcribe…) before starting the next, so two things aren't exported at once.
    func processExportQueue() {
        guard exportQueueTask == nil else { return }
        exportQueueTask = Task { [self] in
            defer { exportQueueTask = nil }
            var produced: [URL] = []
            var failures = 0
            while let next = exportQueue.first(where: { $0.status == .waiting }) {
                while job != nil {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                }
                guard exportQueue.contains(where: { $0.id == next.id }) else { continue }   // removed while it was waiting
                setQueueStatus(next.id, .running)
                let runner = exportQueueRunner ?? { [self] kind in try await self.runQueuedExport(kind) }
                let t = Task<[URL], Error> { try await runner(next.kind) }
                startQueueJob(title: String(localized: "En cola: \(next.title)"), task: t)
                do {
                    let urls = try await t.value
                    produced += urls
                    setQueueStatus(next.id, .done(urls))
                } catch is CancellationError {
                    setQueueStatus(next.id, .failed(String(localized: "Cancelado")))
                    // Cancelling the running job also empties what was waiting: that way "Cancel" means stop.
                    exportQueue.removeAll { $0.status == .waiting }
                } catch {
                    failures += 1
                    setQueueStatus(next.id, .failed(error.localizedDescription))
                }
                endQueueJob()
            }
            refreshExports()
            if !produced.isEmpty || failures > 0 { notifyQueueFinished(files: produced.count, failures: failures) }
            if let last = produced.last, exportQueueRunner == nil { NSWorkspace.shared.activateFileViewerSelecting([last]) }
        }
    }

    private func runQueuedExport(_ kind: ExportJob.Kind) async throws -> [URL] {
        switch kind {
        case .format(let f): return [try await performExport(format: f)]
        case .reels: return try await performExportReels()
        case .stems:
            try await ensureEnergy()
            player.pause()
            let folder = try await Exporter.exportStems(project: project, energy: energy) { [weak self] f in
                self?.queueProgress(String(localized: "Pistas por separado"), f)
            }
            return [folder]
        }
    }

    nonisolated func queueProgress(_ title: String, _ f: Double) {
        Task { @MainActor in self.job = JobState(title: String(localized: "En cola: \(title)"), detail: self.queueDetail, fraction: f) }
    }

    var queueDetail: String {
        let left = exportQueue.filter { $0.status == .waiting }.count
        return left == 0 ? "" : (left == 1 ? String(localized: "1 más esperando") : String(localized: "\(left) más esperando"))
    }

    // MARK: Notification when done

    func notifyQueueFinished(files: Int, failures: Int) {
        guard Bundle.main.bundleIdentifier != nil, exportQueueRunner == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = failures == 0 ? String(localized: "Exportación lista") : String(localized: "Exportación terminada con problemas")
            c.body = files == 1 ? String(localized: "1 archivo listo.") : String(localized: "\(files) archivos listos.") + (failures > 0 ? String(localized: " \(failures) no se pudieron exportar.") : "")
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "export-queue-\(Date().timeIntervalSince1970)", content: c, trigger: nil))
        }
    }
}
