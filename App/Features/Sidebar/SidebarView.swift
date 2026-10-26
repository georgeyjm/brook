import SwiftUI
import SyncModel

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var jobPendingDeletion: SyncJob?
    @State private var groupNamePrompt: GroupNamePrompt?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            if !model.jobs.isEmpty {
                Section("Syncs") {
                    jobRows(in: nil)
                }
            }
            ForEach(model.groups) { group in
                Section {
                    jobRows(in: group.id)
                } header: {
                    Text(group.name)
                        .contextMenu {
                            Button("Rename Group…") { groupNamePrompt = GroupNamePrompt(groupID: group.id, name: group.name) }
                            Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
                        }
                }
            }
            Section("Library") {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(AppModel.SidebarItem.activity)
                Label("Servers", systemImage: "server.rack")
                    .tag(AppModel.SidebarItem.servers)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("New Sync", systemImage: "plus") { model.newJob() }
                    .help("Create a new sync (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom) { RsyncStatusFooter() }
        .confirmationDialog(
            "Delete “\(jobPendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { jobPendingDeletion != nil }, set: { if !$0 { jobPendingDeletion = nil } }),
            presenting: jobPendingDeletion
        ) { job in
            Button("Delete Sync", role: .destructive) { model.delete(job.id) }
        } message: { _ in
            Text("The sync and its history are removed. No files are deleted.")
        }
        .alert(groupNamePrompt?.groupID == nil ? "New Group" : "Rename Group",
               isPresented: Binding(get: { groupNamePrompt != nil }, set: { if !$0 { groupNamePrompt = nil } })) {
            TextField("Name", text: Binding(get: { groupNamePrompt?.name ?? "" }, set: { groupNamePrompt?.name = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitGroupPrompt() }
        }
    }

    @ViewBuilder
    private func jobRows(in groupID: UUID?) -> some View {
        ForEach(model.jobs.filter { $0.groupID == groupID }) { job in
            SyncRow(job: job)
                .tag(AppModel.SidebarItem.sync(job.id))
                .contextMenu { contextMenu(for: job) }
        }
        .onMove { model.moveJobs(in: groupID, from: $0, to: $1) }
    }

    @ViewBuilder
    private func contextMenu(for job: SyncJob) -> some View {
        let running = model.runs.isRunning(job.id)
        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.runs.start(job.id, kind: .sync) }
            .disabled(running)
        Button("Preview Changes", systemImage: "eye") { model.runs.start(job.id, kind: .preview) }
            .disabled(running)
        if running {
            Button("Stop", systemImage: "stop.fill") { model.runs.stop(job.id) }
        }
        Divider()
        Button("Edit…", systemImage: "pencil") { model.edit(job.id) }
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(job.id) }
        Menu("Move to Group") {
            Button("None") { model.move(job.id, toGroup: nil) }
                .disabled(job.groupID == nil)
            ForEach(model.groups) { group in
                Button(group.name) { model.move(job.id, toGroup: group.id) }
                    .disabled(job.groupID == group.id)
            }
            Divider()
            Button("New Group…") { groupNamePrompt = GroupNamePrompt(groupID: nil, name: "", moveJobID: job.id) }
        }
        if job.schedule != nil {
            Button(job.isEnabled ? "Pause Schedule" : "Resume Schedule",
                   systemImage: job.isEnabled ? "pause.circle" : "play.circle") {
                model.setEnabled(!job.isEnabled, for: job.id)
            }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { jobPendingDeletion = job }
    }

    private func commitGroupPrompt() {
        guard let prompt = groupNamePrompt else { return }
        let name = prompt.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let id = prompt.groupID {
            model.renameGroup(id, to: name)
        } else {
            let group = model.addGroup(named: name)
            if let jobID = prompt.moveJobID { model.move(jobID, toGroup: group.id) }
        }
    }
}

private struct GroupNamePrompt {
    var groupID: UUID?
    var name: String
    var moveJobID: UUID?
}

/// One sync in the sidebar: icon, name, and a live status line.
struct SyncRow: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob

    var body: some View {
        HStack(spacing: 10) {
            SyncIcon(symbol: job.symbol, tint: job.tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name.isEmpty ? "Untitled Sync" : job.name)
                    .lineLimit(1)
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        let _ = model.historyRevision
        if let run = model.runs.liveRun(for: job.id), run.isRunning {
            if let progress = run.progress, run.phase == .transferring {
                Text("\(run.kind == .preview ? "Previewing" : "Syncing") · \(progress.percent)%")
            } else {
                Text(run.phase.label)
            }
        } else if let record = model.lastRecord(for: job.id) {
            Text(record.headline)
        } else {
            Text("Never synced")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        let _ = model.historyRevision
        if let run = model.runs.liveRun(for: job.id), run.isRunning {
            if let progress = run.progress, run.phase == .transferring, !progress.stillScanning {
                ProgressView(value: Double(progress.percent), total: 100)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if job.schedule != nil && !job.isEnabled {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                .help("Schedule paused")
        } else if let record = model.lastRecord(for: job.id), record.outcome == .failed || record.outcome == .warning {
            Image(systemName: record.outcome.symbol).foregroundStyle(record.outcome.color)
                .help(record.message ?? record.outcome.label)
        }
    }
}

/// Shown at the bottom of the sidebar when rsync is missing or limited.
private struct RsyncStatusFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch model.rsyncStatus {
        case .missing:
            banner("No usable rsync found", symbol: "exclamationmark.triangle.fill", color: .red)
        case .ready(let binary) where binary.capabilities.isOpenRsync:
            banner("Using macOS's limited rsync", symbol: "exclamationmark.triangle.fill", color: .orange)
        default:
            EmptyView()
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Button { openSettings() } label: {
            Label(text, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(10)
        .glassEffect(in: .rect(cornerRadius: 10))
        .padding(10)
        .help("Open Settings to choose an rsync")
    }
}
