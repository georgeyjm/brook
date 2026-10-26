import Foundation
import Testing
@testable import SyncModel

@Suite struct ModelTests {
    @Test func endpointHelpers() {
        let id = UUID()
        let remote = Endpoint.remote(hostID: id, path: "/a")
        #expect(remote.isRemote)
        #expect(remote.hostID == id)
        #expect(remote.withPath("/b").path == "/b")
        #expect(Endpoint.local("/x").path == "/x")
        #expect(!Endpoint.local("/x").isRemote)
    }

    @Test func changeSummaryIgnoresFolderMetadataNoise() {
        var summary = ChangeSummary()
        summary.record(FileChange(kind: .metadata, itemType: .directory, path: "."))
        #expect(summary.isEmpty)
        summary.record(FileChange(kind: .added, itemType: .directory, path: "new"))
        summary.record(FileChange(kind: .added, itemType: .file, path: "new/a"))
        summary.record(FileChange(kind: .metadata, itemType: .file, path: "b"))
        #expect(summary == ChangeSummary(added: 1, updated: 0, deleted: 0, metadataOnly: 1, foldersCreated: 1))
    }

    @Test func jobRoundTripsThroughJSON() throws {
        var job = SyncJob(name: "Docs", source: .local("/a"), destination: .local(path: "/Volumes/B/x", volume: VolumeIdentity(uuid: "U", name: "B", mountPath: "/Volumes/B")))
        job.schedule = JobSchedule(rule: .monthly(day: 31, at: TimeOfDay(hour: 1, minute: 2)), since: Date(timeIntervalSince1970: 0))
        job.createdAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(SyncJob.self, from: encoder.encode(job)) == job)
    }
}
