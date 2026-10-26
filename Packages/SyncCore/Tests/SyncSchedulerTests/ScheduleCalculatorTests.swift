import Foundation
import SyncModel
import Testing
@testable import SyncScheduler

@Suite struct ScheduleCalculatorTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func dailyLaterTodayThenTomorrow() {
        let rule = ScheduleRule.daily(at: TimeOfDay(hour: 9, minute: 30))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 8), anchor: .distantPast, calendar: calendar) == date(2026, 5, 4, 9, 30))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 9, 30), anchor: .distantPast, calendar: calendar) == date(2026, 5, 5, 9, 30))
    }

    @Test func dailyInsideDSTGapMovesForward() throws {
        // 29 Mar 2026: clocks jump 02:00 → 03:00 in Berlin.
        let rule = ScheduleRule.daily(at: TimeOfDay(hour: 2, minute: 30))
        let next = try #require(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 3, 29, 0), anchor: .distantPast, calendar: calendar))
        #expect(calendar.component(.day, from: next) == 29)
        #expect(calendar.component(.hour, from: next) == 3)
    }

    @Test func weeklyPicksNearestDay() {
        // 4 May 2026 is a Monday.
        let rule = ScheduleRule.weekly(days: [.wednesday, .saturday], at: TimeOfDay(hour: 20, minute: 0))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 12), anchor: .distantPast, calendar: calendar) == date(2026, 5, 6, 20))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 6, 21), anchor: .distantPast, calendar: calendar) == date(2026, 5, 9, 20))
        #expect(ScheduleCalculator.nextOccurrence(of: .weekly(days: [], at: TimeOfDay(hour: 1, minute: 0)), after: date(2026, 5, 4), anchor: .distantPast, calendar: calendar) == nil)
    }

    @Test func monthlyClampsToLastDay() {
        let rule = ScheduleRule.monthly(day: 31, at: TimeOfDay(hour: 23, minute: 0))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 2, 1), anchor: .distantPast, calendar: calendar) == date(2026, 2, 28, 23))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 2, 28, 23), anchor: .distantPast, calendar: calendar) == date(2026, 3, 31, 23))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2028, 2, 1), anchor: .distantPast, calendar: calendar) == date(2028, 2, 29, 23))
    }

    @Test func hourlyCountsFromAnchor() {
        let anchor = date(2026, 5, 4, 10, 15)
        let rule = ScheduleRule.hourly(every: 3)
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 11), anchor: anchor, calendar: calendar) == date(2026, 5, 4, 13, 15))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 13, 15), anchor: anchor, calendar: calendar) == date(2026, 5, 4, 16, 15))
        #expect(ScheduleCalculator.nextOccurrence(of: rule, after: date(2026, 5, 4, 9), anchor: anchor, calendar: calendar) == date(2026, 5, 4, 13, 15))
    }

    @Test func newScheduleDoesNotCountEarlierTimesAsMissed() {
        let schedule = JobSchedule(rule: .daily(at: TimeOfDay(hour: 9, minute: 0)), since: date(2026, 5, 4, 10))
        #expect(ScheduleCalculator.nextRun(for: schedule, lastRun: nil, calendar: calendar) == date(2026, 5, 5, 9))
    }
}

@Suite struct SchedulePlannerTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: d, hour: h, minute: mi))!
    }

    @Test func dueMissedAndNextWake() {
        let daily9 = JobSchedule(rule: .daily(at: TimeOfDay(hour: 9, minute: 0)), since: date(1, 0))
        let onTime = SchedulePlanner.Entry(jobID: UUID(), schedule: daily9, lastAttempt: date(2, 9))
        let missed = SchedulePlanner.Entry(jobID: UUID(), schedule: daily9, lastAttempt: date(1, 9))
        var noCatchUp = missed
        noCatchUp.jobID = UUID()
        noCatchUp.schedule.catchUpMissedRuns = false
        var paused = onTime
        paused.jobID = UUID()
        paused.schedule.isPaused = true
        let later = SchedulePlanner.Entry(jobID: UUID(), schedule: JobSchedule(rule: .daily(at: TimeOfDay(hour: 18, minute: 0)), since: date(3, 9)), lastAttempt: nil)

        // Now is 3 June 09:01: `onTime` ran yesterday so today's 09:00 is due; `missed` last ran on the 1st.
        let plan = SchedulePlanner.plan([onTime, missed, noCatchUp, paused, later], now: date(3, 9, 1), calendar: calendar)
        #expect(plan.due == [onTime.jobID])
        // `missed`'s first unrun occurrence (2 June 09:00) is long past.
        #expect(plan.missed == [missed.jobID])
        #expect(plan.nextWake == date(3, 18))
    }
}
