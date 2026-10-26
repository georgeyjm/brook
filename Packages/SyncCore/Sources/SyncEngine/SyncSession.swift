import Foundation
import ProcessSupport
import RsyncCore
import SyncModel
import SyncStore

public struct RunRequest: Sendable {
    public var job: SyncJob
    public var hosts: [RemoteHost]
    public var kind: RunKind
    public var trigger: RunTrigger
    /// Issues the user has explicitly accepted for this run.
    public var confirmations: Set<Confirmation>
    /// Whether this job has completed a preview or sync before (for the first-mirror check).
    public var hasPreviewedOrSynced: Bool

    public init(
        job: SyncJob,
        hosts: [RemoteHost],
        kind: RunKind,
        trigger: RunTrigger = .manual,
        confirmations: Set<Confirmation> = [],
        hasPreviewedOrSynced: Bool = false
    ) {
        self.job = job
        self.hosts = hosts
        self.kind = kind
        self.trigger = trigger
        self.confirmations = confirmations
        self.hasPreviewedOrSynced = hasPreviewedOrSynced
    }

    /// Scheduled runs can't ask questions.
    public var isUnattended: Bool { trigger != .manual }
}

public enum SessionPhase: String, Sendable {
    case checking
    case runningBeforeHook
    case estimatingDeletions
    case transferring
    case runningAfterHook
}

public enum SessionEvent: Sendable {
    case phase(SessionPhase)
    case progress(TransferProgress)
    case change(FileChange)
    case line(String, isError: Bool)
    case finished(SessionResult)
}

public struct SessionResult: Sendable {
    public var record: RunRecord
    public var diagnosis: Diagnosis?
    /// Set when the run didn't start because the user needs to confirm something.
    public var needsConfirmation: PreflightIssue?
    /// Itemized changes (previews keep up to `SyncSession.maxRetainedChanges`).
    public var changes: [FileChange]
    public var changesTruncated: Bool

    public init(record: RunRecord, diagnosis: Diagnosis?, needsConfirmation: PreflightIssue?, changes: [FileChange], changesTruncated: Bool) {
        self.record = record
        self.diagnosis = diagnosis
        self.needsConfirmation = needsConfirmation
        self.changes = changes
        self.changesTruncated = changesTruncated
    }
}

/// Runs one preview or sync end to end: preflight → before hook → deletion estimate →
/// rsync → after hook → history.
public final class SyncSession: @unchecked Sendable {
    public static let maxRetainedChanges = 100_000

    public let request: RunRequest
    public let binary: RsyncBinary
    private let history: HistoryStore?
    private let volumes: VolumeInspecting

    private let lock = NSLock()
    private var currentProcess: RsyncProcess?
    private var stopRequested = false
    private var task: Task<Void, Never>?

    public init(request: RunRequest, binary: RsyncBinary, history: HistoryStore?, volumes: VolumeInspecting = SystemVolumes()) {
        self.request = request
        self.binary = binary
        self.history = history
        self.volumes = volumes
    }

    public func start() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        task = Task { [self] in
            let result = await run(emit: { continuation.yield($0) })
            continuation.yield(.finished(result))
            continuation.finish()
        }
        return stream
    }

    public func stop() {
        let process = lock.withLock {
            stopRequested = true
            return currentProcess
        }
        process?.stop()
    }

    public func pause() { lock.withLock { currentProcess }?.pause() }
    public func resume() { lock.withLock { currentProcess }?.resume() }

    private var isStopRequested: Bool { lock.withLock { stopRequested } }

    // MARK: - Flow

    private func run(emit: @Sendable (SessionEvent) -> Void) async -> SessionResult {
        let job = request.job
        var record = RunRecord(jobID: job.id, kind: request.kind, trigger: request.trigger)
        record.logFileName = "\(record.id.uuidString).log"
        let log = LogWriter(handle: try? history?.openLog(for: record))
        defer { log.close() }

        func finish(_ outcome: RunOutcome, message: String? = nil, diagnosis: Diagnosis? = nil,
                    confirmation: PreflightIssue? = nil, changes: [FileChange] = [], truncated: Bool = false) -> SessionResult {
            record.outcome = outcome
            record.finishedAt = Date()
            record.message = message ?? record.message
            if confirmation == nil { try? history?.save(record) }
            return SessionResult(record: record, diagnosis: diagnosis, needsConfirmation: confirmation,
                                 changes: changes, changesTruncated: truncated)
        }

        // 1. Preflight
        emit(.phase(.checking))
        let issues = Preflight.check(job: job, kind: request.kind, hasPreviewedOrSynced: request.hasPreviewedOrSynced, volumes: volumes)
        for issue in issues {
            log.write("[preflight] \(issue.message)")
            guard let confirmation = issue.confirmation else { return finish(.skipped, message: issue.message) }
            guard request.confirmations.contains(confirmation) else {
                return request.isUnattended
                    ? finish(.skipped, message: issue.message)
                    : finish(.skipped, message: issue.message, confirmation: issue)
            }
        }

        // 2. Before hook
        if request.kind == .sync, let script = job.hooks.beforeRun, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit(.phase(.runningBeforeHook))
            let result = await runHook(script, exitCode: nil, log: log, emit: emit)
            if !result.succeeded && job.hooks.abortIfBeforeRunFails {
                return finish(.failed, message: "The “before sync” command failed (exit code \(result.exitCode)), so the sync didn't run.")
            }
        }
        if isStopRequested { return finish(.cancelled) }

        // 3. Deletion guard (needs a dry run to know how much would be deleted)
        var maxDelete: Int?
        if request.kind == .sync, job.mode == .mirror, job.safety.deletionGuardEnabled,
           !request.confirmations.contains(.largeDeletion) {
            emit(.phase(.estimatingDeletions))
            let estimate = await runRsync(purpose: .preview, maxDelete: nil, log: log, emit: { event in
                if case .line(let line, let isError) = event, isError { emit(.line(line, isError: true)) }
            })
            if estimate.completion.wasStopped || isStopRequested { return finish(.cancelled) }
            if let diagnosis = estimate.completion.diagnosis, diagnosis.severity == .failure {
                record.exitCode = estimate.completion.exitCode
                return finish(.failed, message: diagnosis.title, diagnosis: diagnosis)
            }
            if let issue = Preflight.deletionIssue(summary: estimate.completion.summary, stats: estimate.completion.stats, safety: job.safety) {
                log.write("[guard] \(issue.message)")
                return request.isUnattended
                    ? finish(.skipped, message: issue.message + " Scheduled runs skip this; run it manually to confirm.")
                    : finish(.skipped, message: issue.message, confirmation: issue)
            }
            maxDelete = job.safety.maxDeletedFiles
        }

        // 4. Transfer
        emit(.phase(.transferring))
        let retainChanges = request.kind == .preview
        let outcome = await runRsync(
            purpose: request.kind == .preview ? .preview : .sync,
            maxDelete: maxDelete,
            log: log,
            retainChanges: retainChanges,
            emit: emit
        )
        if let buildError = outcome.buildError {
            return finish(.failed, message: buildError)
        }
        let completion = outcome.completion
        record.exitCode = completion.exitCode
        record.summary = completion.summary
        record.stats = completion.stats

        var finalOutcome: RunOutcome
        let diagnosis = completion.diagnosis
        if completion.wasStopped || isStopRequested {
            finalOutcome = .cancelled
        } else if let diagnosis {
            finalOutcome = diagnosis.severity == .warning ? .warning : .failed
            record.message = diagnosis.title
        } else {
            finalOutcome = .success
        }

        // 5. After hook (runs even after failures; it receives the exit code)
        if request.kind == .sync, finalOutcome != .cancelled,
           let script = job.hooks.afterRun, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emit(.phase(.runningAfterHook))
            let result = await runHook(script, exitCode: completion.exitCode, log: log, emit: emit)
            if !result.succeeded {
                let note = "The “after sync” command failed (exit code \(result.exitCode))."
                record.message = [record.message, note].compactMap { $0 }.joined(separator: " ")
                if finalOutcome == .success { finalOutcome = .warning }
            }
        }

        return finish(finalOutcome, diagnosis: diagnosis, changes: outcome.changes, truncated: outcome.truncated)
    }

    // MARK: - rsync

    private struct RsyncOutcome {
        var completion: RsyncCompletion
        var changes: [FileChange] = []
        var truncated = false
        var buildError: String?
    }

    private func runRsync(
        purpose: CommandBuilder.Purpose,
        maxDelete: Int?,
        log: LogWriter,
        retainChanges: Bool = false,
        emit: @Sendable (SessionEvent) -> Void
    ) async -> RsyncOutcome {
        let failed = RsyncCompletion(exitCode: -1, wasStopped: false, summary: ChangeSummary(), stats: nil, errorLines: [])
        let context = CommandBuilder.Context(
            hosts: request.hosts,
            capabilities: binary.capabilities,
            purpose: purpose,
            unattended: request.isUnattended,
            maxDelete: maxDelete
        )

        let arguments: [String]
        do {
            arguments = try CommandBuilder.arguments(for: request.job, context: context)
        } catch {
            let message = Self.describe(error)
            log.write("[error] \(message)")
            return RsyncOutcome(completion: failed, buildError: message)
        }

        log.write("$ " + CommandBuilder.displayString(executable: binary.url.path, arguments: arguments))
        let process = RsyncProcess(executable: binary.url, arguments: arguments)
        let shouldStart = lock.withLock { () -> Bool in
            guard !stopRequested else { return false }
            currentProcess = process
            return true
        }
        guard shouldStart else {
            return RsyncOutcome(completion: RsyncCompletion(exitCode: 20, wasStopped: true, summary: ChangeSummary(), stats: nil, errorLines: []))
        }
        defer { lock.withLock { currentProcess = nil } }

        let events: AsyncStream<RsyncEvent>
        do {
            events = try process.start()
        } catch {
            let message = "Couldn't start rsync at \(binary.url.path)."
            log.write("[error] \(message) \(error)")
            return RsyncOutcome(completion: failed, buildError: message)
        }

        var outcome = RsyncOutcome(completion: failed)
        for await event in events {
            switch event {
            case .progress(let progress):
                emit(.progress(progress))
            case .change(let change):
                if retainChanges {
                    if outcome.changes.count < Self.maxRetainedChanges { outcome.changes.append(change) } else { outcome.truncated = true }
                }
                emit(.change(change))
            case .line(let line, let isError):
                log.write(isError ? "[stderr] \(line)" : line)
                emit(.line(line, isError: isError))
            case .finished(let completion):
                outcome.completion = completion
                log.write("[exit] \(completion.exitCode)\(completion.wasStopped ? " (stopped)" : "")")
            }
        }
        return outcome
    }

    static func describe(_ error: Error) -> String {
        switch error as? CommandBuilder.BuildError {
        case .emptyPath(let side)?: "Choose a \(side.rawValue) folder."
        case .relativeLocalPath(let side)?: "The \(side.rawValue) must be a full path starting with “/”."
        case .unknownHost(let side)?: "The server for the \(side.rawValue) no longer exists. Choose it again."
        case .remoteToRemote?: "Syncing between two servers isn't supported. One side must be on this Mac."
        case .unquotableSSHArgument(let arg)?: "An SSH setting contains both kinds of quotes and can't be used: \(arg)"
        case nil: error.localizedDescription
        }
    }

    // MARK: - Hooks

    private func runHook(_ script: String, exitCode: Int32?, log: LogWriter, emit: @Sendable (SessionEvent) -> Void) async -> CommandResult {
        let job = request.job
        var environment = [
            "SYNC_NAME": job.name,
            "SYNC_ID": job.id.uuidString,
            "SYNC_SOURCE": job.source.path,
            "SYNC_DESTINATION": job.destination.path,
            "SYNC_KIND": request.kind.rawValue,
            "SYNC_TRIGGER": request.trigger.rawValue,
        ]
        if let exitCode { environment["SYNC_EXIT_CODE"] = String(exitCode) }

        log.write("$ [hook] \(script)")
        let result: CommandResult
        do {
            result = try await CommandRunner.run(URL(filePath: "/bin/zsh"), arguments: ["-c", script],
                                                 environment: environment, timeout: .seconds(15 * 60))
        } catch {
            log.write("[hook] couldn't start: \(error)")
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            log.write("[hook] \(line)")
            emit(.line(String(line), isError: false))
        }
        for line in result.stderr.split(whereSeparator: \.isNewline) {
            log.write("[hook:stderr] \(line)")
            emit(.line(String(line), isError: true))
        }
        if result.timedOut { log.write("[hook] timed out") }
        log.write("[hook] exit \(result.exitCode)")
        return result
    }
}

/// Appends lines to a run's log file. Safe to call with a nil handle.
final class LogWriter: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(handle: FileHandle?) { self.handle = handle }

    func write(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        lock.withLock { try? handle.write(contentsOf: data) }
    }

    func close() {
        lock.withLock { try? handle?.close() }
    }
}
