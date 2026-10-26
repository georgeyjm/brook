import AppKit
import Foundation
import RsyncCore
import SyncModel
import UserNotifications

/// Posts run results as system notifications.
///
/// Policy: failures, warnings and skipped scheduled runs always notify. Successful
/// scheduled runs only notify when the user opted in. Manual runs notify only when the
/// app isn't in front (otherwise the window already shows the result).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Called when the user clicks a notification for a sync.
    var onOpenJob: ((UUID) -> Void)?

    private var center: UNUserNotificationCenter { .current() }
    private var requestedAuthorization = false

    func activate() {
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(record: RunRecord, jobName: String, diagnosis: Diagnosis?) {
        guard record.kind == .sync, record.outcome != .cancelled, record.outcome != .running else { return }

        let isManual = record.trigger == .manual
        if isManual && NSApp.isActive { return }
        if record.outcome == .success && !isManual && !Preferences.notifyOnSuccess { return }

        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = jobName
        content.body = Self.body(for: record, diagnosis: diagnosis)
        content.userInfo = ["jobID": record.jobID.uuidString]
        if record.outcome == .failed { content.sound = .default }

        center.add(UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }

    static func body(for record: RunRecord, diagnosis: Diagnosis?) -> String {
        switch record.outcome {
        case .success:
            let s = record.summary
            let changed = s.added + s.updated + s.deleted
            return changed == 0 ? "Already up to date." : "Synced \(changed.formatted()) changed item\(changed == 1 ? "" : "s")."
        case .warning: return diagnosis?.title ?? record.message ?? "Finished with warnings."
        case .failed: return diagnosis?.title ?? record.message ?? "The sync failed."
        case .skipped: return record.message ?? "The sync was skipped."
        case .cancelled, .running: return ""
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let idString = response.notification.request.content.userInfo["jobID"] as? String,
              let jobID = UUID(uuidString: idString) else { return }
        await MainActor.run {
            NSApp.activate()
            self.onOpenJob?(jobID)
        }
    }
}
