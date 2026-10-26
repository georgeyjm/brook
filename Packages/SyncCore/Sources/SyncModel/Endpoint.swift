import Foundation

/// Where files come from or go to.
public enum Endpoint: Codable, Hashable, Sendable {
    /// A folder on this Mac. `volume` is recorded for paths on external drives so we can
    /// tell "drive not connected" apart from "empty folder".
    case local(path: String, volume: VolumeIdentity?)
    /// A folder on a saved `RemoteHost`, reached over SSH.
    case remote(hostID: UUID, path: String)

    public static func local(_ path: String) -> Endpoint { .local(path: path, volume: nil) }

    public var path: String {
        switch self {
        case .local(let path, _), .remote(_, let path): path
        }
    }

    public var isRemote: Bool {
        if case .remote = self { true } else { false }
    }

    public var hostID: UUID? {
        if case .remote(let id, _) = self { id } else { nil }
    }

    public func withPath(_ newPath: String) -> Endpoint {
        switch self {
        case .local(_, let volume): .local(path: newPath, volume: volume)
        case .remote(let hostID, _): .remote(hostID: hostID, path: newPath)
        }
    }
}

/// Identifies a mounted volume independently of its mount point name.
public struct VolumeIdentity: Codable, Hashable, Sendable {
    public var uuid: String
    public var name: String
    /// e.g. `/Volumes/Backup`
    public var mountPath: String

    public init(uuid: String, name: String, mountPath: String) {
        self.uuid = uuid
        self.name = name
        self.mountPath = mountPath
    }
}

/// A saved SSH destination.
public struct RemoteHost: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Display name, e.g. "Home NAS".
    public var name: String
    /// Hostname, IP, or a `Host` alias from `~/.ssh/config`.
    public var hostname: String
    public var user: String?
    public var port: Int?
    /// Path to a private key; `nil` lets ssh pick (agent, config, defaults).
    public var identityFile: String?
    /// Extra `-o Key=Value` style options, one per element (e.g. `ProxyJump=bastion`).
    public var sshOptions: [String]
    /// `--rsync-path` on the remote, e.g. `/usr/local/bin/rsync` or `sudo rsync`.
    public var remoteRsyncPath: String?

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        remoteRsyncPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.remoteRsyncPath = remoteRsyncPath
    }

    /// `user@host` or just `host`.
    public var sshTarget: String {
        if let user, !user.isEmpty { "\(user)@\(hostname)" } else { hostname }
    }
}
