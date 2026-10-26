import Foundation
import RsyncCore
import SyncModel
import SyncStore
import Testing
@testable import SyncEngine

struct FakeVolumes: VolumeInspecting {
    var mounted: [String: String]  // mount path → UUID
    func uuid(ofVolumeMountedAt mountPath: String) -> String? { mounted[mountPath] }
    func isMountPoint(_ path: String) -> Bool { mounted[path] != nil }
}

@Suite struct PreflightTests {
    let backup = VolumeIdentity(uuid: "AAAA", name: "Backup", mountPath: "/Volumes/Backup")

    func job(_ destination: Endpoint, mode: SyncMode = .copy) -> SyncJob {
        SyncJob(name: "t", source: .local(NSTemporaryDirectory()), destination: destination, mode: mode)
    }

    @Test func driveNotConnected() {
        let issues = Preflight.check(job: job(.local(path: "/Volumes/Backup/x", volume: backup)), kind: .sync,
                                     hasPreviewedOrSynced: true, volumes: FakeVolumes(mounted: [:]))
        #expect(issues.map(\.kind) == [.volumeNotConnected(name: "Backup")])
        #expect(issues.first?.confirmation == nil)
    }

    @Test func differentDriveWithSameName() {
        let issues = Preflight.check(job: job(.local(path: "/Volumes/Backup/x", volume: backup)), kind: .sync,
                                     hasPreviewedOrSynced: true, volumes: FakeVolumes(mounted: ["/Volumes/Backup": "BBBB"]))
        #expect(issues.map(\.kind) == [.wrongVolume(expected: "Backup")])
    }

    @Test func correctDrivePasses() {
        let issues = Preflight.check(job: job(.local(path: "/Volumes/Backup/x", volume: backup)), kind: .sync,
                                     hasPreviewedOrSynced: true, volumes: FakeVolumes(mounted: ["/Volumes/Backup": "AAAA"]))
        #expect(issues.isEmpty)
    }

    @Test func unmountedVolumesPathWithoutIdentity() {
        let issues = Preflight.check(job: job(.local("/Volumes/Nope/x")), kind: .sync,
                                     hasPreviewedOrSynced: true, volumes: FakeVolumes(mounted: [:]))
        #expect(issues.map(\.kind) == [.volumeNotConnected(name: "Nope")])
    }

    @Test func missingSource() {
        var j = job(.local("/tmp/x"))
        j.source = .local("/definitely/not/here")
        let issues = Preflight.check(job: j, kind: .sync, hasPreviewedOrSynced: true, volumes: FakeVolumes(mounted: [:]))
        #expect(issues.map(\.kind) == [.sourceMissing])
    }

    @Test func deletionGuardMath() {
        let safety = SafetySettings(maxDeletedFiles: 100, maxDeletedFraction: 0.2)
        // 10 of ~100 destination files: fine.
        #expect(Preflight.deletionIssue(summary: ChangeSummary(), stats: TransferStats(totalFiles: 95, createdFiles: 5, deletedFiles: 10), safety: safety) == nil)
        // 30 of ~100: over the fraction.
        let issue = Preflight.deletionIssue(summary: ChangeSummary(), stats: TransferStats(totalFiles: 70, createdFiles: 0, deletedFiles: 30), safety: safety)
        #expect(issue?.confirmation == .largeDeletion)
        // Over the absolute count even though the fraction is small.
        #expect(Preflight.deletionIssue(summary: ChangeSummary(), stats: TransferStats(totalFiles: 100_000, createdFiles: 0, deletedFiles: 101), safety: safety) != nil)
        // A handful of deletions in a tiny folder doesn't trip the percentage rule.
        #expect(Preflight.deletionIssue(summary: ChangeSummary(), stats: TransferStats(totalFiles: 8, createdFiles: 7, deletedFiles: 1), safety: safety) == nil)
        // Disabled guard.
        var off = safety
        off.deletionGuardEnabled = false
        #expect(Preflight.deletionIssue(summary: ChangeSummary(), stats: TransferStats(totalFiles: 1, createdFiles: 0, deletedFiles: 1000), safety: off) == nil)
    }
}

// MARK: - End-to-end sessions with a real rsync

func testRsyncURL() -> URL? {
    let candidates = [ProcessInfo.processInfo.environment["RSYNC_PATH"]].compactMap { $0 } + RsyncLocator.homebrewPaths
    return candidates.map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

struct Sandbox {
    let root: URL
    let history: HistoryStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "syncengine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        history = HistoryStore(directory: root.appending(path: "History"))
    }

    func path(_ p: String) -> String { root.appending(path: p).path }

    func write(_ p: String, _ contents: String = "x") throws {
        let url = root.appending(path: p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: path(p)) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.enabled(if: testRsyncURL() != nil, "needs rsync 3.x (Homebrew or RSYNC_PATH)"))
struct SyncSessionTests {
    func binary() async throws -> RsyncBinary {
        try await RsyncLocator.probe(testRsyncURL()!, origin: .homebrew)
    }

    func run(_ request: RunRequest, sandbox: Sandbox) async throws -> (SessionResult, [SessionPhase]) {
        let session = SyncSession(request: request, binary: try await binary(), history: sandbox.history,
                                  volumes: FakeVolumes(mounted: [:]))
        var phases: [SessionPhase] = []
        var result: SessionResult?
        for await event in session.start() {
            if case .phase(let p) = event { phases.append(p) }
            if case .finished(let r) = event { result = r }
        }
        return (try #require(result), phases)
    }

    /// src has 2 files; dst has 10 extra files that a mirror would delete.
    func mirrorFixture() throws -> (Sandbox, SyncJob) {
        let sandbox = try Sandbox()
        try sandbox.write("src/a.txt")
        try sandbox.write("src/b.txt")
        for i in 0..<10 { try sandbox.write("dst/old\(i).txt") }
        var job = SyncJob(name: "Mirror", source: .local(sandbox.path("src")), destination: .local(sandbox.path("dst")),
                          mode: .mirror, copyFolderItself: false)
        job.safety = SafetySettings(maxDeletedFiles: 5, maxDeletedFraction: 0.5)
        return (sandbox, job)
    }

    @Test func firstMirrorAsksForPreview() async throws {
        let (sandbox, job) = try mirrorFixture()
        defer { sandbox.remove() }
        let (result, _) = try await run(RunRequest(job: job, hosts: [], kind: .sync), sandbox: sandbox)
        #expect(result.needsConfirmation?.kind == .firstMirrorNeedsPreview)
        #expect(sandbox.history.records(for: job.id).isEmpty)  // nothing ran, nothing recorded
    }

    @Test func previewListsChangesWithoutTouchingFiles() async throws {
        let (sandbox, job) = try mirrorFixture()
        defer { sandbox.remove() }
        let (result, _) = try await run(RunRequest(job: job, hosts: [], kind: .preview), sandbox: sandbox)
        #expect(result.record.outcome == .success)
        #expect(result.record.summary.deleted == 10)
        #expect(result.record.summary.added == 2)
        #expect(result.changes.count >= 12)
        #expect(sandbox.exists("dst/old0.txt"))
        #expect(sandbox.history.records(for: job.id).count == 1)
        let log = try String(contentsOf: sandbox.history.logURL(for: result.record), encoding: .utf8)
        #expect(log.contains("--dry-run"))
    }

    @Test func deletionGuardStopsThenConfirmationProceeds() async throws {
        let (sandbox, job) = try mirrorFixture()
        defer { sandbox.remove() }
        let (guarded, phases) = try await run(RunRequest(job: job, hosts: [], kind: .sync, hasPreviewedOrSynced: true), sandbox: sandbox)
        #expect(phases.contains(.estimatingDeletions))
        #expect(guarded.needsConfirmation?.confirmation == .largeDeletion)
        #expect(sandbox.exists("dst/old0.txt"))

        let (confirmed, _) = try await run(RunRequest(job: job, hosts: [], kind: .sync, confirmations: [.largeDeletion], hasPreviewedOrSynced: true), sandbox: sandbox)
        #expect(confirmed.record.outcome == .success)
        #expect(!sandbox.exists("dst/old0.txt"))
        #expect(sandbox.exists("dst/a.txt"))
    }

    @Test func scheduledRunSkipsInsteadOfAsking() async throws {
        let (sandbox, job) = try mirrorFixture()
        defer { sandbox.remove() }
        let (result, _) = try await run(RunRequest(job: job, hosts: [], kind: .sync, trigger: .scheduled, hasPreviewedOrSynced: true), sandbox: sandbox)
        #expect(result.needsConfirmation == nil)
        #expect(result.record.outcome == .skipped)
        #expect(result.record.message?.contains("Scheduled runs skip") == true)
        #expect(sandbox.history.latest(for: job.id)?.outcome == .skipped)
        #expect(sandbox.exists("dst/old0.txt"))
    }

    @Test func hooksRunWithEnvironmentAndCanAbort() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("src/a.txt")
        var job = SyncJob(name: "Hooked", source: .local(sandbox.path("src")), destination: .local(sandbox.path("dst")))
        let marker = sandbox.path("after.txt")
        job.hooks = Hooks(beforeRun: "echo before $SYNC_NAME", afterRun: "echo \"$SYNC_EXIT_CODE\" > '\(marker)'")

        let (ok, phases) = try await run(RunRequest(job: job, hosts: [], kind: .sync), sandbox: sandbox)
        #expect(ok.record.outcome == .success)
        #expect(phases == [.checking, .runningBeforeHook, .transferring, .runningAfterHook])
        #expect(try String(contentsOfFile: marker, encoding: .utf8) == "0\n")
        #expect(sandbox.exists("dst/src/a.txt"))

        job.hooks.beforeRun = "exit 3"
        let (aborted, _) = try await run(RunRequest(job: job, hosts: [], kind: .sync), sandbox: sandbox)
        #expect(aborted.record.outcome == .failed)
        #expect(aborted.record.message?.contains("exit code 3") == true)
    }

    @Test func failureIsRecordedWithDiagnosis() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // Source exists at preflight time but is unreadable to rsync: use a file with "contents only".
        try sandbox.write("dst/x")
        let host = RemoteHost(name: "Nowhere", hostname: "doesnotexist.invalid", sshOptions: ["ConnectTimeout=2"])
        let job = SyncJob(name: "Remote", source: .local(sandbox.path("dst")), destination: .remote(hostID: host.id, path: "/tmp/x"))
        let (result, _) = try await run(RunRequest(job: job, hosts: [host], kind: .sync), sandbox: sandbox)
        #expect(result.record.outcome == .failed)
        #expect(result.diagnosis?.fixIt == .checkServerAddress)
        #expect(sandbox.history.latest(for: job.id)?.exitCode == 255)
    }
}
