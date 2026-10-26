import Foundation

/// When a sync runs automatically.
public struct JobSchedule: Codable, Hashable, Sendable {
    public var rule: ScheduleRule
    /// If the Mac was asleep or the app wasn't running at the scheduled time,
    /// run once as soon as possible afterwards.
    public var catchUpMissedRuns: Bool
    public var isPaused: Bool
    /// When the schedule was set or last edited. Occurrences before this never count as missed.
    public var since: Date

    public init(rule: ScheduleRule, catchUpMissedRuns: Bool = true, isPaused: Bool = false, since: Date = Date()) {
        self.rule = rule
        self.catchUpMissedRuns = catchUpMissedRuns
        self.isPaused = isPaused
        self.since = since
    }
}

public enum ScheduleRule: Codable, Hashable, Sendable {
    /// Every N hours, counted from the last run (or from when the schedule was set).
    case hourly(every: Int)
    case daily(at: TimeOfDay)
    case weekly(days: Set<Weekday>, at: TimeOfDay)
    /// `day` is clamped to the month's last day (31 → Feb 28/29).
    case monthly(day: Int, at: TimeOfDay)
}

public struct TimeOfDay: Codable, Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

/// Matches `Calendar` weekday numbering (1 = Sunday … 7 = Saturday).
public enum Weekday: Int, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}
