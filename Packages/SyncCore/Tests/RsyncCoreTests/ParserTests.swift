import Foundation
import SyncModel
import Testing
@testable import RsyncCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fixtureString(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

@Suite struct CapabilitiesTests {
    @Test func parsesModernRsync() throws {
        let caps = RsyncCapabilities.parse(versionOutput: try fixtureString("version-rsync-3.5.0"))
        #expect(caps.version == RsyncVersion(3, 5, 0))
        #expect(caps.protocolVersion == 32)
        #expect(!caps.isOpenRsync)
        #expect(caps.isModern)
        #expect(caps.supportsExtendedAttributes)
        #expect(caps.supportsACLs)
        #expect(caps.supportsCreationTimes)
        #expect(!caps.features.contains("no prealloc"))
        #expect(!caps.needsExplicitProtectArgs)
    }

    @Test func detectsOpenRsync() throws {
        let caps = RsyncCapabilities.parse(versionOutput: try fixtureString("version-openrsync"))
        #expect(caps.isOpenRsync)
        #expect(caps.version == RsyncVersion(2, 6, 9))
        #expect(caps.protocolVersion == 29)
        #expect(!caps.isModern)
    }

    @Test func versionOrdering() {
        #expect(RsyncVersion(string: "3.2.7pre1") == RsyncVersion(3, 2, 7))
        #expect(RsyncVersion(3, 2, 3) < RsyncVersion(3, 2, 4))
        #expect(RsyncVersion(string: "x") == nil)
    }
}

@Suite struct ItemizeParserTests {
    @Test(arguments: [
        (">f+++++++++ photos/a.jpg", FileChange(kind: .added, itemType: .file, path: "photos/a.jpg")),
        (">f.st...... notes.txt", FileChange(kind: .updated, itemType: .file, path: "notes.txt")),
        (".f...p..... script.sh", FileChange(kind: .metadata, itemType: .file, path: "script.sh")),
        ("cd+++++++++ new folder/", FileChange(kind: .added, itemType: .directory, path: "new folder")),
        (".d..t...... ./", FileChange(kind: .metadata, itemType: .directory, path: ".")),
        ("cL+++++++++ link -> target file", FileChange(kind: .added, itemType: .symlink, path: "link", linkTarget: "target file")),
        ("*deleting   old/stale.txt", FileChange(kind: .deleted, itemType: .file, path: "old/stale.txt")),
        ("*deleting   old/", FileChange(kind: .deleted, itemType: .directory, path: "old")),
        ("hf+++++++++ hard", FileChange(kind: .added, itemType: .file, path: "hard")),
        (">f+++++++++ new\\#012line.txt", FileChange(kind: .added, itemType: .file, path: "new\nline.txt")),
        (">f+++++++++ héllo wörld.txt", FileChange(kind: .added, itemType: .file, path: "héllo wörld.txt")),
    ])
    func parses(line: String, expected: FileChange) {
        #expect(ItemizeParser.parse(line) == expected)
    }

    @Test(arguments: [
        "sending incremental file list",
        "Number of files: 8 (reg: 5, dir: 2, link: 1)",
        "        200,000  33%  190.73MB/s    0:00:00 (xfr#1, to-chk=2/8)",
        "created directory /tmp/x",
        "",
        ">x+++++++++ bogus",
    ])
    func ignoresOtherLines(line: String) {
        #expect(ItemizeParser.parse(line) == nil)
    }

    @Test func unescapeLeavesIncompleteSequences() {
        #expect(RsyncEscapes.unescape("a\\#01") == "a\\#01")
        #expect(RsyncEscapes.unescape("a\\#999b") == "a\\#999b")
        #expect(RsyncEscapes.unescape("tab\\#011end") == "tab\tend")
    }
}

@Suite struct ProgressParserTests {
    @Test func parsesFullLine() throws {
        let p = try #require(ProgressParser.parse("        200,000  33%  190.73MB/s    0:00:00 (xfr#1, to-chk=2/8)"))
        #expect(p.bytesTransferred == 200_000)
        #expect(p.percent == 33)
        #expect(abs(p.bytesPerSecond - 190.73 * 1024 * 1024) < 1)
        #expect(p.filesTransferred == 1)
        #expect(p.filesRemaining == 2)
        #expect(p.filesTotal == 8)
        #expect(!p.stillScanning)
        #expect(p.fileFraction == 0.75)
    }

    @Test func parsesLineWithoutCounters() throws {
        let p = try #require(ProgressParser.parse("         32,768   5%    0.00kB/s    0:00:00  "))
        #expect(p.bytesTransferred == 32_768)
        #expect(p.bytesPerSecond == 0)
        #expect(p.filesTotal == nil)
    }

    @Test func parsesIncrementalScanAndLongETA() throws {
        let p = try #require(ProgressParser.parse("  1,234,567,890  12%   11.20MB/s    1:02:03 (xfr#120, ir-chk=1000/5021)"))
        #expect(p.stillScanning)
        #expect(p.time == 3723)
    }

    @Test func rejectsNonProgress() {
        #expect(ProgressParser.parse(">f+++++++++ 50% off.txt") == nil)
    }
}

@Suite struct StreamParsingTests {
    /// Feeds a captured run through the splitter and parsers exactly as `RsyncProcess` does.
    func replay(_ data: Data, chunkSize: Int) -> (ChangeSummary, [TransferProgress], TransferStats?) {
        var splitter = LineSplitter()
        var lines: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            lines += splitter.append(data[index..<end])
            index = end
        }
        if let rest = splitter.flush() { lines.append(rest) }

        var summary = ChangeSummary()
        var progress: [TransferProgress] = []
        var other: [String] = []
        for line in lines {
            if let p = ProgressParser.parse(line) { progress.append(p) }
            else if let c = ItemizeParser.parse(line) { summary.record(c) }
            else { other.append(line) }
        }
        return (summary, progress, StatsParser.parse(other))
    }

    @Test(arguments: [1, 7, 4096])
    func realRunFixture(chunkSize: Int) throws {
        let (summary, progress, stats) = replay(try fixture("mirror-run"), chunkSize: chunkSize)
        #expect(summary == ChangeSummary(added: 5, updated: 1, deleted: 1, metadataOnly: 0, foldersCreated: 1))
        #expect(progress.count >= 5)
        #expect(progress.last?.filesRemaining == 0)
        let s = try #require(stats)
        #expect(s.totalFiles == 8)
        #expect(s.createdFiles == 6)
        #expect(s.deletedFiles == 1)
        #expect(s.transferredFiles == 5)
        #expect(s.totalSize == 600_016)
        #expect(s.literalData == 600_007)
        #expect(s.speedup == 1.0)
    }

    @Test func dryRunFixture() throws {
        let (summary, _, stats) = replay(try fixture("mirror-dry-run"), chunkSize: 64)
        #expect(summary.deleted == 1)
        #expect(summary.added == 5)
        #expect(stats?.literalData == 0)
    }

    @Test func splitterHandlesCarriageReturns() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\r\rb\nc".utf8)) == ["a", "b"])
        #expect(splitter.flush() == "c")
        #expect(splitter.flush() == nil)
    }
}

@Suite struct ErrorTranslatorTests {
    @Test func successHasNoDiagnosis() {
        #expect(ErrorTranslator.diagnose(exitCode: 0, stderr: []) == nil)
    }

    @Test func missingSource() throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 23, stderr: [
            #"rsync: [sender] change_dir "/x/nope" failed: No such file or directory (2)"#,
            "rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1394) [sender=3.5.0]",
        ]))
        #expect(d.title == "The source folder doesn't exist.")
        #expect(d.detail?.hasPrefix("rsync: [sender] change_dir") == true)
    }

    @Test(arguments: [
        ("ssh: connect to host 1.2.3.4 port 22: Connection refused", Diagnosis.FixIt.checkServerAddress),
        ("ssh: Could not resolve hostname nas: nodename nor servname provided", .checkServerAddress),
        ("me@nas: Permission denied (publickey,password).", .setUpSSHKey),
        ("Host key verification failed.", .trustHostKey),
        ("bash: rsync: command not found", .installRemoteRsync),
    ])
    func sshFailures(line: String, fixIt: Diagnosis.FixIt) throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 255, stderr: [line, "rsync: connection unexpectedly closed (0 bytes received so far) [sender]"]))
        #expect(d.fixIt == fixIt)
        #expect(d.severity == .failure)
        #expect(d.detail == line)
    }

    @Test func vanishedFilesAreAWarning() throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 24, stderr: ["file has vanished: \"/x/tmp\""]))
        #expect(d.severity == .warning)
    }

    @Test func permissionBlockedSuggestsFullDiskAccess() throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 23, stderr: [#"rsync: [sender] opendir "/Users/me/Library/Mail" failed: Operation not permitted (1)"#]))
        #expect(d.fixIt == .grantFullDiskAccess)
        #expect(d.severity == .warning)
    }

    @Test func maxDeleteStops() throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 25, stderr: []))
        #expect(d.fixIt == .reviewDeletions)
    }

    @Test func unknownCode() throws {
        let d = try #require(ErrorTranslator.diagnose(exitCode: 99, stderr: []))
        #expect(d.title.contains("99"))
    }
}
