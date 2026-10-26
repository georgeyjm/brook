import Foundation
import SyncModel

public enum RsyncEvent: Sendable {
    case progress(TransferProgress)
    case change(FileChange)
    /// Every non-progress output line, for the live log and the saved log file.
    case line(String, isError: Bool)
    case finished(RsyncCompletion)
}

public struct RsyncCompletion: Sendable {
    public var exitCode: Int32
    /// `true` when the user (or the app) stopped the run.
    public var wasStopped: Bool
    public var summary: ChangeSummary
    public var stats: TransferStats?
    /// Last stderr lines, for diagnosis.
    public var errorLines: [String]

    public init(exitCode: Int32, wasStopped: Bool, summary: ChangeSummary, stats: TransferStats?, errorLines: [String]) {
        self.exitCode = exitCode
        self.wasStopped = wasStopped
        self.summary = summary
        self.stats = stats
        self.errorLines = errorLines
    }

    public var diagnosis: Diagnosis? {
        wasStopped ? nil : ErrorTranslator.diagnose(exitCode: exitCode, stderr: errorLines)
    }
}

public enum RsyncProcessError: Error, Sendable {
    case launchFailed(String)
    case alreadyStarted
}

/// Runs one rsync invocation and streams parsed events.
///
/// Stop sends SIGTERM (then SIGKILL after a grace period); pause/resume use SIGSTOP/SIGCONT.
public final class RsyncProcess: @unchecked Sendable {
    public let executable: URL
    public let arguments: [String]

    private let process = Process()
    private let lock = NSLock()
    private var state = State()
    private var continuation: AsyncStream<RsyncEvent>.Continuation?

    private struct State {
        var started = false
        var stdoutSplitter = LineSplitter()
        var stderrSplitter = LineSplitter()
        var summary = ChangeSummary()
        var statsLines: [String] = []
        var errorLines: [String] = []
        var stdoutClosed = false
        var stderrClosed = false
        var exitCode: Int32?
        var wasStopped = false
        var isPaused = false
        var finished = false
    }

    private static let maxErrorLines = 200

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Launches rsync. The returned stream ends after `.finished`.
    public func start() throws(RsyncProcessError) -> AsyncStream<RsyncEvent> {
        let alreadyStarted = lock.withLock {
            defer { state.started = true }
            return state.started
        }
        if alreadyStarted { throw .alreadyStarted }

        let (stream, continuation) = AsyncStream<RsyncEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // The handlers hold `self` strongly on purpose: the stream must finish even if the
        // caller drops its reference. The cycle is broken when each handler is cleared.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self.consume(data, isError: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self.consume(data, isError: true)
        }
        process.terminationHandler = { process in
            process.terminationHandler = nil
            self.processExited(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw .launchFailed(error.localizedDescription)
        }
        return stream
    }

    public func stop() {
        let pid = process.processIdentifier
        let shouldSignal = lock.withLock { () -> Bool in
            guard state.started, state.exitCode == nil else { return false }
            state.wasStopped = true
            return true
        }
        guard shouldSignal, pid > 0 else { return }
        kill(pid, SIGCONT)  // a paused process can't handle SIGTERM
        kill(pid, SIGTERM)
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.lock.withLock({ self.state.exitCode == nil }) else { return }
            kill(pid, SIGKILL)
        }
    }

    public func pause() { signal(SIGSTOP, paused: true) }
    public func resume() { signal(SIGCONT, paused: false) }

    public var isPaused: Bool { lock.withLock { state.isPaused } }

    private func signal(_ sig: Int32, paused: Bool) {
        let pid = process.processIdentifier
        let shouldSignal = lock.withLock { () -> Bool in
            guard state.started, state.exitCode == nil, pid > 0 else { return false }
            state.isPaused = paused
            return true
        }
        if shouldSignal { kill(pid, sig) }
    }

    // MARK: - Output handling

    private func consume(_ data: Data, isError: Bool) {
        var events: [RsyncEvent] = []
        lock.withLock {
            var lines: [String]
            if data.isEmpty {
                lines = []
                if let rest = isError ? state.stderrSplitter.flush() : state.stdoutSplitter.flush() { lines.append(rest) }
                if isError { state.stderrClosed = true } else { state.stdoutClosed = true }
            } else {
                lines = isError ? state.stderrSplitter.append(data) : state.stdoutSplitter.append(data)
            }

            for line in lines {
                if isError {
                    state.errorLines.append(line)
                    if state.errorLines.count > Self.maxErrorLines { state.errorLines.removeFirst() }
                    events.append(.line(line, isError: true))
                } else if let progress = ProgressParser.parse(line) {
                    events.append(.progress(progress))
                } else if let change = ItemizeParser.parse(line) {
                    state.summary.record(change)
                    events.append(.change(change))
                    events.append(.line(line, isError: false))
                } else {
                    state.statsLines.append(line)
                    if state.statsLines.count > 400 { state.statsLines.removeFirst() }
                    events.append(.line(line, isError: false))
                }
            }
        }
        for event in events { continuation?.yield(event) }
        finishIfDone()
    }

    private func processExited(status: Int32) {
        lock.withLock { state.exitCode = status }
        finishIfDone()
    }

    private func finishIfDone() {
        let completion: RsyncCompletion? = lock.withLock {
            guard !state.finished, state.stdoutClosed, state.stderrClosed, let exitCode = state.exitCode else { return nil }
            state.finished = true
            return RsyncCompletion(
                exitCode: exitCode,
                wasStopped: state.wasStopped,
                summary: state.summary,
                stats: StatsParser.parse(state.statsLines),
                errorLines: state.errorLines
            )
        }
        guard let completion else { return }
        continuation?.yield(.finished(completion))
        continuation?.finish()
    }
}
