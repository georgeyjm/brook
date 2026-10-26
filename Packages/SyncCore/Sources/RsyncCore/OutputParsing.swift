import Foundation
import SyncModel

// MARK: - Line splitting

/// Splits a byte stream into lines on `\n` *and* `\r`, because `--info=progress2`
/// rewrites its line in place with carriage returns. Empty lines are dropped.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A || byte == 0x0D {
                if !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }

    /// Returns whatever is left once the stream has ended.
    public mutating func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - Escapes

public enum RsyncEscapes {
    /// rsync prints unprintable bytes in names as `\#ooo` (octal), e.g. a newline as `\#012`.
    public static func unescape(_ string: String) -> String {
        guard string.contains("\\#") else { return string }
        let bytes = Array(string.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 4 < bytes.count,
               bytes[i + 1] == UInt8(ascii: "#"),
               let value = octal(bytes[i + 2], bytes[i + 3], bytes[i + 4]) {
                out.append(value)
                i += 5
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func octal(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        let digits = [a, b, c].map { Int($0) - Int(UInt8(ascii: "0")) }
        guard digits.allSatisfy({ (0...7).contains($0) }) else { return nil }
        let value = digits[0] * 64 + digits[1] * 8 + digits[2]
        return value <= 255 ? UInt8(value) : nil
    }
}

// MARK: - Itemized changes

/// Decodes `--itemize-changes` lines such as `>f+++++++++ photos/a.jpg` or `*deleting   old.txt`.
public enum ItemizeParser {
    private static let updateTypes: Set<Character> = ["<", ">", "c", "h", ".", "*"]
    private static let fileTypes: Set<Character> = ["f", "d", "L", "D", "S"]

    public static func parse(_ line: String) -> FileChange? {
        let chars = Array(line)
        guard chars.count > 12, chars[11] == " ",
              updateTypes.contains(chars[0]) else { return nil }

        var rawPath = String(chars[12...])

        if chars[0] == "*" {
            guard line.hasPrefix("*deleting") else { return nil }
            let isDirectory = rawPath.hasSuffix("/")
            if isDirectory { rawPath.removeLast() }
            return FileChange(
                kind: .deleted,
                itemType: isDirectory ? .directory : .file,
                path: RsyncEscapes.unescape(rawPath)
            )
        }

        guard fileTypes.contains(chars[1]) else { return nil }
        let itemType: FileChange.ItemType = switch chars[1] {
        case "f": .file
        case "d": .directory
        case "L": .symlink
        case "D": .device
        case "S": .special
        default: .unknown
        }

        let attributes = chars[2...10]
        let kind: FileChange.Kind
        if attributes.allSatisfy({ $0 == "+" }) {
            kind = .added
        } else if chars[0] == "<" || chars[0] == ">" || chars[0] == "c" || chars[0] == "h" {
            kind = .updated
        } else {
            kind = .metadata
        }

        var linkTarget: String?
        if itemType == .symlink, let arrow = rawPath.range(of: " -> ") {
            linkTarget = RsyncEscapes.unescape(String(rawPath[arrow.upperBound...]))
            rawPath = String(rawPath[..<arrow.lowerBound])
        }
        if itemType == .directory, rawPath.count > 1, rawPath.hasSuffix("/") { rawPath.removeLast() }

        return FileChange(kind: kind, itemType: itemType, path: RsyncEscapes.unescape(rawPath), linkTarget: linkTarget)
    }
}

// MARK: - Progress

public struct TransferProgress: Hashable, Sendable {
    public var bytesTransferred: Int64
    /// 0...100, relative to the total size rsync knows about so far.
    public var percent: Int
    public var bytesPerSecond: Double
    /// Remaining time while a file is in flight; elapsed time once it completes.
    public var time: TimeInterval
    public var filesTransferred: Int?
    public var filesRemaining: Int?
    public var filesTotal: Int?
    /// `ir-chk`: rsync is still discovering files, so totals will grow.
    public var stillScanning: Bool

    public init(
        bytesTransferred: Int64,
        percent: Int,
        bytesPerSecond: Double,
        time: TimeInterval,
        filesTransferred: Int? = nil,
        filesRemaining: Int? = nil,
        filesTotal: Int? = nil,
        stillScanning: Bool = false
    ) {
        self.bytesTransferred = bytesTransferred
        self.percent = percent
        self.bytesPerSecond = bytesPerSecond
        self.time = time
        self.filesTransferred = filesTransferred
        self.filesRemaining = filesRemaining
        self.filesTotal = filesTotal
        self.stillScanning = stillScanning
    }

    /// Fraction of files checked, which is steadier than byte percent while scanning.
    public var fileFraction: Double? {
        guard let filesRemaining, let filesTotal, filesTotal > 0 else { return nil }
        return Double(filesTotal - filesRemaining) / Double(filesTotal)
    }
}

/// Decodes `--info=progress2` lines:
/// `        200,000  33%  190.73MB/s    0:00:00 (xfr#1, to-chk=2/8)`
public enum ProgressParser {
    nonisolated(unsafe) private static let regex = #/^\s*(?<bytes>[\d,]+)\s+(?<pct>\d{1,3})%\s+(?<speed>[\d.,]+)(?<unit>[kKMGTP]?B)/s\s+(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})(?:\s+\((?:xfr#(?<xfr>\d+),\s*)?(?<chk>to-chk|ir-chk)=(?<rem>\d+)/(?<total>\d+)\))?/#

    public static func parse(_ line: String) -> TransferProgress? {
        guard line.contains("%"), let match = line.firstMatch(of: regex) else { return nil }
        let out = match.output
        guard let bytes = Int64(out.bytes.filter { $0 != "," }),
              let percent = Int(out.pct),
              let speedValue = Double(out.speed.filter { $0 != "," }),
              let h = Double(out.h), let m = Double(out.m), let s = Double(out.s) else { return nil }

        let multiplier: Double = switch out.unit.first {
        case "k", "K": 1024
        case "M": 1024 * 1024
        case "G": 1024 * 1024 * 1024
        case "T": 1024 * 1024 * 1024 * 1024
        case "P": 1024 * 1024 * 1024 * 1024 * 1024
        default: 1
        }

        return TransferProgress(
            bytesTransferred: bytes,
            percent: min(100, percent),
            bytesPerSecond: speedValue * multiplier,
            time: h * 3600 + m * 60 + s,
            filesTransferred: out.xfr.flatMap { Int($0) },
            filesRemaining: out.rem.flatMap { Int($0) },
            filesTotal: out.total.flatMap { Int($0) },
            stillScanning: out.chk == "ir-chk"
        )
    }
}

// MARK: - Stats

/// Decodes the `--stats` block printed at the end of a run.
public enum StatsParser {
    public static func parse(_ lines: [String]) -> TransferStats? {
        var stats = TransferStats()
        var found = false

        for line in lines {
            if line.hasPrefix("total size is "), let range = line.range(of: "speedup is ") {
                stats.speedup = Double(leadingNumber(String(line[range.upperBound...])))
                found = true
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let value = String(line[line.index(after: colon)...])

            switch key {
            case "Number of files": stats.totalFiles = int(value)
            case "Number of created files": stats.createdFiles = int(value)
            case "Number of deleted files": stats.deletedFiles = int(value)
            case "Number of regular files transferred": stats.transferredFiles = int(value)
            case "Total file size": stats.totalSize = int64(value)
            case "Total transferred file size": stats.transferredSize = int64(value)
            case "Literal data": stats.literalData = int64(value)
            case "Matched data": stats.matchedData = int64(value)
            case "Total bytes sent": stats.bytesSent = int64(value)
            case "Total bytes received": stats.bytesReceived = int64(value)
            default: continue
            }
            found = true
        }
        return found ? stats : nil
    }

    private static func leadingNumber(_ value: String) -> String {
        let trimmed = value.drop { $0 == " " }
        return String(trimmed.prefix { $0.isNumber || $0 == "," || $0 == "." }).replacingOccurrences(of: ",", with: "")
    }

    private static func int(_ value: String) -> Int? { Int(leadingNumber(value)) }
    private static func int64(_ value: String) -> Int64? { Int64(leadingNumber(value)) }
}
