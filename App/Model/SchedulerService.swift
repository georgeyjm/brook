import AppKit
import Foundation
import Observation
import SyncModel
import SyncScheduler

/// Fires scheduled syncs while the app is running (window open or just in the menu bar).
/// Wakes at the next due time, after the Mac wakes from sleep, and whenever syncs change.
@Observable @MainActor
final class SchedulerService {
    /// Next scheduled run per job, for "Next: Tomorrow 09:00".
    private(set) var nextRuns: [UUID: Date] = [:]

    private weak var model: AppModel?
    private var timer: Task<Void, Never>?
    private var lastTriggered: [UUID: Date] = [:]
    private var isStarted = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// Never sleep longer than this, so clock and time-zone changes self-correct.
    private static let maxSleep: Duration = .seconds(15 * 60)

    init(model: AppModel) {
        self.model = model
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
    }

    /// Call once rsync has been located.
    func start() {
        isStarted = true
        reschedule()
    }

    func reschedule() {
        guard isStarted, let model else { return }
        timer?.cancel()

        let entries = model.jobs.compactMap { job -> SchedulePlanner.Entry? in
            guard job.isEnabled, let schedule = job.schedule else { return nil }
            let recorded = model.lastSync(for: job.id)?.startedAt
            let triggered = lastTriggered[job.id]
            let lastAttempt = [recorded, triggered].compactMap { $0 }.max()
            return SchedulePlanner.Entry(jobID: job.id, schedule: schedule, lastAttempt: lastAttempt)
        }

        let now = Date()
        let plan = SchedulePlanner.plan(entries, now: now)
        for jobID in plan.due { trigger(jobID, as: .scheduled, at: now) }
        for jobID in plan.missed { trigger(jobID, as: .catchUp, at: now) }

        // Recompute "next run" labels after triggering.
        nextRuns = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            let last = [entry.lastAttempt, lastTriggered[entry.jobID]].compactMap { $0 }.max()
            guard !entry.schedule.isPaused,
                  let next = ScheduleCalculator.nextRun(for: entry.schedule, lastRun: last) else { return nil }
            return (entry.jobID, next)
        })

        let wake = nextRuns.values.min()
        timer = Task { [weak self] in
            let delay = wake.map { Duration.seconds(max(1, $0.timeIntervalSinceNow)) } ?? Self.maxSleep
            try? await Task.sleep(for: min(delay, Self.maxSleep))
            guard !Task.isCancelled else { return }
            self?.reschedule()
        }
    }

    private func trigger(_ jobID: UUID, as trigger: RunTrigger, at date: Date) {
        guard let model, !model.runs.isRunning(jobID) else { return }
        lastTriggered[jobID] = date
        model.runs.start(jobID, kind: .sync, trigger: trigger)
    }
}
