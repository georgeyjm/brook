import RsyncCore
import SwiftUI
import SyncEngine
import SyncModel

struct SyncDetailView: View {
    @Environment(AppModel.self) private var model
    let jobID: UUID
    @State private var resultsRecord: RunRecord?

    var body: some View {
        if let job = model.job(id: jobID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Header(job: job)
                    RouteCard(job: job)
                    if let run = model.runs.liveRun(for: jobID), run.isRunning {
                        RunProgressCard(run: run)
                    } else {
                        LastRunCard(job: job, showResults: { resultsRecord = $0 })
                    }
                    if job.schedule != nil {
                        ScheduleCard(job: job)
                    }
                    HistoryCard(job: job, showResults: { resultsRecord = $0 })
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(job.name)
            .toolbar {
                ToolbarItem {
                    Button("Edit", systemImage: "slider.horizontal.3") { model.edit(job.id) }
                        .help("Edit this sync (⌘E)")
                }
            }
            .sheet(item: $resultsRecord) { record in
                ResultsView(job: job, record: record)
            }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob

    var body: some View {
        let run = model.runs.liveRun(for: job.id)
        let running = run?.isRunning == true

        HStack(alignment: .center, spacing: 16) {
            SyncIcon(symbol: job.symbol, tint: job.tint, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.name.isEmpty ? "Untitled Sync" : job.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if job.mode == .mirror {
                        Pill(text: "Mirror · can delete files", systemImage: "arrow.left.arrow.right", color: .orange)
                    } else {
                        Pill(text: "Copy new & changed", systemImage: "arrow.right", color: .accentColor)
                    }
                    if let schedule = job.schedule {
                        Pill(text: job.isEnabled ? schedule.summary : "Schedule paused",
                             systemImage: job.isEnabled ? "calendar" : "pause.circle",
                             color: job.isEnabled ? .secondary : .orange)
                    }
                }
            }
            Spacer()
            if running, let run {
                Button(run.isPaused ? "Resume" : "Pause", systemImage: run.isPaused ? "play.fill" : "pause.fill") {
                    model.runs.togglePause(job.id)
                }
                .buttonStyle(.glass)
                .disabled(run.phase != .transferring && run.phase != .estimatingDeletions)
                Button("Stop", systemImage: "stop.fill", role: .destructive) { model.runs.stop(job.id) }
                    .buttonStyle(.glass)
            } else {
                Button("Preview", systemImage: "eye") { model.runs.start(job.id, kind: .preview) }
                    .buttonStyle(.glass)
                    .help("See what would change without changing anything (⇧⌘R)")
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.runs.start(job.id, kind: .sync) }
                    .buttonStyle(.glassProminent)
                    .help("Run this sync now (⌘R)")
            }
        }
        .controlSize(.large)
    }
}

// MARK: - From → To

private struct RouteCard: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob

    var body: some View {
        Card {
            HStack(spacing: 12) {
                EndpointView(label: "From", endpoint: job.source)
                Image(systemName: job.mode == .mirror ? "arrow.right.circle.fill" : "arrow.right.circle")
                    .font(.title)
                    .foregroundStyle(job.mode == .mirror ? Color.orange : Color.accentColor)
                    .accessibilityLabel(job.mode == .mirror ? "mirrors to" : "copies to")
                EndpointView(label: "To", endpoint: job.destination)
            }
            Text(landingSentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var landingSentence: String {
        let landing = CommandBuilder.landingPath(for: job)
        let place = job.destination.isRemote
            ? "\(EndpointDescription(job.destination, model: model).subtitle.components(separatedBy: " · ").first ?? "the server"):\(landing)"
            : (landing as NSString).abbreviatingWithTildeInPath
        return job.copyFolderItself
            ? "The folder itself is copied, so files end up in \(place)/…"
            : "Only what's inside is copied, so files end up directly in \(place)/…"
    }
}

private struct EndpointView: View {
    @Environment(AppModel.self) private var model
    let label: String
    let endpoint: Endpoint

    var body: some View {
        let description = EndpointDescription(endpoint, model: model)
        HStack(spacing: 10) {
            Image(systemName: description.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Text(description.title).font(.headline).lineLimit(1)
                Text(description.subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(endpoint.path)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if case .local(let path, _) = endpoint {
                Button("Show in Finder") { FinderActions.reveal(path) }
            }
            Button("Copy Path") { FinderActions.copy(endpoint.path) }
        }
    }
}

// MARK: - Running

struct RunProgressCard: View {
    let run: LiveRun
    @State private var showLog = false

    var body: some View {
        Card(title: run.kind == .preview ? "Previewing" : "Syncing", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(run.isPaused ? "Paused" : run.phase.label).font(.title3.weight(.semibold))
                    Spacer()
                    if let progress = run.progress, run.phase == .transferring {
                        Text("\(progress.percent)%").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                if let progress = run.progress, run.phase == .transferring, !progress.stillScanning {
                    ProgressView(value: Double(progress.percent), total: 100)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }

                if let progress = run.progress, run.phase == .transferring {
                    Text(details(progress))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let change = run.latestChange {
                    Text(change.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !run.summary.isEmpty {
                    Text(run.summary.shortDescription).font(.callout)
                }

                DisclosureGroup("Details", isExpanded: $showLog) {
                    LogView(lines: run.logLines)
                        .frame(height: 220)
                }
                .font(.callout)
            }
        }
    }

    private func details(_ p: TransferProgress) -> String {
        var parts = ["\(p.bytesTransferred.bytes) copied"]
        if p.bytesPerSecond > 0 { parts.append("\(Int64(p.bytesPerSecond).bytes)/s") }
        if let total = p.filesTotal, let remaining = p.filesRemaining {
            parts.append("\((total - remaining).formatted()) of \(total.formatted())\(p.stillScanning ? "+" : "") items checked")
        }
        return parts.joined(separator: " · ")
    }
}

/// Scrolling monospaced log that follows new output.
struct LogView: View {
    let lines: [LiveRun.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.isError ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .background(.background, in: .rect(cornerRadius: 8))
            .onChange(of: lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Last run

private struct LastRunCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let job: SyncJob
    let showResults: (RunRecord) -> Void

    var body: some View {
        let _ = model.historyRevision
        let live = model.runs.liveRun(for: job.id)
        let record = live?.result?.record ?? model.lastRecord(for: job.id)
        let diagnosis = live?.result?.diagnosis

        if let record {
            Card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: record.outcome.symbol)
                        .font(.title)
                        .foregroundStyle(record.outcome.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.headline).font(.title3.weight(.semibold))
                        if let message = record.message {
                            Text(message).foregroundStyle(.secondary)
                        }
                        if let detail = diagnosis?.detail {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                    if live?.result != nil {
                        Button("Dismiss", systemImage: "xmark") { model.runs.dismiss(job.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Show the saved summary instead")
                    }
                }

                if record.outcome == .success || record.outcome == .warning {
                    HStack(spacing: 12) {
                        StatTile(value: record.summary.added.formatted(), label: "New", color: .green)
                        StatTile(value: record.summary.updated.formatted(), label: "Updated", color: .blue)
                        StatTile(value: record.summary.deleted.formatted(), label: "Deleted", color: record.summary.deleted > 0 ? .red : .primary)
                        StatTile(value: (record.stats?.transferredSize ?? 0).bytes, label: record.kind == .preview ? "To copy" : "Copied")
                        if let duration = record.duration {
                            StatTile(value: duration.shortDuration, label: "Took")
                        }
                    }
                }

                HStack {
                    if let fixIt = diagnosis?.fixIt {
                        fixItButton(fixIt)
                    }
                    Spacer()
                    if record.kind == .preview, record.outcome == .success, !record.summary.isEmpty {
                        Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                            model.runs.start(job.id, kind: .sync)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if record.outcome != .skipped {
                        Button(record.kind == .preview ? "Show Changes" : "Show Details") { showResults(record) }
                            .buttonStyle(.glass)
                    }
                }
            }
        } else {
            Card {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not synced yet").font(.title3.weight(.semibold))
                        Text(job.mode == .mirror
                             ? "Start with Preview to see exactly what would be copied and deleted."
                             : "Press Sync Now to copy the files, or Preview to see what would be copied first.")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles").font(.title).foregroundStyle(.tint)
                }
            }
        }
    }

    @ViewBuilder
    private func fixItButton(_ fixIt: Diagnosis.FixIt) -> some View {
        switch fixIt {
        case .grantFullDiskAccess:
            Button("Open Privacy Settings", systemImage: "lock.shield") { FinderActions.openFullDiskAccessSettings() }
                .help("Give \(AppInfo.name) Full Disk Access so it can read protected folders")
        case .trustHostKey, .setUpSSHKey, .checkServerAddress, .installRemoteRsync:
            Button("Check Server Settings", systemImage: "server.rack") { model.selection = .servers }
        case .chooseRsyncBinary:
            Button("Open Settings", systemImage: "gear") { openSettings() }
        case .reviewDeletions:
            Button("Preview Changes", systemImage: "eye") { model.runs.start(job.id, kind: .preview) }
        case .reviewExtraArguments:
            Button("Edit Sync", systemImage: "pencil") { model.edit(job.id) }
        case .freeUpSpace:
            EmptyView()
        }
    }
}

// MARK: - Schedule

private struct ScheduleCard: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob

    var body: some View {
        if let schedule = job.schedule {
            Card(title: "Schedule", systemImage: "calendar") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.rule.summary).font(.headline)
                        Group {
                            if !job.isEnabled {
                                Text("Paused. Scheduled runs won't happen until you resume.")
                            } else if let next = model.scheduler.nextRuns[job.id] {
                                Text("Next run \(next.formatted(.relative(presentation: .named))) (\(next.formatted(date: .abbreviated, time: .shortened)))")
                            }
                        }
                        .foregroundStyle(.secondary)
                        Text("Runs while \(AppInfo.name) is open or in the menu bar.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { job.isEnabled }, set: { model.setEnabled($0, for: job.id) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(job.isEnabled ? "Pause the schedule" : "Resume the schedule")
                }
            }
        }
    }
}

// MARK: - History

private struct HistoryCard: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob
    let showResults: (RunRecord) -> Void

    var body: some View {
        let _ = model.historyRevision
        let records = Array(model.records(for: job.id).prefix(10))
        if !records.isEmpty {
            Card(title: "History", systemImage: "clock") {
                VStack(spacing: 0) {
                    ForEach(records) { record in
                        Button { showResults(record) } label: {
                            HistoryRow(record: record)
                        }
                        .buttonStyle(.plain)
                        if record.id != records.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: RunRecord
    var showJob: SyncJob?

    var body: some View {
        HStack(spacing: 10) {
            if let job = showJob {
                SyncIcon(symbol: job.symbol, tint: job.tint, size: 22)
            }
            Image(systemName: record.outcome.symbol)
                .foregroundStyle(record.outcome.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let job = showJob { Text(job.name).fontWeight(.medium) }
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(showJob == nil ? .primary : .secondary)
                }
                Text(record.message ?? record.summary.shortDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(record.triggerLabel).font(.caption).foregroundStyle(.tertiary)
            if let duration = record.duration {
                Text(duration.shortDuration).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(minWidth: 50, alignment: .trailing)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }
}
