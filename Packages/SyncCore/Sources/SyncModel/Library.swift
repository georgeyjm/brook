import Foundation

/// Everything the user configures, persisted as one human-readable JSON document.
public struct Library: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var jobs: [SyncJob]
    public var hosts: [RemoteHost]
    public var groups: [SyncGroup]

    public init(jobs: [SyncJob] = [], hosts: [RemoteHost] = [], groups: [SyncGroup] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.jobs = jobs
        self.hosts = hosts
        self.groups = groups
    }

    public func host(id: UUID) -> RemoteHost? { hosts.first { $0.id == id } }
    public func job(id: UUID) -> SyncJob? { jobs.first { $0.id == id } }
}
