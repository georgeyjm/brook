import Foundation
import SyncModel

/// Run history on disk:
/// ```
/// History/<jobID>/<runID>.json   – RunRecord
/// History/<jobID>/<runID>.log    – raw rsync output
/// ```
public struct HistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func jobDirectory(_ jobID: UUID) -> URL {
        directory.appending(path: jobID.uuidString, directoryHint: .isDirectory)
    }

    public func recordURL(for record: RunRecord) -> URL {
        jobDirectory(record.jobID).appending(path: "\(record.id.uuidString).json")
    }

    public func logURL(for record: RunRecord) -> URL {
        jobDirectory(record.jobID).appending(path: record.logFileName ?? "\(record.id.uuidString).log")
    }

    public func save(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: jobDirectory(record.jobID), withIntermediateDirectories: true)
        try JSONCoding.makeEncoder().encode(record).write(to: recordURL(for: record), options: .atomic)
    }

    /// Creates (or truncates) the log file for a run and returns a handle for appending.
    public func openLog(for record: RunRecord) throws -> FileHandle {
        try FileManager.default.createDirectory(at: jobDirectory(record.jobID), withIntermediateDirectories: true)
        let url = logURL(for: record)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    /// Newest first.
    public func records(for jobID: UUID) -> [RunRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: jobDirectory(jobID), includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONCoding.makeDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RunRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Newest first, across all jobs.
    public func allRecords(limit: Int? = nil) -> [RunRecord] {
        let fm = FileManager.default
        guard let jobDirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let all = jobDirs
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .flatMap(records(for:))
            .sorted { $0.startedAt > $1.startedAt }
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    public func latest(for jobID: UUID, kind: RunKind? = nil) -> RunRecord? {
        records(for: jobID).first { kind == nil || $0.kind == kind }
    }

    /// Keeps the newest `keep` records per job and drops anything older than `maxAge`.
    public func prune(jobID: UUID, keep: Int, maxAge: TimeInterval? = nil, now: Date = Date()) {
        let fm = FileManager.default
        for (index, record) in records(for: jobID).enumerated() {
            let tooOld = maxAge.map { now.timeIntervalSince(record.startedAt) > $0 } ?? false
            if index >= keep || tooOld {
                try? fm.removeItem(at: recordURL(for: record))
                try? fm.removeItem(at: logURL(for: record))
            }
        }
    }

    public func deleteHistory(for jobID: UUID) {
        try? FileManager.default.removeItem(at: jobDirectory(jobID))
    }

    /// Marks runs left as `.running` by a crash or force-quit as failed.
    public func repairInterruptedRuns(now: Date = Date()) {
        for var record in allRecords() where record.outcome == .running {
            record.outcome = .failed
            record.finishedAt = record.finishedAt ?? now
            record.message = "The app quit before this run finished."
            try? save(record)
        }
    }
}
