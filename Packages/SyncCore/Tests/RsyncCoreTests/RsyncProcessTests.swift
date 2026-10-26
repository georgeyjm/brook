import Foundation
import SyncModel
import Testing
@testable import RsyncCore

/// A modern rsync for integration tests: `RSYNC_PATH` env var, else Homebrew.
func testRsyncURL() -> URL? {
    let candidates = [ProcessInfo.processInfo.environment["RSYNC_PATH"]].compactMap { $0 } + RsyncLocator.homebrewPaths
    return candidates.map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// A throwaway directory tree under the system temp dir.
struct TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "synccore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String = "x") throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relativePath).path)
    }

    func path(_ relativePath: String) -> String { root.appending(path: relativePath).path }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func collect(_ stream: AsyncStream<RsyncEvent>) async -> (RsyncCompletion?, [FileChange], [TransferProgress]) {
    var completion: RsyncCompletion?
    var changes: [FileChange] = []
    var progress: [TransferProgress] = []
    for await event in stream {
        switch event {
        case .finished(let c): completion = c
        case .change(let c): changes.append(c)
        case .progress(let p): progress.append(p)
        case .line: break
        }
    }
    return (completion, changes, progress)
}

@Suite(.enabled(if: testRsyncURL() != nil, "needs rsync 3.x (Homebrew or RSYNC_PATH)"))
struct RsyncProcessTests {
    let rsync = testRsyncURL()!

    func capabilities() async throws -> RsyncCapabilities {
        try await RsyncLocator.probe(rsync, origin: .homebrew).capabilities
    }

    @Test func mirrorCopiesAndDeletes() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("src/a.txt", "hello")
        try tree.write("src/sub/b.txt", "world")
        try tree.write("dst/src/stale.txt")

        let job = SyncJob(name: "t", source: .local(tree.path("src")), destination: .local(tree.path("dst")), mode: .mirror)
        let args = try CommandBuilder.arguments(for: job, context: .init(capabilities: try await capabilities()))
        let (completion, changes, _) = await collect(try RsyncProcess(executable: rsync, arguments: args).start())

        let c = try #require(completion)
        #expect(c.exitCode == 0)
        #expect(c.diagnosis == nil)
        #expect(c.summary.added == 2)
        #expect(c.summary.deleted == 1)
        #expect(c.stats?.deletedFiles == 1)
        #expect(changes.contains(FileChange(kind: .deleted, itemType: .file, path: "src/stale.txt")))
        #expect(tree.exists("dst/src/a.txt"))
        #expect(tree.exists("dst/src/sub/b.txt"))
        #expect(!tree.exists("dst/src/stale.txt"))
    }

    @Test func previewChangesNothing() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("src/a.txt")
        try FileManager.default.createDirectory(atPath: tree.path("dst"), withIntermediateDirectories: true)

        let job = SyncJob(name: "t", source: .local(tree.path("src")), destination: .local(tree.path("dst")), copyFolderItself: false)
        let args = try CommandBuilder.arguments(for: job, context: .init(capabilities: try await capabilities(), purpose: .preview))
        let (completion, changes, _) = await collect(try RsyncProcess(executable: rsync, arguments: args).start())

        #expect(completion?.exitCode == 0)
        #expect(changes.map(\.path).contains("a.txt"))
        #expect(!tree.exists("dst/a.txt"))
    }

    @Test func failureIsDiagnosed() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let job = SyncJob(name: "t", source: .local(tree.path("missing")), destination: .local(tree.path("dst")), copyFolderItself: false)
        let args = try CommandBuilder.arguments(for: job, context: .init(capabilities: try await capabilities()))
        let (completion, _, _) = await collect(try RsyncProcess(executable: rsync, arguments: args).start())

        let c = try #require(completion)
        #expect(c.exitCode == 23)
        #expect(c.diagnosis?.title == "The source folder doesn't exist.")
    }

    @Test func stopEndsTheRun() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.write("src/a.txt")
        let job = SyncJob(name: "t", source: .local(tree.path("src")), destination: .local(tree.path("dst")))
        var args = try CommandBuilder.arguments(for: job, context: .init(capabilities: try await capabilities()))
        args.insert("--bwlimit=1", at: 0)  // slow enough to stop mid-run
        try tree.write("src/big.bin", String(repeating: "x", count: 2_000_000))

        let process = RsyncProcess(executable: rsync, arguments: args)
        let stream = try process.start()
        Task {
            try await Task.sleep(for: .milliseconds(500))
            process.stop()
        }
        let (completion, _, _) = await collect(stream)
        let c = try #require(completion)
        #expect(c.wasStopped)
        #expect(c.exitCode != 0)
        #expect(c.diagnosis == nil)
    }

    @Test func cannotStartTwice() async throws {
        let process = RsyncProcess(executable: rsync, arguments: ["--version"])
        _ = await collect(try process.start())
        #expect(throws: RsyncProcessError.self) { try process.start() }
    }
}
