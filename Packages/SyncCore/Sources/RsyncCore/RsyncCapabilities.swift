import Foundation

public struct RsyncVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "3.4.1", "3.2.7pre1", "2.6.9".
    public init?(string: String) {
        let parts = string.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
        guard parts.count >= 2 else { return nil }
        self.init(parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    public static func < (lhs: RsyncVersion, rhs: RsyncVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// What a particular rsync binary can do, parsed from `rsync --version`.
public struct RsyncCapabilities: Hashable, Sendable {
    public var version: RsyncVersion?
    public var protocolVersion: Int?
    /// Apple's BSD reimplementation shipped as `/usr/bin/rsync` since macOS 15.
    public var isOpenRsync: Bool
    /// Entries from the "Capabilities:" section, e.g. "xattrs", "ACLs", "crtimes".
    public var features: Set<String>

    public init(version: RsyncVersion?, protocolVersion: Int?, isOpenRsync: Bool, features: Set<String>) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.isOpenRsync = isOpenRsync
        self.features = features
    }

    /// Used for command previews before a binary has been probed.
    public static let assumedModern = RsyncCapabilities(
        version: RsyncVersion(3, 4, 0),
        protocolVersion: 32,
        isOpenRsync: false,
        features: ["xattrs", "ACLs", "crtimes", "hardlinks", "symtimes", "iconv"]
    )

    /// rsync 3.1+ (not openrsync): `--info=progress2`, reliable itemize output.
    public var isModern: Bool {
        guard !isOpenRsync, let version else { return false }
        return version >= RsyncVersion(3, 1, 0)
    }

    public var supportsInfoFlags: Bool { isModern }
    public var supportsExtendedAttributes: Bool { features.contains("xattrs") }
    public var supportsACLs: Bool { features.contains("ACLs") }
    public var supportsCreationTimes: Bool { features.contains("crtimes") }

    /// Since 3.2.4 remote args are protected by default; between 3.0 and 3.2.4 we need `--protect-args`.
    public var needsExplicitProtectArgs: Bool {
        guard !isOpenRsync, let version else { return false }
        return version >= RsyncVersion(3, 0, 0) && version < RsyncVersion(3, 2, 4)
    }

    public static func parse(versionOutput: String) -> RsyncCapabilities {
        let lines = versionOutput.split(whereSeparator: \.isNewline).map(String.init)
        let isOpenRsync = lines.first?.hasPrefix("openrsync") ?? false

        var version: RsyncVersion?
        var protocolVersion: Int?
        for line in lines {
            let words = line.split(separator: " ").map(String.init)
            if version == nil, let index = words.firstIndex(of: "version"), index + 1 < words.count,
               words.first == "rsync" {
                version = RsyncVersion(string: words[index + 1])
            }
            if protocolVersion == nil, let index = words.firstIndex(of: "protocol"),
               index + 2 < words.count, words[index + 1] == "version" {
                protocolVersion = Int(words[index + 2])
            }
        }

        var features = Set<String>()
        if let start = lines.firstIndex(where: { $0.hasPrefix("Capabilities:") }) {
            for line in lines[(start + 1)...] {
                guard line.first?.isWhitespace == true else { break }
                for item in line.split(separator: ",") {
                    let feature = item.trimmingCharacters(in: .whitespaces)
                    if !feature.isEmpty, !feature.hasPrefix("no ") {
                        features.insert(feature)
                    }
                }
            }
        }

        return RsyncCapabilities(
            version: version,
            protocolVersion: protocolVersion,
            isOpenRsync: isOpenRsync,
            features: features
        )
    }
}
