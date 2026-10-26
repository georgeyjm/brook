import Foundation
import ProcessSupport
import RsyncCore
import SyncModel

/// Checks that a server is reachable, that we can sign in without a prompt, and which
/// rsync it has.
public enum ConnectionTester {
    public enum Outcome: Sendable, Equatable {
        case success(remoteRsync: String)
        /// Connected, but the server's rsync is missing or too old to work well.
        case warning(String)
        case failure(Diagnosis)
    }

    public static func test(_ host: RemoteHost, sshExecutable: String = "/usr/bin/ssh") async -> Outcome {
        var arguments: [String] = []
        if let port = host.port, port != 22 { arguments += ["-p", String(port)] }
        if let identity = host.identityFile, !identity.isEmpty {
            arguments += ["-i", (identity as NSString).expandingTildeInPath]
        }
        for option in host.sshOptions where !option.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-o", option.trimmingCharacters(in: .whitespaces)]
        }
        arguments += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host.sshTarget]
        let remoteRsync = host.remoteRsyncPath?.trimmingCharacters(in: .whitespaces)
        arguments += [(remoteRsync?.isEmpty == false ? remoteRsync! : "rsync") + " --version"]

        let result: CommandResult
        do {
            result = try await CommandRunner.run(URL(filePath: sshExecutable), arguments: arguments, timeout: .seconds(20))
        } catch {
            return .failure(Diagnosis(severity: .failure, title: "Couldn't start ssh.", detail: "\(error)", exitCode: -1))
        }

        if result.timedOut {
            return .failure(Diagnosis(severity: .failure, title: "The server didn't respond.", fixIt: .checkServerAddress, exitCode: -1))
        }
        let errorLines = result.stderr.split(whereSeparator: \.isNewline).map(String.init)
        guard result.exitCode == 0 else {
            // 127 from the remote shell means the command (rsync) wasn't found.
            if result.exitCode == 127 {
                return .failure(Diagnosis(severity: .failure, title: "rsync isn't installed on the server.",
                                          detail: errorLines.first, fixIt: .installRemoteRsync, exitCode: 127))
            }
            return .failure(ErrorTranslator.diagnose(exitCode: result.exitCode == 0 ? 255 : result.exitCode, stderr: errorLines)
                ?? Diagnosis(severity: .failure, title: "Couldn't connect to the server.", exitCode: result.exitCode))
        }

        let caps = RsyncCapabilities.parse(versionOutput: result.stdout)
        let version = caps.version?.description ?? "unknown version"
        if caps.isOpenRsync {
            return .warning("Connected, but the server has openrsync (\(version)-compatible). Some options may not work; installing rsync 3 on the server is recommended.")
        }
        if let v = caps.version, v < RsyncVersion(3, 0, 0) {
            return .warning("Connected, but the server's rsync \(version) is very old. Installing rsync 3 is recommended.")
        }
        return .success(remoteRsync: "rsync \(version)")
    }
}
