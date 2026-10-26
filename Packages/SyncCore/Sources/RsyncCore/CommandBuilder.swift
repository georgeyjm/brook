import Foundation
import SyncModel

/// Turns a `SyncJob` into rsync arguments. This is the single source of truth for both
/// execution and the command preview shown in the editor.
///
/// It always produces an argument array and never a shell string, so paths and patterns
/// can't inject commands.
public enum CommandBuilder {
    public enum Purpose: Sendable {
        case sync
        /// `--dry-run`
        case preview
    }

    public struct Context: Sendable {
        public var hosts: [RemoteHost]
        public var capabilities: RsyncCapabilities
        public var purpose: Purpose
        /// Scheduled runs: never prompt (ssh `BatchMode`).
        public var unattended: Bool
        /// Hard cap on deletions (`--max-delete`); set by the engine's deletion guard.
        public var maxDelete: Int?
        public var sshExecutable: String
        /// Used to expand `~` in local paths.
        public var homeDirectory: String

        public init(
            hosts: [RemoteHost] = [],
            capabilities: RsyncCapabilities = .assumedModern,
            purpose: Purpose = .sync,
            unattended: Bool = false,
            maxDelete: Int? = nil,
            sshExecutable: String = "/usr/bin/ssh",
            homeDirectory: String = NSHomeDirectory()
        ) {
            self.hosts = hosts
            self.capabilities = capabilities
            self.purpose = purpose
            self.unattended = unattended
            self.maxDelete = maxDelete
            self.sshExecutable = sshExecutable
            self.homeDirectory = homeDirectory
        }
    }

    public enum Side: String, Sendable { case source, destination }

    public enum BuildError: Error, Equatable, Sendable {
        case emptyPath(Side)
        case relativeLocalPath(Side)
        case unknownHost(Side)
        case remoteToRemote
        case unquotableSSHArgument(String)
    }

    // MARK: - Arguments

    public static func arguments(for job: SyncJob, context: Context) throws(BuildError) -> [String] {
        if job.source.isRemote && job.destination.isRemote { throw .remoteToRemote }

        let caps = context.capabilities
        let options = job.options
        var args: [String] = ["--archive"]

        if caps.supportsInfoFlags {
            args += ["--8-bit-output", "--itemize-changes", "--stats", "--info=progress2"]
        } else {
            args += ["--itemize-changes", "--stats"]
        }

        if context.purpose == .preview { args.append("--dry-run") }

        if job.mode == .mirror {
            args.append("--delete")
            if options.deleteExcluded { args.append("--delete-excluded") }
            if let maxDelete = context.maxDelete { args.append("--max-delete=\(max(0, maxDelete))") }
        }

        if options.compareByChecksum { args.append("--checksum") }
        if options.compress { args.append("--compress") }
        if let limit = options.bandwidthLimitKBps, limit > 0 { args.append("--bwlimit=\(limit)") }
        if options.preserveExtendedAttributes && caps.supportsExtendedAttributes { args.append("--xattrs") }
        if options.preserveCreationDates && caps.supportsCreationTimes { args.append("--crtimes") }
        if options.preserveACLs && caps.supportsACLs { args.append("--acls") }
        if options.preserveHardLinks { args.append("--hard-links") }
        if options.keepPartialFiles { args.append("--partial") }
        if options.skipNewerAtDestination { args.append("--update") }
        if options.stayOnOneFileSystem { args.append("--one-file-system") }
        if let backupDir = options.backupDirectory?.trimmingCharacters(in: .whitespaces), !backupDir.isEmpty {
            args += ["--backup", "--backup-dir=\(backupDir)"]
        }

        for rule in job.filters where rule.isEnabled && !rule.pattern.isEmpty {
            switch rule.kind {
            case .include: args.append("--include=\(rule.pattern)")
            case .exclude: args.append("--exclude=\(rule.pattern)")
            }
        }

        let remoteHost: RemoteHost?
        if let hostID = job.source.hostID ?? job.destination.hostID {
            let side: Side = job.source.isRemote ? .source : .destination
            guard let host = context.hosts.first(where: { $0.id == hostID }) else { throw .unknownHost(side) }
            remoteHost = host
            args.append("--rsh=\(try sshCommand(for: host, context: context))")
            if let rsyncPath = host.remoteRsyncPath?.trimmingCharacters(in: .whitespaces), !rsyncPath.isEmpty {
                args.append("--rsync-path=\(rsyncPath)")
            }
            if caps.needsExplicitProtectArgs { args.append("--protect-args") }
        } else {
            remoteHost = nil
        }

        args += options.extraArguments.filter { !$0.isEmpty }

        args.append(try location(job.source, side: .source, host: remoteHost, job: job, context: context))
        args.append(try location(job.destination, side: .destination, host: remoteHost, job: job, context: context))
        return args
    }

    /// The `--rsh` value. rsync splits it on spaces and honours single/double quotes (no backslashes).
    public static func sshCommand(for host: RemoteHost, context: Context) throws(BuildError) -> String {
        var parts = [context.sshExecutable]
        if let port = host.port, port != 22 { parts += ["-p", String(port)] }
        if let identity = host.identityFile, !identity.isEmpty {
            parts += ["-i", expandTilde(identity, home: context.homeDirectory)]
        }
        for option in host.sshOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            parts += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }
        if !host.sshOptions.contains(where: { $0.lowercased().hasPrefix("connecttimeout") }) {
            parts += ["-o", "ConnectTimeout=20"]
        }
        if context.unattended { parts += ["-o", "BatchMode=yes"] }
        return try parts.map { (part: String) throws(BuildError) -> String in try rshQuote(part) }.joined(separator: " ")
    }

    // MARK: - Paths

    static func location(_ endpoint: Endpoint, side: Side, host: RemoteHost?, job: SyncJob, context: Context) throws(BuildError) -> String {
        var path = endpoint.path.trimmingCharacters(in: .whitespacesAndNewlines)

        switch endpoint {
        case .local:
            guard !path.isEmpty else { throw .emptyPath(side) }
            path = expandTilde(path, home: context.homeDirectory)
            guard path.hasPrefix("/") else { throw .relativeLocalPath(side) }
        case .remote:
            // An empty remote path means the login user's home directory.
            break
        }

        path = shapeTrailingSlash(path, side: side, copyFolderItself: job.copyFolderItself)

        switch endpoint {
        case .local: return path
        case .remote: return "\(host?.sshTarget ?? ""):\(path)"
        }
    }

    /// Source: "copy the folder itself" → no trailing slash; "copy what's inside" → trailing slash.
    /// Destination: always a directory, so always a trailing slash.
    static func shapeTrailingSlash(_ path: String, side: Side, copyFolderItself: Bool) -> String {
        if path.isEmpty { return path }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "/" }
        if side == .source && copyFolderItself { return trimmed }
        return trimmed + "/"
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func rshQuote(_ arg: String) throws(BuildError) -> String {
        let needsQuoting = arg.isEmpty || arg.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" || $0 == "\t" })
        guard needsQuoting else { return arg }
        if !arg.contains("'") { return "'\(arg)'" }
        if !arg.contains("\"") { return "\"\(arg)\"" }
        throw .unquotableSSHArgument(arg)
    }

    // MARK: - Presentation

    /// Where files will end up, for the editor's live explanation
    /// ("Files will end up in /Volumes/Backup/Photos/…").
    public static func landingPath(for job: SyncJob) -> String {
        var destination = job.destination.path
        while destination.count > 1 && destination.hasSuffix("/") { destination.removeLast() }
        guard job.copyFolderItself else { return destination }
        var source = job.source.path
        while source.count > 1 && source.hasSuffix("/") { source.removeLast() }
        let folderName = (source as NSString).lastPathComponent
        guard !folderName.isEmpty, folderName != "/" else { return destination }
        return destination == "/" ? "/\(folderName)" : "\(destination)/\(folderName)"
    }

    /// Shell-quoted command line for display and "Copy command".
    public static func displayString(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+%")
        if !arg.isEmpty && arg.unicodeScalars.allSatisfy(safe.contains) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
