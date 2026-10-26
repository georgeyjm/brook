import AppKit
import RsyncCore
import SwiftUI
import SyncModel

/// What a preview or sync changed, file by file.
struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: SyncJob
    let record: RunRecord

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", added = "New", updated = "Updated", deleted = "Deleted"
        var id: Self { self }
    }

    @State private var changes: [FileChange]?
    @State private var filter: Filter = .all
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
        .task { await loadChanges() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.outcome.symbol)
                .font(.largeTitle)
                .foregroundStyle(record.outcome.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.kind == .preview ? "Preview of “\(job.name)”" : "“\(job.name)”")
                    .font(.title2.weight(.semibold))
                Text("\(record.outcome.label) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.triggerLabel)")
                    .foregroundStyle(.secondary)
                if let message = record.message {
                    Text(message).foregroundStyle(.secondary)
                }
                if record.kind == .preview {
                    Text("Nothing was changed. This is what a sync would do.")
                        .font(.callout).foregroundStyle(.tint)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if let changes {
            let visible = filtered(changes)
            VStack(spacing: 0) {
                HStack {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { f in
                            Text("\(f.rawValue) (\(count(f, in: changes).formatted()))").tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TextField("Filter by name", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                .padding(12)

                if visible.isEmpty {
                    ContentUnavailableView(
                        changes.isEmpty ? "No changes" : "No matches",
                        systemImage: changes.isEmpty ? "checkmark.circle" : "magnifyingglass",
                        description: Text(changes.isEmpty ? "Everything was already up to date." : "Try a different filter.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(visible.indices, id: \.self) { index in
                        ChangeRow(change: visible[index])
                            .contextMenu { rowMenu(visible[index]) }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        } else {
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Button("Show Log", systemImage: "doc.text") {
                NSWorkspace.shared.open(model.history.logURL(for: record))
            }
            .disabled(!FileManager.default.fileExists(atPath: model.history.logURL(for: record).path))
            Spacer()
            if record.kind == .preview, record.outcome == .success, !record.summary.isEmpty, !model.runs.isRunning(job.id) {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    dismiss()
                    model.runs.start(job.id, kind: .sync)
                }
                .buttonStyle(.glassProminent)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private func rowMenu(_ change: FileChange) -> some View {
        if let path = localPath(for: change) {
            Button("Show in Finder") { FinderActions.reveal(path) }
        }
        Button("Copy Path") { FinderActions.copy(localPath(for: change) ?? change.path) }
    }

    // MARK: - Data

    private func filtered(_ changes: [FileChange]) -> [FileChange] {
        changes.filter { change in
            let kindMatches = switch filter {
            case .all: change.kind != .metadata || change.itemType != .directory
            case .added: change.kind == .added
            case .updated: change.kind == .updated || (change.kind == .metadata && change.itemType != .directory)
            case .deleted: change.kind == .deleted
            }
            return kindMatches && (search.isEmpty || change.path.localizedCaseInsensitiveContains(search))
        }
    }

    private func count(_ filter: Filter, in changes: [FileChange]) -> Int {
        switch filter {
        case .all: changes.count { $0.kind != .metadata || $0.itemType != .directory }
        case .added: changes.count { $0.kind == .added }
        case .updated: changes.count { $0.kind == .updated || ($0.kind == .metadata && $0.itemType != .directory) }
        case .deleted: changes.count { $0.kind == .deleted }
        }
    }

    /// Where the item lives on this Mac: the destination after a sync, the source in a preview.
    private func localPath(for change: FileChange) -> String? {
        func root(_ endpoint: Endpoint, isSource: Bool) -> String? {
            guard case .local(let path, _) = endpoint else { return nil }
            var base = path
            while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
            // With "copy the folder itself" the itemized paths start with the folder's name.
            if isSource && job.copyFolderItself { base = (base as NSString).deletingLastPathComponent }
            return base
        }
        let useSource = record.kind == .preview && change.kind != .deleted
        guard let base = useSource ? root(job.source, isSource: true) : root(job.destination, isSource: false) else { return nil }
        return (base as NSString).appendingPathComponent(change.path)
    }

    private func loadChanges() async {
        if let live = model.runs.liveRun(for: job.id), live.result?.record.id == record.id {
            changes = live.changes
            return
        }
        let url = model.history.logURL(for: record)
        changes = await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [FileChange]() }
            return text.split(whereSeparator: \.isNewline).compactMap { ItemizeParser.parse(String($0)) }
        }.value
    }
}

private struct ChangeRow: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kindSymbol)
                .foregroundStyle(kindColor)
                .frame(width: 18)
                .accessibilityLabel(kindLabel)
            Image(systemName: itemSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(change.path)
                .lineLimit(1)
                .truncationMode(.middle)
            if let target = change.linkTarget {
                Text("→ \(target)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(kindLabel).font(.caption).foregroundStyle(.tertiary)
        }
        .help(change.path)
    }

    private var kindSymbol: String {
        switch change.kind {
        case .added: "plus.circle.fill"
        case .updated: "arrow.triangle.2.circlepath.circle.fill"
        case .deleted: "minus.circle.fill"
        case .metadata: "info.circle"
        }
    }

    private var kindColor: Color {
        switch change.kind {
        case .added: .green
        case .updated: .blue
        case .deleted: .red
        case .metadata: .secondary
        }
    }

    private var kindLabel: String {
        switch change.kind {
        case .added: "New"
        case .updated: "Updated"
        case .deleted: "Deleted"
        case .metadata: "Details changed"
        }
    }

    private var itemSymbol: String {
        switch change.itemType {
        case .directory: "folder"
        case .symlink: "link"
        default: "doc"
        }
    }
}
