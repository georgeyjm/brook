import Foundation
import ProcessSupport

/// A usable rsync executable and what it supports.
public struct RsyncBinary: Hashable, Sendable {
    public enum Origin: String, Hashable, Sendable {
        /// Shipped inside the app (`Contents/Helpers/rsync`).
        case bundled
        case homebrew
        case custom
        /// `/usr/bin/rsync`, which is openrsync on macOS 15+. Last resort only.
        case system
    }

    public var url: URL
    public var origin: Origin
    public var capabilities: RsyncCapabilities

    public init(url: URL, origin: Origin, capabilities: RsyncCapabilities) {
        self.url = url
        self.origin = origin
        self.capabilities = capabilities
    }
}

public enum RsyncLocatorError: Error, Sendable {
    case notExecutable(URL)
    case unrecognisedOutput(URL)
}

public enum RsyncLocator {
    public static let homebrewPaths = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"]
    public static let systemPath = "/usr/bin/rsync"

    /// The rsync helper inside an app bundle, if present.
    public static func bundledURL(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appending(path: "Contents/Helpers/rsync")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Runs `rsync --version` and parses it.
    public static func probe(_ url: URL, origin: RsyncBinary.Origin) async throws -> RsyncBinary {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw RsyncLocatorError.notExecutable(url) }
        let result = try await CommandRunner.run(url, arguments: ["--version"], timeout: .seconds(10))
        let capabilities = RsyncCapabilities.parse(versionOutput: result.stdout + result.stderr)
        guard capabilities.version != nil || capabilities.isOpenRsync else {
            throw RsyncLocatorError.unrecognisedOutput(url)
        }
        return RsyncBinary(url: url, origin: origin, capabilities: capabilities)
    }

    /// Picks the binary to use: the user's custom choice, then the bundled helper, then Homebrew.
    /// Falls back to the system openrsync only when nothing better exists.
    public static func locate(customPath: String? = nil, bundle: Bundle = .main) async -> RsyncBinary? {
        var candidates: [(URL, RsyncBinary.Origin)] = []
        if let customPath, !customPath.isEmpty { candidates.append((URL(filePath: customPath), .custom)) }
        if let bundled = bundledURL(in: bundle) { candidates.append((bundled, .bundled)) }
        candidates += homebrewPaths.map { (URL(filePath: $0), .homebrew) }

        for (url, origin) in candidates {
            if let binary = try? await probe(url, origin: origin), binary.capabilities.isModern || origin == .custom {
                return binary
            }
        }
        return try? await probe(URL(filePath: systemPath), origin: .system)
    }
}
