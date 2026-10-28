import Foundation
import Observation
import OSLog
import RsyncCore
import SyncEngine
import SyncModel
import SyncStore

/// App-wide state: the user's library, run history, the rsync binary, and UI navigation.
@Observable @MainActor
final class AppModel {
    enum RsyncStatus: Equatable {
        case locating
        case ready(RsyncBinary)
        case missing
    }

    enum SidebarItem: Hashable {
        case home
        case sync(UUID)
        case activity
        case servers
    }

    /// Something the editor sheet should show.
    struct EditorRequest: Identifiable {
        let id = UUID()
        var job: SyncJob
        var isNew: Bool
    }

    private(set) var library = Library()
    private(set) var rsyncStatus: RsyncStatus = .locating
    private(set) var recordsByJob: [UUID: [RunRecord]] = [:]
    private(set) var historyRevision = 0
    var saveError: String?

    // Navigation
    var selection: SidebarItem? = .home
    var editor: EditorRequest?

    let libraryStore: LibraryStore
    let history: HistoryStore
    private(set) var runs: RunCoordinator!
    private(set) var scheduler: SchedulerService!

    private let log = Logger(subsystem: "app.brook.mac", category: "model")

    init(supportDirectory: URL = AppInfo.supportDirectory) {
        libraryStore = LibraryStore(directory: supportDirectory)
        history = HistoryStore(directory: supportDirectory.appending(path: "History", directoryHint: .isDirectory))

        do {
            library = try libraryStore.load()
        } catch {
            log.error("Couldn't load library: \(error.localizedDescription, privacy: .public)")
            saveError = "Your syncs couldn't be loaded (\(error.localizedDescription)). A backup is kept next to the file."
        }
        history.repairInterruptedRuns()

        runs = RunCoordinator(model: self)
        scheduler = SchedulerService(model: self)
        Task { await locateRsync() }
    }

    // MARK: - rsync

    var rsync: RsyncBinary? {
        if case .ready(let binary) = rsyncStatus { binary } else { nil }
    }

    func locateRsync() async {
        rsyncStatus = .locating
        let found = await RsyncLocator.locate(customPath: Preferences.customRsyncPath)
        rsyncStatus = found.map { .ready($0) } ?? .missing
        if let found {
            log.info("Using rsync \(found.capabilities.version?.description ?? "?", privacy: .public) at \(found.url.path, privacy: .public)")
        }
        // Schedules can only run once we know which rsync to use.
        scheduler.start()
    }

    // MARK: - Jobs

    var jobs: [SyncJob] { library.jobs }
    var hosts: [RemoteHost] { library.hosts }
    var groups: [SyncGroup] { library.groups }

    func job(id: UUID) -> SyncJob? { library.job(id: id) }
    func host(id: UUID) -> RemoteHost? { library.host(id: id) }

    func newJob(prefilledSource: String? = nil) {
        var job = SyncJob(name: "", source: .local(""), destination: .local(""))
        if let prefilledSource {
            job.source = .local(path: prefilledSource, volume: SystemVolumes.identity(forPath: prefilledSource))
            job.name = (prefilledSource as NSString).lastPathComponent
        }
        if case .sync(let id)? = selection, let groupID = self.job(id: id)?.groupID {
            job.groupID = groupID
        }
        editor = EditorRequest(job: job, isNew: true)
    }

    func edit(_ jobID: UUID) {
        guard let job = job(id: jobID) else { return }
        editor = EditorRequest(job: job, isNew: false)
    }

    func save(job: SyncJob) {
        var job = job
        if let old = self.job(id: job.id), old.schedule?.rule != job.schedule?.rule {
            // A changed schedule starts counting from now.
            job.schedule?.since = Date()
        }
        if let index = library.jobs.firstIndex(where: { $0.id == job.id }) {
            library.jobs[index] = job
        } else {
            library.jobs.append(job)
        }
        persist()
        selection = .sync(job.id)
        scheduler.reschedule()
    }

    func duplicate(_ jobID: UUID) {
        guard var copy = job(id: jobID) else { return }
        copy.id = UUID()
        copy.name += " copy"
        copy.createdAt = Date()
        copy.schedule?.since = Date()
        if let index = library.jobs.firstIndex(where: { $0.id == jobID }) {
            library.jobs.insert(copy, at: index + 1)
        }
        persist()
        selection = .sync(copy.id)
        scheduler.reschedule()
    }

    func delete(_ jobID: UUID) {
        runs.stop(jobID)
        library.jobs.removeAll { $0.id == jobID }
        history.deleteHistory(for: jobID)
        recordsByJob[jobID] = nil
        if selection == .sync(jobID) { selection = .home }
        persist()
        scheduler.reschedule()
    }

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = library.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        library.jobs[index].isEnabled = enabled
        persist()
        scheduler.reschedule()
    }

    func move(_ jobID: UUID, toGroup groupID: UUID?) {
        guard let index = library.jobs.firstIndex(where: { $0.id == jobID }) else { return }
        library.jobs[index].groupID = groupID
        persist()
    }

    func moveJobs(in groupID: UUID?, from source: IndexSet, to destination: Int) {
        var subset = library.jobs.filter { $0.groupID == groupID }
        subset.move(fromOffsets: source, toOffset: destination)
        var iterator = subset.makeIterator()
        library.jobs = library.jobs.map { $0.groupID == groupID ? iterator.next()! : $0 }
        persist()
    }

    // MARK: - Groups

    @discardableResult
    func addGroup(named name: String) -> SyncGroup {
        let group = SyncGroup(name: name)
        library.groups.append(group)
        persist()
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let index = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[index].name = name
        persist()
    }

    func deleteGroup(_ id: UUID) {
        library.groups.removeAll { $0.id == id }
        for index in library.jobs.indices where library.jobs[index].groupID == id {
            library.jobs[index].groupID = nil
        }
        persist()
    }

    // MARK: - Hosts

    func save(host: RemoteHost) {
        if let index = library.hosts.firstIndex(where: { $0.id == host.id }) {
            library.hosts[index] = host
        } else {
            library.hosts.append(host)
        }
        persist()
    }

    func jobsUsing(hostID: UUID) -> [SyncJob] {
        library.jobs.filter { $0.source.hostID == hostID || $0.destination.hostID == hostID }
    }

    func deleteHost(_ id: UUID) {
        guard jobsUsing(hostID: id).isEmpty else { return }
        library.hosts.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Import / export

    func exportData(jobIDs: [UUID]) throws -> Data {
        try LibraryStore.export(jobs: library.jobs.filter { jobIDs.contains($0.id) }, from: library)
    }

    func importData(_ data: Data) throws {
        let (merged, imported) = try LibraryStore.importing(data, into: library)
        library = merged
        persist()
        if let first = imported.first { selection = .sync(first) }
        scheduler.reschedule()
    }

    private func persist() {
        do {
            try libraryStore.save(library)
            saveError = nil
        } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
            saveError = "Couldn't save your changes: \(error.localizedDescription)"
        }
    }

    // MARK: - History

    func records(for jobID: UUID) -> [RunRecord] {
        if let cached = recordsByJob[jobID] { return cached }
        let loaded = history.records(for: jobID)
        recordsByJob[jobID] = loaded
        return loaded
    }

    func lastRecord(for jobID: UUID, kind: RunKind? = nil) -> RunRecord? {
        records(for: jobID).first { kind == nil || $0.kind == kind }
    }

    /// The most recent finished sync (not preview), for "Synced 2 hours ago".
    func lastSync(for jobID: UUID) -> RunRecord? {
        records(for: jobID).first { $0.kind == .sync && $0.outcome != .running }
    }

    func hasPreviewedOrSynced(_ jobID: UUID) -> Bool {
        records(for: jobID).contains { $0.outcome == .success || $0.outcome == .warning }
    }

    func historyDidChange(for jobID: UUID) {
        history.prune(jobID: jobID, keep: Preferences.historyLimit)
        recordsByJob[jobID] = history.records(for: jobID)
        historyRevision += 1
    }

    func clearHistory(for jobID: UUID) {
        history.deleteHistory(for: jobID)
        historyDidChange(for: jobID)
    }
}
