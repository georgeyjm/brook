import SwiftUI
import SyncEngine
import SyncModel
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model
        @Bindable var runs = model.runs

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailRouter()
        }
        .sheet(item: $model.editor) { request in
            SyncEditorView(request: request)
        }
        .sheet(item: $runs.pendingConfirmation) { pending in
            ConfirmationSheet(pending: pending)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            model.newJob(prefilledSource: folder.path)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .overlay {
                        Label("Drop a folder to create a sync", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding()
                            .glassEffect()
                    }
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .padding(12)
                    .glassEffect(.regular.tint(.red.opacity(0.3)))
                    .padding()
            }
        }
    }
}

private struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .sync(let id) where model.job(id: id) != nil:
            SyncDetailView(jobID: id)
                .id(id)
        case .activity:
            ActivityView()
        case .servers:
            ServersView()
        default:
            HomeView()
        }
    }
}

/// Asks before a risky run proceeds ("This would delete 2,000 files").
private struct ConfirmationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingConfirmation

    private var jobName: String { model.job(id: pending.jobID)?.name ?? "This sync" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(pending.issue.message).foregroundStyle(.secondary)
                    if case .tooManyDeletions = pending.issue.kind {
                        Text("Deleted files are removed from the destination, not moved to the Trash.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if pending.kind == .sync {
                    Button("Preview Changes") {
                        dismiss()
                        model.runs.start(pending.jobID, kind: .preview, confirmations: pending.alreadyConfirmed)
                    }
                }
                Button(confirmTitle, role: .destructive) {
                    dismiss()
                    model.runs.confirm(pending)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var symbol: String {
        switch pending.issue.kind {
        case .firstMirrorNeedsPreview: "eye.trianglebadge.exclamationmark"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch pending.issue.kind {
        case .tooManyDeletions: "\(jobName) would delete a lot of files"
        case .emptySourceMirror: "The source folder is empty"
        case .firstMirrorNeedsPreview: "Preview before the first mirror?"
        default: "Continue?"
        }
    }

    private var confirmTitle: String {
        switch pending.issue.kind {
        case .firstMirrorNeedsPreview: "Sync Without Preview"
        default: "Sync Anyway"
        }
    }
}
