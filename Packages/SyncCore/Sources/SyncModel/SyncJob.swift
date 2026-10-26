import Foundation

/// One saved sync: "copy *this* to *there*, this way, on this schedule".
public struct SyncJob: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// SF Symbol name shown on the sync's card.
    public var symbol: String
    public var tint: SyncTint
    public var groupID: UUID?

    public var source: Endpoint
    public var destination: Endpoint
    public var mode: SyncMode
    /// `true` copies the source folder itself into the destination (`src` → `dst/src/…`);
    /// `false` copies only what's inside it (`src/` → `dst/…`). Hides rsync's trailing-slash rule.
    public var copyFolderItself: Bool

    public var options: RsyncOptions
    public var filters: [FilterRule]
    public var schedule: JobSchedule?
    public var hooks: Hooks
    public var safety: SafetySettings
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "folder",
        tint: SyncTint = .blue,
        groupID: UUID? = nil,
        source: Endpoint,
        destination: Endpoint,
        mode: SyncMode = .copy,
        copyFolderItself: Bool = true,
        options: RsyncOptions = RsyncOptions(),
        filters: [FilterRule] = [],
        schedule: JobSchedule? = nil,
        hooks: Hooks = Hooks(),
        safety: SafetySettings = SafetySettings(),
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.groupID = groupID
        self.source = source
        self.destination = destination
        self.mode = mode
        self.copyFolderItself = copyFolderItself
        self.options = options
        self.filters = filters
        self.schedule = schedule
        self.hooks = hooks
        self.safety = safety
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

public enum SyncMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Add new and changed files; never delete anything at the destination.
    case copy
    /// Make the destination identical to the source, deleting extra files (`--delete`).
    case mirror

    public var canDelete: Bool { self == .mirror }
}

public enum SyncTint: String, Codable, Hashable, Sendable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray
}

public struct SyncGroup: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// An ordered include/exclude rule, passed to rsync in the order given.
public struct FilterRule: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case exclude, include
    }

    public var id: UUID
    public var kind: Kind
    public var pattern: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind = .exclude, pattern: String, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.isEnabled = isEnabled
    }

    /// Common junk users usually don't want copied.
    public static let presets: [(title: String, pattern: String)] = [
        ("Finder metadata (.DS_Store)", ".DS_Store"),
        ("Spotlight index", ".Spotlight-V100"),
        ("Trash", ".Trashes"),
        ("Caches", "Caches/"),
        ("Node modules", "node_modules/"),
        ("Git repositories", ".git/"),
        ("Temporary files", "*.tmp"),
    ]
}

/// Shell commands run before and after a sync (power-user feature).
public struct Hooks: Codable, Hashable, Sendable {
    public var beforeRun: String?
    public var afterRun: String?
    /// If the before-run command exits non-zero, don't sync.
    public var abortIfBeforeRunFails: Bool

    public init(beforeRun: String? = nil, afterRun: String? = nil, abortIfBeforeRunFails: Bool = true) {
        self.beforeRun = beforeRun
        self.afterRun = afterRun
        self.abortIfBeforeRunFails = abortIfBeforeRunFails
    }
}

public struct SafetySettings: Codable, Hashable, Sendable {
    /// Ask before a Mirror run deletes a lot. Unattended runs are skipped instead.
    public var deletionGuardEnabled: Bool
    public var maxDeletedFiles: Int
    /// 0...1 fraction of the destination's files.
    public var maxDeletedFraction: Double
    /// Require a preview before the first Mirror run.
    public var requirePreviewBeforeFirstMirror: Bool

    public init(
        deletionGuardEnabled: Bool = true,
        maxDeletedFiles: Int = 500,
        maxDeletedFraction: Double = 0.2,
        requirePreviewBeforeFirstMirror: Bool = true
    ) {
        self.deletionGuardEnabled = deletionGuardEnabled
        self.maxDeletedFiles = maxDeletedFiles
        self.maxDeletedFraction = maxDeletedFraction
        self.requirePreviewBeforeFirstMirror = requirePreviewBeforeFirstMirror
    }
}
