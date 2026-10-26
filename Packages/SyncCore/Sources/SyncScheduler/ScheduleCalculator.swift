import Foundation
import SyncModel

/// Pure date maths for schedules. All functions take an explicit calendar so DST and
/// time-zone behaviour is testable.
public enum ScheduleCalculator {
    /// The first scheduled time strictly after `date`.
    public static func nextOccurrence(of rule: ScheduleRule, after date: Date, anchor: Date, calendar: Calendar = .current) -> Date? {
        switch rule {
        case .hourly(let every):
            let interval = TimeInterval(max(1, every) * 3600)
            guard date >= anchor else { return anchor.addingTimeInterval(interval) }
            let steps = floor(date.timeIntervalSince(anchor) / interval) + 1
            return anchor.addingTimeInterval(steps * interval)

        case .daily(let time):
            return calendar.nextDate(
                after: date,
                matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                matchingPolicy: .nextTime
            )

        case .weekly(let days, let time):
            return days.compactMap { day in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(hour: time.hour, minute: time.minute, second: 0, weekday: day.rawValue),
                    matchingPolicy: .nextTime
                )
            }.min()

        case .monthly(let day, let time):
            guard let monthStart = calendar.dateInterval(of: .month, for: date)?.start else { return nil }
            for offset in 0..<24 {
                guard let month = calendar.date(byAdding: .month, value: offset, to: monthStart),
                      let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count else { continue }
                var components = calendar.dateComponents([.year, .month], from: month)
                components.day = min(max(1, day), daysInMonth)
                components.hour = time.hour
                components.minute = time.minute
                components.second = 0
                // Resolve DST gaps the same way as `nextDate(…, .nextTime)`.
                guard let dayStart = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day)),
                      let candidate = calendar.nextDate(
                        after: dayStart.addingTimeInterval(-1),
                        matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                        matchingPolicy: .nextTime
                      ) else { continue }
                if candidate > date { return candidate }
            }
            return nil
        }
    }

    /// When a job is next due, given its last run (if any).
    public static func nextRun(for schedule: JobSchedule, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        let reference = max(lastRun ?? schedule.since, schedule.since)
        let anchor = lastRun.map { max($0, schedule.since) } ?? schedule.since
        return nextOccurrence(of: schedule.rule, after: reference, anchor: anchor, calendar: calendar)
    }
}

/// Decides which jobs to run now and when to wake next.
public enum SchedulePlanner {
    public struct Entry: Sendable {
        public var jobID: UUID
        public var schedule: JobSchedule
        /// Last time the job ran a sync (any trigger) or was skipped by a scheduled attempt.
        public var lastAttempt: Date?

        public init(jobID: UUID, schedule: JobSchedule, lastAttempt: Date?) {
            self.jobID = jobID
            self.schedule = schedule
            self.lastAttempt = lastAttempt
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Jobs whose scheduled time is now (within `tolerance`).
        public var due: [UUID]
        /// Jobs whose scheduled time passed while the app/Mac wasn't running.
        public var missed: [UUID]
        public var nextWake: Date?
    }

    /// - Parameter tolerance: how late a run may start and still count as on time rather than missed.
    public static func plan(_ entries: [Entry], now: Date, tolerance: TimeInterval = 120, calendar: Calendar = .current) -> Plan {
        var due: [UUID] = []
        var missed: [UUID] = []
        var nextWake: Date?

        for entry in entries where !entry.schedule.isPaused {
            guard let next = ScheduleCalculator.nextRun(for: entry.schedule, lastRun: entry.lastAttempt, calendar: calendar) else { continue }
            if next <= now {
                if now.timeIntervalSince(next) <= tolerance {
                    due.append(entry.jobID)
                } else if entry.schedule.catchUpMissedRuns {
                    missed.append(entry.jobID)
                }
                // Either way, the following occurrence is the next wake-up for this job.
                if let following = ScheduleCalculator.nextOccurrence(of: entry.schedule.rule, after: now, anchor: entry.lastAttempt ?? entry.schedule.since, calendar: calendar) {
                    nextWake = min(nextWake ?? following, following)
                }
            } else {
                nextWake = min(nextWake ?? next, next)
            }
        }
        return Plan(due: due, missed: missed, nextWake: nextWake)
    }
}
