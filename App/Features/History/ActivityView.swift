import SwiftUI
import SyncModel

/// Every run of every sync, newest first, grouped by day.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [RunRecord] = []
    @State private var selected: RunRecord?
    @State private var showFailuresOnly = false

    var body: some View {
        let visible = showFailuresOnly ? records.filter { $0.outcome == .failed || $0.outcome == .warning || $0.outcome == .skipped } : records
        Group {
            if visible.isEmpty {
                ContentUnavailableView(
                    showFailuresOnly ? "No problems" : "No activity yet",
                    systemImage: showFailuresOnly ? "checkmark.seal" : "clock.arrow.circlepath",
                    description: Text(showFailuresOnly ? "Every run finished without issues." : "Runs appear here after you sync or preview.")
                )
            } else {
                List {
                    ForEach(groupedByDay(visible), id: \.day) { section in
                        Section(section.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                            ForEach(section.records) { record in
                                Button { selected = record } label: {
                                    HistoryRow(record: record, showJob: model.job(id: record.jobID))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Toggle("Problems Only", systemImage: "exclamationmark.triangle", isOn: $showFailuresOnly)
                    .help("Show only failed, skipped and warning runs")
            }
        }
        .task(id: model.historyRevision) {
            let history = model.history
            records = await Task.detached { history.allRecords(limit: 500) }.value
        }
        .sheet(item: $selected) { record in
            if let job = model.job(id: record.jobID) {
                ResultsView(job: job, record: record)
            }
        }
    }

    private func groupedByDay(_ records: [RunRecord]) -> [(day: Date, records: [RunRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: records) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }
}
