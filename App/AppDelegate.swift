import AppKit
import SwiftUI

/// App lifecycle: keep running in the menu bar when the window closes (so schedules keep
/// firing), hide the Dock icon while windowless, and confirm before quitting mid-sync.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    private(set) weak var model: AppModel?
    /// Set by a view that has `openWindow`, so the delegate can reopen the main window.
    var openMainWindow: (() -> Void)?
    private var windowObserver: NSObjectProtocol?

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        NotificationService.shared.onOpenJob = { [weak self] jobID in
            self?.showMainWindow()
            model.selection = .sync(jobID)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With the menu bar icon hidden there is no way back in, so quit like a normal app.
        !UserDefaults.standard.bool(forKey: Preferences.showMenuBarExtraKey)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.runs.isAnyRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop syncing and quit?"
        alert.informativeText = "\(model.runs.runningCount) sync\(model.runs.runningCount == 1 ? " is" : "s are") still running. Quitting stops \(model.runs.runningCount == 1 ? "it" : "them"); you can run \(model.runs.runningCount == 1 ? "it" : "them") again later."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.runs.stopAll()
        return .terminateNow
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.mainWindowID && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate()
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard window?.identifier?.rawValue == Self.mainWindowID,
              UserDefaults.standard.bool(forKey: Preferences.showMenuBarExtraKey) else { return }
        // Live on in the menu bar without a Dock icon.
        DispatchQueue.main.async {
            let hasOtherWindows = NSApp.windows.contains { $0.isVisible && $0 != window && $0.canBecomeMain }
            if !hasOtherWindows { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
