import Foundation

/// Behaviour switches exposed in the editor's Options/Advanced sections.
/// Defaults are what a non-technical user should get.
public struct RsyncOptions: Codable, Hashable, Sendable {
    /// Compare file contents instead of size + modification time (`--checksum`). Slower.
    public var compareByChecksum: Bool
    /// Compress data in transit (`--compress`). Useful over slow networks only.
    public var compress: Bool
    /// Bandwidth cap in KiB/s (`--bwlimit`).
    public var bandwidthLimitKBps: Int?
    /// Extended attributes: Finder tags, resource forks, quarantine flags (`--xattrs`).
    public var preserveExtendedAttributes: Bool
    /// File creation dates (`--crtimes`), when the rsync binary supports it.
    public var preserveCreationDates: Bool
    /// Access control lists (`--acls`).
    public var preserveACLs: Bool
    /// Hard links (`--hard-links`).
    public var preserveHardLinks: Bool
    /// Keep partially transferred files so interrupted big transfers resume (`--partial`).
    public var keepPartialFiles: Bool
    /// Don't overwrite files that are newer at the destination (`--update`).
    public var skipNewerAtDestination: Bool
    /// Don't cross into other mounted volumes (`--one-file-system`).
    public var stayOnOneFileSystem: Bool
    /// Also delete excluded files at the destination in Mirror mode (`--delete-excluded`).
    public var deleteExcluded: Bool
    /// Move replaced/deleted files into this folder instead of discarding them
    /// (`--backup --backup-dir`). Relative paths are relative to the destination.
    public var backupDirectory: String?
    /// Raw arguments appended verbatim, one per element.
    public var extraArguments: [String]

    public init(
        compareByChecksum: Bool = false,
        compress: Bool = false,
        bandwidthLimitKBps: Int? = nil,
        preserveExtendedAttributes: Bool = true,
        preserveCreationDates: Bool = true,
        preserveACLs: Bool = false,
        preserveHardLinks: Bool = false,
        keepPartialFiles: Bool = false,
        skipNewerAtDestination: Bool = false,
        stayOnOneFileSystem: Bool = false,
        deleteExcluded: Bool = false,
        backupDirectory: String? = nil,
        extraArguments: [String] = []
    ) {
        self.compareByChecksum = compareByChecksum
        self.compress = compress
        self.bandwidthLimitKBps = bandwidthLimitKBps
        self.preserveExtendedAttributes = preserveExtendedAttributes
        self.preserveCreationDates = preserveCreationDates
        self.preserveACLs = preserveACLs
        self.preserveHardLinks = preserveHardLinks
        self.keepPartialFiles = keepPartialFiles
        self.skipNewerAtDestination = skipNewerAtDestination
        self.stayOnOneFileSystem = stayOnOneFileSystem
        self.deleteExcluded = deleteExcluded
        self.backupDirectory = backupDirectory
        self.extraArguments = extraArguments
    }
}
