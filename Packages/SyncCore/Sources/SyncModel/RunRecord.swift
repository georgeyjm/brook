import Foundation

/// The persisted result of one preview or sync.
public struct RunRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var jobID: UUID
    public var kind: RunKind
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: RunOutcome
    public var exitCode: Int32?
    public var summary: ChangeSummary
    public var stats: TransferStats?
    /// One plain-language sentence explaining a warning/failure/skip.
    public var message: String?
    /// File name of the raw log inside the job's history folder.
    public var logFileName: String?

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        kind: RunKind,
        trigger: RunTrigger,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: RunOutcome = .running,
        exitCode: Int32? = nil,
        summary: ChangeSummary = ChangeSummary(),
        stats: TransferStats? = nil,
        message: String? = nil,
        logFileName: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.exitCode = exitCode
        self.summary = summary
        self.stats = stats
        self.message = message
        self.logFileName = logFileName
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

public enum RunKind: String, Codable, Hashable, Sendable {
    /// Dry run: shows what would change.
    case preview
    case sync
}

public enum RunTrigger: String, Codable, Hashable, Sendable {
    case manual, scheduled, catchUp
}

public enum RunOutcome: String, Codable, Hashable, Sendable {
    case running
    case success
    /// Finished, but something minor happened (e.g. files vanished mid-run).
    case warning
    case failed
    case cancelled
    /// Didn't run: a safety check stopped it (drive missing, too many deletions…).
    case skipped
}

/// Per-category counts derived from `--itemize-changes`.
public struct ChangeSummary: Codable, Hashable, Sendable {
    public var added: Int
    public var updated: Int
    public var deleted: Int
    /// Only permissions/times/etc. changed.
    public var metadataOnly: Int
    public var foldersCreated: Int

    public init(added: Int = 0, updated: Int = 0, deleted: Int = 0, metadataOnly: Int = 0, foldersCreated: Int = 0) {
        self.added = added
        self.updated = updated
        self.deleted = deleted
        self.metadataOnly = metadataOnly
        self.foldersCreated = foldersCreated
    }

    public var isEmpty: Bool { added == 0 && updated == 0 && deleted == 0 && metadataOnly == 0 && foldersCreated == 0 }

    public mutating func record(_ change: FileChange) {
        switch (change.kind, change.itemType) {
        case (.added, .directory): foldersCreated += 1
        case (.added, _): added += 1
        case (.updated, _): updated += 1
        case (.deleted, _): deleted += 1
        case (.metadata, .directory): break  // every touched folder reports this; it's noise
        case (.metadata, _): metadataOnly += 1
        }
    }
}

/// One line of `--itemize-changes` output, decoded.
public struct FileChange: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case added, updated, deleted, metadata
    }

    public enum ItemType: String, Codable, Hashable, Sendable {
        case file, directory, symlink, device, special, unknown
    }

    public var kind: Kind
    public var itemType: ItemType
    /// Path relative to the transfer root, unescaped.
    public var path: String
    public var linkTarget: String?

    public init(kind: Kind, itemType: ItemType, path: String, linkTarget: String? = nil) {
        self.kind = kind
        self.itemType = itemType
        self.path = path
        self.linkTarget = linkTarget
    }
}

/// Parsed `--stats` block.
public struct TransferStats: Codable, Hashable, Sendable {
    public var totalFiles: Int?
    public var createdFiles: Int?
    public var deletedFiles: Int?
    public var transferredFiles: Int?
    public var totalSize: Int64?
    public var transferredSize: Int64?
    public var literalData: Int64?
    public var matchedData: Int64?
    public var bytesSent: Int64?
    public var bytesReceived: Int64?
    public var speedup: Double?

    public init(
        totalFiles: Int? = nil,
        createdFiles: Int? = nil,
        deletedFiles: Int? = nil,
        transferredFiles: Int? = nil,
        totalSize: Int64? = nil,
        transferredSize: Int64? = nil,
        literalData: Int64? = nil,
        matchedData: Int64? = nil,
        bytesSent: Int64? = nil,
        bytesReceived: Int64? = nil,
        speedup: Double? = nil
    ) {
        self.totalFiles = totalFiles
        self.createdFiles = createdFiles
        self.deletedFiles = deletedFiles
        self.transferredFiles = transferredFiles
        self.totalSize = totalSize
        self.transferredSize = transferredSize
        self.literalData = literalData
        self.matchedData = matchedData
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.speedup = speedup
    }
}
