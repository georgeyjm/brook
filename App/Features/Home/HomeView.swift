import SwiftUI
import SyncModel

/// The home screen. With no syncs it's a welcome page; otherwise it's an overview of every
/// sync plus quick ways to start a new one.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if model.jobs.isEmpty {
                    WelcomeHero()
                } else {
                    StatusHeader()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your Syncs").font(.title3.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(model.jobs) { job in
                                SyncCard(job: job)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    if !model.jobs.isEmpty {
                        Text("Start Something New").font(.title3.weight(.semibold))
                    }
                    TemplateRow()
                    Label("Or drop a folder anywhere in this window", systemImage: "hand.point.up.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }
}

// MARK: - Header

private struct WelcomeHero: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "water.waves")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.wiggle, options: .nonRepeating)
            Text("Keep your files in sync")
                .font(.largeTitle.weight(.bold))
            Text("Copy folders to a drive, a server or another folder, by hand or on a schedule.\nOnly what changed is copied, so it's fast after the first time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

/// "Everything is up to date" / "1 sync needs attention" / "Syncing…".
private struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.historyRevision
        let problems = model.jobs.filter { job in
            guard let last = model.lastSync(for: job.id) else { return false }
            return last.outcome == .failed || last.outcome == .warning || last.outcome == .skipped
        }
        let running = model.runs.runningCount

        HStack(spacing: 16) {
            Image(systemName: running > 0 ? "arrow.triangle.2.circlepath.circle.fill"
                  : problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(running > 0 ? Color.accentColor : problems.isEmpty ? Color.green : Color.orange)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: running > 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(running: running, problems: problems.count))
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func title(running: Int, problems: Int) -> String {
        if running > 0 { return running == 1 ? "Syncing…" : "Syncing \(running) folders…" }
        if problems > 0 { return problems == 1 ? "1 sync needs attention" : "\(problems) syncs need attention" }
        return "Everything looks good"
    }

    private var subtitle: String {
        if let next = model.scheduler.nextRuns.values.min() {
            return "Next scheduled sync \(next.formatted(.relative(presentation: .named))), \(next.formatted(date: .omitted, time: .shortened))."
        }
        return "\(model.jobs.count) sync\(model.jobs.count == 1 ? "" : "s"), none scheduled."
    }
}

// MARK: - Sync cards

private struct SyncCard: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob
    @State private var isHovered = false

    var body: some View {
        let _ = model.historyRevision
        let run = model.runs.liveRun(for: job.id)
        let running = run?.isRunning == true
        let last = model.lastSync(for: job.id)

        HStack(alignment: .top, spacing: 12) {
            SyncIcon(symbol: job.symbol, tint: job.tint, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline).lineLimit(1)
                if running, let run {
                    if let progress = run.progress, run.phase == .transferring {
                        ProgressView(value: Double(progress.percent), total: 100)
                    } else {
                        Text(run.phase.label).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        if let last {
                            Image(systemName: last.outcome.symbol).foregroundStyle(last.outcome.color)
                        }
                        Text(last?.headline ?? "Never synced").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                if let next = model.scheduler.nextRuns[job.id], job.isEnabled, !running {
                    Label("Next \(next.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button {
                if running { model.runs.stop(job.id) } else { model.runs.start(job.id, kind: .sync) }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(running ? "Stop" : "Sync now")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isHovered ? 0.5 : 0), lineWidth: 1.5)
        }
        .contentShape(.rect(cornerRadius: 16))
        .onHover { isHovered = $0 }
        .onTapGesture { model.selection = .sync(job.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(job.name)
        .accessibilityAction { model.selection = .sync(job.id) }
    }
}

// MARK: - Templates

private struct TemplateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TemplateCard(
                title: "Back up to a drive",
                detail: "Copy a folder to an external drive. Nothing at the destination is ever deleted.",
                symbol: "externaldrive.fill", tint: .blue
            ) { start(.driveBackup) }
            TemplateCard(
                title: "Mirror to a server",
                detail: "Keep an exact copy on a NAS or server over SSH, including deletions.",
                symbol: "server.rack", tint: .purple
            ) { start(.mirrorToServer) }
            TemplateCard(
                title: "Download from a server",
                detail: "Bring a folder from a server to this Mac and keep it up to date.",
                symbol: "arrow.down.circle.fill", tint: .green
            ) { start(.downloadFromServer) }
        }
    }

    private enum Template { case driveBackup, mirrorToServer, downloadFromServer }

    private func start(_ template: Template) {
        let firstHost = model.hosts.first?.id
        var job = SyncJob(name: "", source: .local(""), destination: .local(""))
        switch template {
        case .driveBackup:
            job.symbol = "externaldrive.fill"
            job.tint = .blue
            job.mode = .copy
        case .mirrorToServer:
            job.symbol = "server.rack"
            job.tint = .purple
            job.mode = .mirror
            if let firstHost { job.destination = .remote(hostID: firstHost, path: "") }
        case .downloadFromServer:
            job.symbol = "arrow.down.circle.fill"
            job.tint = .green
            job.copyFolderItself = false
            if let firstHost { job.source = .remote(hostID: firstHost, path: "") }
        }
        model.editor = AppModel.EditorRequest(job: job, isNew: true)
    }
}

private struct TemplateCard: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: SyncTint
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SyncIcon(symbol: symbol, tint: tint, size: 40)
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .contentShape(.rect)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .scaleEffect(isHovered ? 1.02 : 1)
            .animation(.snappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
