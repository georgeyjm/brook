import Foundation
import SyncModel

/// Something that stops a run, or needs the user's OK first.
public struct PreflightIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case sourceMissing
        case sourceNotFolder
        case volumeNotConnected(name: String)
        /// A different drive is mounted where the expected one used to be.
        case wrongVolume(expected: String)
        case emptySourceMirror
        case firstMirrorNeedsPreview
        case tooManyDeletions(count: Int, fraction: Double)
    }

    public var kind: Kind
    public var side: Side
    public var message: String

    public enum Side: String, Hashable, Sendable { case source, destination, both }

    /// Blocking issues can't be overridden; the rest can be confirmed by the user.
    public var confirmation: Confirmation? {
        switch kind {
        case .emptySourceMirror: .emptySourceMirror
        case .firstMirrorNeedsPreview: .firstMirror
        case .tooManyDeletions: .largeDeletion
        default: nil
        }
    }
}

/// Issues a user can explicitly accept for one run.
public enum Confirmation: String, Hashable, Sendable, Codable {
    case emptySourceMirror
    case firstMirror
    case largeDeletion
}

public enum Preflight {
    /// Checks that only look at the local file system (remote endpoints are verified by rsync itself).
    public static func check(
        job: SyncJob,
        kind: RunKind,
        hasPreviewedOrSynced: Bool,
        volumes: VolumeInspecting = SystemVolumes()
    ) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []

        for (endpoint, side) in [(job.source, PreflightIssue.Side.source), (job.destination, .destination)] {
            guard case .local(let path, let identity) = endpoint else { continue }
            if let issue = volumeIssue(path: path, identity: identity, side: side, volumes: volumes) {
                issues.append(issue)
            }
        }
        // Without the drive there's nothing more we can usefully check.
        if !issues.isEmpty { return issues }

        if case .local(let path, _) = job.source {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                issues.append(PreflightIssue(kind: .sourceMissing, side: .source, message: "The source folder “\(displayName(path))” doesn't exist."))
                return issues
            }
            if !isDirectory.boolValue && !job.copyFolderItself {
                issues.append(PreflightIssue(kind: .sourceNotFolder, side: .source, message: "“\(displayName(path))” is a file, not a folder."))
                return issues
            }
            if job.mode == .mirror && isDirectory.boolValue && isEffectivelyEmpty(path) {
                issues.append(PreflightIssue(
                    kind: .emptySourceMirror, side: .source,
                    message: "“\(displayName(path))” is empty. Mirroring it would delete everything at the destination."
                ))
            }
        }

        if kind == .sync, job.mode == .mirror, job.safety.requirePreviewBeforeFirstMirror, !hasPreviewedOrSynced {
            issues.append(PreflightIssue(
                kind: .firstMirrorNeedsPreview, side: .destination,
                message: "This is the first time this mirror runs. Preview it first to see what would be deleted."
            ))
        }
        return issues
    }

    static func volumeIssue(path: String, identity: VolumeIdentity?, side: PreflightIssue.Side, volumes: VolumeInspecting) -> PreflightIssue? {
        let label = side == .source ? "source" : "destination"
        if let identity {
            guard path.hasPrefix(identity.mountPath) else { return nil }
            guard let mountedUUID = volumes.uuid(ofVolumeMountedAt: identity.mountPath) else {
                return PreflightIssue(kind: .volumeNotConnected(name: identity.name), side: side,
                                      message: "The \(label) drive “\(identity.name)” isn't connected.")
            }
            if mountedUUID != identity.uuid {
                return PreflightIssue(kind: .wrongVolume(expected: identity.name), side: side,
                                      message: "A different drive is connected as “\(identity.name)”. Connect the original \(label) drive or choose the folder again.")
            }
            return nil
        }
        // No recorded identity: still catch "/Volumes/Name" not being mounted, so rsync doesn't
        // silently create that folder on the startup disk.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.count >= 2, components[0] == "Volumes" {
            let mountPath = "/Volumes/\(components[1])"
            if volumes.uuid(ofVolumeMountedAt: mountPath) == nil && !volumes.isMountPoint(mountPath) {
                return PreflightIssue(kind: .volumeNotConnected(name: String(components[1])), side: side,
                                      message: "The \(label) drive “\(components[1])” isn't connected.")
            }
        }
        return nil
    }

    static func isEffectivelyEmpty(_ path: String) -> Bool {
        let ignorable: Set<String> = [".DS_Store", ".localized"]
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return contents.allSatisfy(ignorable.contains)
    }

    static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    public static let minimumDeletionsForFractionRule = 10

    /// Evaluates the deletion guard against a dry run's results.
    public static func deletionIssue(summary: ChangeSummary, stats: TransferStats?, safety: SafetySettings) -> PreflightIssue? {
        let deleted = stats?.deletedFiles ?? summary.deleted
        guard safety.deletionGuardEnabled, deleted > 0 else { return nil }
        // Files at the destination ≈ (source files − newly created) + files only at the destination.
        let total = stats?.totalFiles ?? 0
        let created = stats?.createdFiles ?? (summary.added + summary.foldersCreated)
        let destinationCount = max(1, total - created + deleted)
        let fraction = Double(deleted) / Double(destinationCount)

        // The percentage rule ignores a handful of deletions, so tidying a small folder never nags.
        let overFraction = deleted >= minimumDeletionsForFractionRule && fraction > safety.maxDeletedFraction
        guard deleted > safety.maxDeletedFiles || overFraction else { return nil }
        let percent = Int((fraction * 100).rounded())
        return PreflightIssue(
            kind: .tooManyDeletions(count: deleted, fraction: fraction), side: .destination,
            message: "This sync would delete \(deleted.formatted()) item\(deleted == 1 ? "" : "s") (\(percent)% of the destination)."
        )
    }
}

// MARK: - Volumes

public protocol VolumeInspecting: Sendable {
    func uuid(ofVolumeMountedAt mountPath: String) -> String?
    func isMountPoint(_ path: String) -> Bool
}

public struct SystemVolumes: VolumeInspecting {
    public init() {}

    public func uuid(ofVolumeMountedAt mountPath: String) -> String? {
        let url = URL(filePath: mountPath, directoryHint: .isDirectory)
        guard isMountPoint(mountPath),
              let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]) else { return nil }
        return values.volumeUUIDString
    }

    public func isMountPoint(_ path: String) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let target = URL(filePath: path).standardizedFileURL.path
        return mounted.contains { $0.standardizedFileURL.path == target }
    }

    /// The identity to store when a user picks a folder; `nil` for the startup disk.
    public static func identity(forPath path: String) -> VolumeIdentity? {
        let url = URL(filePath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey, .volumeIsRootFileSystemKey]),
              values.volumeIsRootFileSystem != true,
              let volumeURL = values.volume,
              let uuid = values.volumeUUIDString else { return nil }
        return VolumeIdentity(uuid: uuid, name: values.volumeName ?? volumeURL.lastPathComponent, mountPath: volumeURL.path)
    }
}
