import SwiftUI
import SyncModel

/// The menu bar icon: still when idle, spinning while syncing, with a warning after failures.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        let running = model.runs.isAnyRunning
        Image(systemName: running ? "arrow.triangle.2.circlepath" : (hasRecentProblem ? "exclamationmark.triangle" : "water.waves"))
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: running)
            .accessibilityLabel(running ? "\(AppInfo.name): syncing" : AppInfo.name)
            .onAppear {
                // This view lives as long as the app, so it can reopen the main window for the delegate.
                appDelegate.openMainWindow = { openWindow(id: AppDelegate.mainWindowID) }
                appDelegate.attach(model)
            }
    }

    private var hasRecentProblem: Bool {
        let _ = model.historyRevision
        return model.jobs.contains { job in
            guard let last = model.lastSync(for: job.id) else { return false }
            return last.outcome == .failed
        }
    }
}

/// The menu bar window: every sync with its status and a one-click run.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(AppInfo.name).font(.headline)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.jobs.isEmpty {
                Text("No syncs yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.jobs) { job in
                            MenuBarRow(job: job, open: { open(job.id) })
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Open \(AppInfo.name)") { open(nil) }
                Spacer()
                Button("Settings…") {
                    dismiss()
                    NSApp.activate()
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private var statusText: String {
        let running = model.runs.runningCount
        if running > 0 { return "Syncing \(running)…" }
        if let next = model.scheduler.nextRuns.values.min() {
            return "Next \(next.formatted(.relative(presentation: .named)))"
        }
        return "Idle"
    }

    private func open(_ jobID: UUID?) {
        dismiss()
        if let jobID { model.selection = .sync(jobID) }
        (NSApp.delegate as? AppDelegate)?.showMainWindow()
    }
}

private struct MenuBarRow: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        let run = model.runs.liveRun(for: job.id)
        let running = run?.isRunning == true

        HStack(spacing: 10) {
            SyncIcon(symbol: job.symbol, tint: job.tint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                if running, let run {
                    if let progress = run.progress, run.phase == .transferring {
                        ProgressView(value: Double(progress.percent), total: 100).controlSize(.small)
                    } else {
                        Text(run.phase.label).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    let _ = model.historyRevision
                    Text(model.lastSync(for: job.id)?.headline ?? "Never synced")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let last = model.lastSync(for: job.id), !running, last.outcome == .failed || last.outcome == .warning {
                Image(systemName: last.outcome.symbol).foregroundStyle(last.outcome.color)
            }
            Button {
                if running { model.runs.stop(job.id) } else { model.runs.start(job.id, kind: .sync) }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(running ? "Stop" : "Sync now")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .accessibilityAction(named: "Open", open)
    }
}
