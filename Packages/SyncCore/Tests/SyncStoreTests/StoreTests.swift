import Foundation
import SyncModel
import Testing
@testable import SyncStore

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "syncstore-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct LibraryStoreTests {
    @Test func missingFileLoadsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try LibraryStore(directory: dir).load() == Library())
    }

    @Test func roundTripsAndKeepsBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir)

        let host = RemoteHost(name: "NAS", hostname: "nas.local", user: "me")
        var job = SyncJob(name: "Photos", source: .local("/Users/me/Pictures"), destination: .remote(hostID: host.id, path: "/backup"))
        job.schedule = JobSchedule(rule: .weekly(days: [.monday, .friday], at: TimeOfDay(hour: 2, minute: 0)))
        let library = Library(jobs: [job], hosts: [host])

        try store.save(library)
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
        // Dates go through ISO 8601 (second precision), so compare after one round trip.
        let loaded = try store.load()
        #expect(loaded.jobs.first?.name == "Photos")
        #expect(loaded.hosts == [host])

        var changed = loaded
        changed.jobs[0].name = "Pictures"
        try store.save(changed)
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path))
        #expect(try store.load().jobs[0].name == "Pictures")

        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"remote\""))
        #expect(json.contains("\"path\" : \"/backup\""))
    }

    @Test func importGivesFreshIDsAndRemapsHosts() throws {
        let host = RemoteHost(name: "NAS", hostname: "nas")
        let group = SyncGroup(name: "Work")
        let job = SyncJob(name: "A", groupID: group.id, source: .local("/a"), destination: .remote(hostID: host.id, path: "/b"))
        let original = Library(jobs: [job], hosts: [host], groups: [group])

        let data = try LibraryStore.export(jobs: [job], from: original)
        let (merged, imported) = try LibraryStore.importing(data, into: original)

        #expect(merged.jobs.count == 2)
        #expect(merged.hosts.count == 2)
        #expect(merged.groups.count == 1)  // same-named group is reused
        let copy = try #require(merged.job(id: imported[0]))
        #expect(copy.id != job.id)
        #expect(copy.groupID == group.id)
        #expect(copy.destination.hostID != host.id)
        #expect(merged.host(id: copy.destination.hostID!) != nil)
    }
}

@Suite struct HistoryStoreTests {
    @Test func saveListPruneAndRepair() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let jobID = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 0..<5 {
            var record = RunRecord(jobID: jobID, kind: .sync, trigger: .manual, startedAt: base.addingTimeInterval(Double(i) * 60), outcome: .success)
            record.logFileName = "\(record.id.uuidString).log"
            try store.save(record)
            let log = try store.openLog(for: record)
            try log.write(contentsOf: Data("line \(i)\n".utf8))
            try log.close()
        }
        let records = store.records(for: jobID)
        #expect(records.count == 5)
        #expect(records.first!.startedAt > records.last!.startedAt)
        #expect(store.latest(for: jobID)?.id == records.first?.id)

        store.prune(jobID: jobID, keep: 2)
        let kept = store.records(for: jobID)
        #expect(kept.map(\.id) == Array(records.prefix(2)).map(\.id))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: jobID.uuidString).path)
        #expect(files.count == 4)

        try store.save(RunRecord(jobID: jobID, kind: .sync, trigger: .scheduled, startedAt: base.addingTimeInterval(3600)))
        store.repairInterruptedRuns()
        #expect(store.latest(for: jobID)?.outcome == .failed)
        #expect(store.allRecords(limit: 1).count == 1)

        store.deleteHistory(for: jobID)
        #expect(store.records(for: jobID).isEmpty)
    }
}
