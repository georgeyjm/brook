import AppKit
import Foundation
import Observation
import RsyncCore
import SyncEngine
import SyncModel

/// Live state of one running (or just finished) preview/sync, observed by the UI.
@Observable @MainActor
final class LiveRun: Identifiable {
    struct LogLine: Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    let id = UUID()
    let jobID: UUID
    let kind: RunKind
    let trigger: RunTrigger
    let startedAt = Date()

    var phase: SessionPhase = .checking
    var progress: TransferProgress?
    var latestChange: FileChange?
    var summary = ChangeSummary()
    var changes: [FileChange] = []
    var changesTruncated = false
    var logLines: [LogLine] = []
    var isPaused = false
    var result: SessionResult?

    private var nextLineID = 0
    static let maxLogLines = 800
    static let maxLiveChanges = 50_000

    init(jobID: UUID, kind: RunKind, trigger: RunTrigger) {
        self.jobID = jobID
        self.kind = kind
        self.trigger = trigger
    }

    var isRunning: Bool { result == nil }

    func appendLine(_ text: String, isError: Bool) {
        logLines.append(LogLine(id: nextLineID, text: text, isError: isError))
        nextLineID += 1
        if logLines.count > Self.maxLogLines { logLines.removeFirst(logLines.count - Self.maxLogLines) }
    }

    func record(_ change: FileChange) {
        summary.record(change)
        latestChange = change
        if changes.count < Self.maxLiveChanges { changes.append(change) } else { changesTruncated = true }
    }
}

/// A run that stopped to ask the user something (e.g. "this would delete 2,000 files").
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let jobID: UUID
    let kind: RunKind
    let issue: PreflightIssue
    let alreadyConfirmed: Set<Confirmation>
}

/// Starts, tracks and stops runs. One run per sync at a time; runs that share a
/// destination wait for each other.
@Observable @MainActor
final class RunCoordinator {
    private(set) var live: [UUID: LiveRun] = [:]
    var pendingConfirmation: PendingConfirmation?

    private var sessions: [UUID: SyncSession] = [:]
    private var queued: [(job: SyncJob, kind: RunKind, trigger: RunTrigger, confirmations: Set<Confirmation>)] = []
    private var sleepAssertion: NSObjectProtocol?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func liveRun(for jobID: UUID) -> LiveRun? { live[jobID] }
    func isRunning(_ jobID: UUID) -> Bool { live[jobID]?.isRunning == true }
    var runningCount: Int { live.values.filter(\.isRunning).count }
    var isAnyRunning: Bool { runningCount > 0 }

    func start(_ jobID: UUID, kind: RunKind, trigger: RunTrigger = .manual, confirmations: Set<Confirmation> = []) {
        guard let model, let job = model.job(id: jobID), !isRunning(jobID) else { return }
        if queued.contains(where: { $0.job.id == jobID }) { return }

        if sharesDestinationWithRunningJob(job) {
            queued.append((job, kind, trigger, confirmations))
            let waiting = LiveRun(jobID: jobID, kind: kind, trigger: trigger)
            waiting.appendLine("Waiting for another sync to the same destination to finish…", isError: false)
            live[jobID] = waiting
            return
        }
        launch(job, kind: kind, trigger: trigger, confirmations: confirmations)
    }

    func stop(_ jobID: UUID) {
        if let index = queued.firstIndex(where: { $0.job.id == jobID }) {
            queued.remove(at: index)
            live[jobID] = nil
            return
        }
        sessions[jobID]?.stop()
    }

    func togglePause(_ jobID: UUID) {
        guard let run = live[jobID], let session = sessions[jobID] else { return }
        if run.isPaused { session.resume() } else { session.pause() }
        run.isPaused.toggle()
    }

    func dismiss(_ jobID: UUID) {
        guard live[jobID]?.isRunning == false else { return }
        live[jobID] = nil
    }

    func stopAll() {
        queued.removeAll()
        for session in sessions.values { session.stop() }
    }

    /// Re-run after the user accepted a confirmation.
    func confirm(_ pending: PendingConfirmation) {
        pendingConfirmation = nil
        var confirmations = pending.alreadyConfirmed
        if let confirmation = pending.issue.confirmation { confirmations.insert(confirmation) }
        live[pending.jobID] = nil
        start(pending.jobID, kind: pending.kind, confirmations: confirmations)
    }

    // MARK: - Private

    private func launch(_ job: SyncJob, kind: RunKind, trigger: RunTrigger, confirmations: Set<Confirmation>) {
        guard let model else { return }
        let run = LiveRun(jobID: job.id, kind: kind, trigger: trigger)
        live[job.id] = run

        guard let binary = model.rsync else {
            run.appendLine("No usable rsync was found. Choose one in Settings.", isError: true)
            run.result = SessionResult(
                record: RunRecord(jobID: job.id, kind: kind, trigger: trigger, finishedAt: Date(), outcome: .failed,
                                  message: "No usable rsync was found. Choose one in Settings."),
                diagnosis: nil, needsConfirmation: nil, changes: [], changesTruncated: false
            )
            return
        }

        let request = RunRequest(
            job: job,
            hosts: model.hosts,
            kind: kind,
            trigger: trigger,
            confirmations: confirmations,
            hasPreviewedOrSynced: model.hasPreviewedOrSynced(job.id)
        )
        let session = SyncSession(request: request, binary: binary, history: model.history)
        sessions[job.id] = session
        updateSleepAssertion()

        let stream = session.start()
        Task { @MainActor [weak self] in
            for await event in stream {
                switch event {
                case .phase(let phase): run.phase = phase
                case .progress(let progress): run.progress = progress
                case .change(let change): run.record(change)
                case .line(let line, let isError): run.appendLine(line, isError: isError)
                case .finished(let result): self?.finished(run, job: job, result: result, confirmations: confirmations)
                }
            }
        }
    }

    private func finished(_ run: LiveRun, job: SyncJob, result: SessionResult, confirmations: Set<Confirmation>) {
        run.result = result
        if result.changes.count > run.changes.count {
            run.changes = result.changes
            run.changesTruncated = result.changesTruncated
        }
        sessions[job.id] = nil
        updateSleepAssertion()
        model?.historyDidChange(for: job.id)

        if let issue = result.needsConfirmation {
            live[job.id] = nil
            pendingConfirmation = PendingConfirmation(jobID: job.id, kind: run.kind, issue: issue, alreadyConfirmed: confirmations)
            NSApp.requestUserAttention(.informationalRequest)
        } else {
            NotificationService.shared.notify(record: result.record, jobName: job.name, diagnosis: result.diagnosis)
        }

        startQueuedRuns()
    }

    private func startQueuedRuns() {
        var remaining: [(job: SyncJob, kind: RunKind, trigger: RunTrigger, confirmations: Set<Confirmation>)] = []
        for item in queued {
            if sharesDestinationWithRunningJob(item.job) {
                remaining.append(item)
            } else {
                live[item.job.id] = nil
                launch(item.job, kind: item.kind, trigger: item.trigger, confirmations: item.confirmations)
            }
        }
        queued = remaining
    }

    private func sharesDestinationWithRunningJob(_ job: SyncJob) -> Bool {
        sessions.keys.compactMap { model?.job(id: $0) }.contains { other in
            other.id != job.id && other.destination.hostID == job.destination.hostID
                && Self.overlaps(other.destination.path, job.destination.path)
        }
    }

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.hasSuffix("/") ? a : a + "/"
        let b = b.hasSuffix("/") ? b : b + "/"
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Keep the Mac awake while anything is syncing.
    private func updateSleepAssertion() {
        if !sessions.isEmpty, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Syncing files"
            )
        } else if sessions.isEmpty, let assertion = sleepAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            sleepAssertion = nil
        }
    }
}
