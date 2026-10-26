import Foundation

/// A concrete `Host` entry from `~/.ssh/config` (wildcard patterns are skipped).
public struct SSHConfigHost: Hashable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil, identityFile: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

/// Reads host aliases from an OpenSSH config so users can pick hosts they already use.
/// This is for suggestions only: ssh itself still reads the config when connecting.
public enum SSHConfigParser {
    public static var defaultConfigURL: URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".ssh/config")
    }

    public static func hosts(in url: URL = defaultConfigURL, followIncludes: Bool = true) -> [SSHConfigHost] {
        var visited = Set<String>()
        return hosts(in: url, followIncludes: followIncludes, visited: &visited)
    }

    private static func hosts(in url: URL, followIncludes: Bool, visited: inout Set<String>) -> [SSHConfigHost] {
        guard visited.insert(url.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var result: [SSHConfigHost] = []
        var included: [URL] = []
        for (key, value) in parseDirectives(text) where key == "include" && followIncludes {
            included += expandInclude(value, relativeTo: url.deletingLastPathComponent())
        }
        result += parse(text)
        for includeURL in included {
            result += hosts(in: includeURL, followIncludes: true, visited: &visited)
        }

        var seen = Set<String>()
        return result.filter { seen.insert($0.alias).inserted }
    }

    /// Parses config text (no includes).
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [SSHConfigHost] = []
        var inMatchBlock = false

        func flush() {
            hosts += current
            current = []
        }

        for (key, value) in parseDirectives(text) {
            switch key {
            case "host":
                flush()
                inMatchBlock = false
                current = value.split(separator: " ").map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                    .map { SSHConfigHost(alias: $0) }
            case "match":
                flush()
                inMatchBlock = true
            default:
                guard !inMatchBlock else { continue }
                for index in current.indices {
                    // First value wins, as in OpenSSH.
                    switch key {
                    case "hostname": current[index].hostName = current[index].hostName ?? value
                    case "user": current[index].user = current[index].user ?? value
                    case "port": current[index].port = current[index].port ?? Int(value)
                    case "identityfile": current[index].identityFile = current[index].identityFile ?? value
                    case "proxyjump": current[index].proxyJump = current[index].proxyJump ?? value
                    default: break
                    }
                }
            }
        }
        flush()
        return hosts
    }

    /// (lowercased keyword, value) pairs, comments and blank lines removed.
    static func parseDirectives(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            // "Key value", "Key=value" or "Key = value"
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
            let key = line[..<separator].lowercased()
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("=") { value = value.dropFirst().trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return (key, value)
        }
    }

    static func expandInclude(_ pattern: String, relativeTo directory: URL) -> [URL] {
        pattern.split(separator: " ").flatMap { part -> [URL] in
            var path = String(part)
            if path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst(1) }
            if !path.hasPrefix("/") { path = directory.appending(path: path).path }

            let url = URL(filePath: path)
            let name = url.lastPathComponent
            guard name.contains("*") else { return [url] }
            let parent = url.deletingLastPathComponent()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            let predicate = NSPredicate(format: "SELF LIKE %@", name)
            return files.filter { predicate.evaluate(with: $0) }.sorted().map { parent.appending(path: $0) }
        }
    }
}
