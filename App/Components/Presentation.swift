import SwiftUI
import SyncEngine
import SyncModel

extension SyncTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .gray: .gray
        }
    }
}

extension RunOutcome {
    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        case .skipped: "forward.end.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: .accentColor
        case .success: .green
        case .warning: .orange
        case .failed: .red
        case .cancelled, .skipped: .secondary
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .success: "Succeeded"
        case .warning: "Finished with warnings"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .skipped: "Skipped"
        }
    }
}

extension RunRecord {
    /// "Synced 2 hours ago", "Preview failed yesterday"…
    var headline: String {
        let date = finishedAt ?? startedAt
        let when = abs(date.timeIntervalSinceNow) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
        switch (kind, outcome) {
        case (.sync, .success): return "Synced \(when)"
        case (.preview, .success): return "Previewed \(when)"
        case (_, .warning): return "\(kind == .sync ? "Synced" : "Previewed") with warnings \(when)"
        case (_, .failed): return "\(kind == .sync ? "Sync" : "Preview") failed \(when)"
        case (_, .cancelled): return "Stopped \(when)"
        case (_, .skipped): return "Skipped \(when)"
        case (_, .running): return "Running"
        }
    }

    var triggerLabel: String {
        switch trigger {
        case .manual: kind == .preview ? "Preview" : "Manual"
        case .scheduled: "Scheduled"
        case .catchUp: "Catch-up"
        }
    }
}

extension ChangeSummary {
    var shortDescription: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added.formatted()) new") }
        if updated > 0 { parts.append("\(updated.formatted()) updated") }
        if deleted > 0 { parts.append("\(deleted.formatted()) deleted") }
        if parts.isEmpty { return metadataOnly > 0 ? "Only file details changed" : "No changes" }
        return parts.joined(separator: " · ")
    }
}

extension SessionPhase {
    var label: String {
        switch self {
        case .checking: "Checking…"
        case .runningBeforeHook: "Running “before sync” command…"
        case .estimatingDeletions: "Checking what would be deleted…"
        case .transferring: "Syncing…"
        case .runningAfterHook: "Running “after sync” command…"
        }
    }
}

extension Int64 {
    var bytes: String { formatted(.byteCount(style: .file)) }
}

extension TimeInterval {
    /// "about 3 min", "12 s"
    var shortDuration: String {
        Duration.seconds(self).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// Plain-language description of a sync endpoint.
struct EndpointDescription {
    var title: String
    var subtitle: String
    var symbol: String

    @MainActor
    init(_ endpoint: Endpoint, model: AppModel) {
        switch endpoint {
        case .local(let path, let volume):
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            title = trimmed.isEmpty ? "Choose a folder" : ((trimmed as NSString).lastPathComponent.isEmpty ? trimmed : (trimmed as NSString).lastPathComponent)
            if let volume {
                subtitle = "\(volume.name) · \((trimmed as NSString).abbreviatingWithTildeInPath)"
                symbol = "externaldrive.fill"
            } else {
                subtitle = trimmed.isEmpty ? "On this Mac" : (trimmed as NSString).abbreviatingWithTildeInPath
                symbol = trimmed.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill"
            }
        case .remote(let hostID, let path):
            let host = model.host(id: hostID)
            let name = (path as NSString).lastPathComponent
            title = name.isEmpty || name == "~" ? (host?.name ?? "Server") : name
            subtitle = "\(host?.name ?? "Missing server") · \(path.isEmpty ? "home folder" : path)"
            symbol = "server.rack"
        }
    }
}

extension JobSchedule {
    var summary: String {
        let prefix = isPaused ? "Paused · " : ""
        return prefix + rule.summary
    }
}

extension ScheduleRule {
    var summary: String {
        switch self {
        case .hourly(let every): every == 1 ? "Every hour" : "Every \(every) hours"
        case .daily(let time): "Daily at \(time.formatted)"
        case .weekly(let days, let time):
            days.count == 7 ? "Daily at \(time.formatted)" : "\(Weekday.listDescription(days)) at \(time.formatted)"
        case .monthly(let day, let time): "Monthly on day \(day) at \(time.formatted)"
        }
    }
}

extension TimeOfDay {
    var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    var formatted: String { date.formatted(date: .omitted, time: .shortened) }
}

extension Weekday {
    var shortName: String { Calendar.current.shortWeekdaySymbols[rawValue - 1] }
    var veryShortName: String { Calendar.current.veryShortWeekdaySymbols[rawValue - 1] }

    /// Weekdays in the user's locale order (e.g. Monday first in Europe).
    static var localeOrdered: [Weekday] {
        let first = Calendar.current.firstWeekday
        return (0..<7).compactMap { Weekday(rawValue: (first - 1 + $0) % 7 + 1) }
    }

    static func listDescription(_ days: Set<Weekday>) -> String {
        if days == [.monday, .tuesday, .wednesday, .thursday, .friday] { return "Weekdays" }
        if days == [.saturday, .sunday] { return "Weekends" }
        return localeOrdered.filter(days.contains).map(\.shortName).formatted(.list(type: .and))
    }
}
