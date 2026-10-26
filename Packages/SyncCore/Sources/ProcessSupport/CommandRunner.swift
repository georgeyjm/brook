import Foundation

/// Captured result of a short-lived command.
public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum CommandRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// Runs short helper commands (`rsync --version`, `ssh … true`, `ssh-keygen`) and captures output.
/// Long-running transfers use `RsyncProcess` instead, which streams.
public enum CommandRunner {
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, toStdout: true)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData, toStdout: false)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                collector.markFinished()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain anything left after the handlers were removed.
                collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
                collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: false)
                let (out, err, timedOut) = collector.snapshot()
                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    timedOut: timedOut
                ))
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
                return
            }

            if let stdin { inPipe.fileHandleForWriting.write(stdin) }
            try? inPipe.fileHandleForWriting.close()

            let pid = process.processIdentifier
            Task.detached {
                try? await Task.sleep(for: timeout)
                if collector.markTimedOutIfRunning() {
                    kill(pid, SIGTERM)
                }
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false
    private var finished = false

    func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.withLock {
            if toStdout { stdout.append(data) } else { stderr.append(data) }
        }
    }

    func markFinished() { lock.withLock { finished = true } }

    /// Returns `true` if the process was still running and is now flagged as timed out.
    func markTimedOutIfRunning() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            timedOut = true
            return true
        }
    }

    func snapshot() -> (Data, Data, Bool) { lock.withLock { (stdout, stderr, timedOut) } }
}
