import Foundation

/// A plain-language explanation of why a run didn't fully succeed, with an optional fix.
public struct Diagnosis: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        /// Finished, with something worth knowing.
        case warning
        case failure
    }

    public enum FixIt: String, Hashable, Sendable {
        case grantFullDiskAccess
        case trustHostKey
        case setUpSSHKey
        case checkServerAddress
        case installRemoteRsync
        case chooseRsyncBinary
        case freeUpSpace
        case reviewDeletions
        case reviewExtraArguments
    }

    public var severity: Severity
    public var title: String
    public var detail: String?
    public var fixIt: FixIt?
    public var exitCode: Int32

    public init(severity: Severity, title: String, detail: String? = nil, fixIt: FixIt? = nil, exitCode: Int32) {
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fixIt = fixIt
        self.exitCode = exitCode
    }
}

/// Maps rsync/ssh exit codes and stderr into `Diagnosis` values a non-expert can act on.
public enum ErrorTranslator {
    /// rsync's exit code when `--max-delete` stopped deletions.
    public static let maxDeleteExitCode: Int32 = 25

    public static func diagnose(exitCode: Int32, stderr: [String]) -> Diagnosis? {
        guard exitCode != 0 else { return nil }
        let detail = mostRelevantLine(stderr)
        let text = stderr.joined(separator: "\n").lowercased()

        func make(_ severity: Diagnosis.Severity, _ title: String, _ fixIt: Diagnosis.FixIt? = nil) -> Diagnosis {
            Diagnosis(severity: severity, title: title, detail: detail, fixIt: fixIt, exitCode: exitCode)
        }

        // Specific stderr patterns are more helpful than exit codes, so check them first.
        if text.contains("remote host identification has changed") {
            return make(.failure, "The server's identity has changed since you last connected. This can mean it was reinstalled, or that someone is intercepting the connection.")
        }
        if text.contains("host key verification failed") {
            return make(.failure, "This server isn't trusted yet.", .trustHostKey)
        }
        if text.contains("permission denied (publickey") || text.contains("permission denied, please try again")
            || text.contains("too many authentication failures") {
            return make(.failure, "Couldn't sign in to the server.", .setUpSSHKey)
        }
        if text.contains("could not resolve hostname") {
            return make(.failure, "Couldn't find the server. Check the address and your network connection.", .checkServerAddress)
        }
        if text.contains("connection refused") {
            return make(.failure, "The server refused the connection. Check that SSH (Remote Login) is turned on and the port is right.", .checkServerAddress)
        }
        if text.contains("operation timed out") || text.contains("connection timed out") {
            return make(.failure, "The server didn't respond.", .checkServerAddress)
        }
        if text.contains("rsync: command not found") || text.contains("rsync: not found")
            || (text.contains("sh:") && text.contains("rsync") && text.contains("not found")) {
            return make(.failure, "rsync isn't installed on the server.", .installRemoteRsync)
        }
        if text.contains("protocol version mismatch") || text.contains("protocol incompatibility") {
            return make(.failure, "This Mac and the server have incompatible versions of rsync.", .installRemoteRsync)
        }
        if text.contains("no space left on device") || text.contains("disk quota exceeded") {
            return make(.failure, "The destination is full.", .freeUpSpace)
        }
        if text.contains("read-only file system") {
            return make(.failure, "The destination is read-only.")
        }
        if text.contains("change_dir") && text.contains("[sender]") && text.contains("no such file or directory") {
            return make(.failure, "The source folder doesn't exist.")
        }

        switch exitCode {
        case 23:
            if text.contains("operation not permitted") {
                return make(.warning, "macOS blocked access to some files.", .grantFullDiskAccess)
            }
            return make(.warning, "Some files couldn't be copied.")
        case 24:
            return make(.warning, "Some files disappeared while syncing. This is normal for folders that are in use.")
        case maxDeleteExitCode:
            return make(.failure, "Stopped before deleting more files than your safety limit allows.", .reviewDeletions)
        case 1:
            return make(.failure, "rsync didn't accept one of the options.", .reviewExtraArguments)
        case 2:
            return make(.failure, "This Mac and the server have incompatible versions of rsync.", .installRemoteRsync)
        case 3:
            return make(.failure, "The source or destination folder couldn't be opened.")
        case 4:
            return make(.failure, "An option isn't supported by this rsync or file system.", .chooseRsyncBinary)
        case 5:
            return make(.failure, "Couldn't start talking to the server's rsync.", .installRemoteRsync)
        case 10, 12:
            return make(.failure, "The connection was interrupted.")
        case 11:
            return make(.failure, "A file couldn't be read or written.")
        case 20:
            return make(.failure, "The sync was stopped.")
        case 30, 35:
            return make(.failure, "The transfer timed out.")
        case 255:
            return make(.failure, "Couldn't connect to the server.", .checkServerAddress)
        default:
            return make(.failure, "rsync stopped with error code \(exitCode).")
        }
    }

    /// The first line that names a cause, rather than rsync's generic trailer.
    static func mostRelevantLine(_ stderr: [String]) -> String? {
        let candidates = stderr.filter { !$0.hasPrefix("rsync error:") && !$0.contains("connection unexpectedly closed") }
        return (candidates.first ?? stderr.first)?.trimmingCharacters(in: .whitespaces)
    }
}
