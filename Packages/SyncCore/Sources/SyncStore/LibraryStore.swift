import Foundation
import SyncModel

public enum JSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reads and writes the user's `Library` (syncs, hosts, groups) as one JSON file.
/// The previous version is kept as `<name>.bak` so a bad write never loses everything.
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `<directory>/syncs.json`
    public init(directory: URL) {
        self.init(fileURL: directory.appending(path: "syncs.json"))
    }

    public var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// Returns an empty library if no file exists yet.
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Library() }
        let data = try Data(contentsOf: fileURL)
        return try JSONCoding.makeDecoder().decode(Library.self, from: data)
    }

    public func save(_ library: Library) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.makeEncoder().encode(library)

        if fm.fileExists(atPath: fileURL.path) {
            if let existing = try? Data(contentsOf: fileURL), existing == data { return }
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    /// Exports selected syncs (plus the hosts they use) for sharing or backup.
    public static func export(jobs: [SyncJob], from library: Library) throws -> Data {
        let hostIDs = Set(jobs.flatMap { [$0.source.hostID, $0.destination.hostID].compactMap { $0 } })
        let groupIDs = Set(jobs.compactMap(\.groupID))
        let subset = Library(
            jobs: jobs,
            hosts: library.hosts.filter { hostIDs.contains($0.id) },
            groups: library.groups.filter { groupIDs.contains($0.id) }
        )
        return try JSONCoding.makeEncoder().encode(subset)
    }

    /// Merges an exported file into `library`, giving imported items fresh IDs so nothing is overwritten.
    public static func importing(_ data: Data, into library: Library) throws -> (library: Library, importedJobIDs: [UUID]) {
        let incoming = try JSONCoding.makeDecoder().decode(Library.self, from: data)
        var result = library

        var hostMap: [UUID: UUID] = [:]
        for var host in incoming.hosts {
            let newID = UUID()
            hostMap[host.id] = newID
            host.id = newID
            result.hosts.append(host)
        }
        var groupMap: [UUID: UUID] = [:]
        for var group in incoming.groups {
            if let existing = result.groups.first(where: { $0.name == group.name }) {
                groupMap[group.id] = existing.id
            } else {
                let newID = UUID()
                groupMap[group.id] = newID
                group.id = newID
                result.groups.append(group)
            }
        }

        func remap(_ endpoint: Endpoint) -> Endpoint {
            guard case .remote(let hostID, let path) = endpoint else { return endpoint }
            return .remote(hostID: hostMap[hostID] ?? hostID, path: path)
        }

        var imported: [UUID] = []
        for var job in incoming.jobs {
            job.id = UUID()
            job.source = remap(job.source)
            job.destination = remap(job.destination)
            job.groupID = job.groupID.flatMap { groupMap[$0] }
            result.jobs.append(job)
            imported.append(job.id)
        }
        return (result, imported)
    }
}
