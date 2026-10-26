import RsyncCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") { GeneralSettings() }
            Tab("rsync", systemImage: "terminal") { RsyncSettings() }
        }
        .frame(width: 540, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.showMenuBarExtraKey) private var showMenuBarExtra = true
    @AppStorage(Preferences.notifyOnSuccessKey) private var notifyOnSuccess = false
    @AppStorage(Preferences.historyLimitKey) private var historyLimit = 50
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
            } footer: {
                Text("Scheduled syncs run while \(AppInfo.name) is open or in the menu bar. With the menu bar icon on, closing the window keeps \(AppInfo.name) running in the background.")
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify when scheduled syncs succeed", isOn: $notifyOnSuccess)
                Text("You're always notified about failures, warnings and skipped runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Stepper("Keep the last \(historyLimit) runs of each sync", value: $historyLimit, in: 5...1000, step: 5)
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change this: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct RsyncSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.customRsyncPathKey) private var customPath = ""

    var body: some View {
        Form {
            Section {
                switch model.rsyncStatus {
                case .locating:
                    HStack { ProgressView().controlSize(.small); Text("Looking for rsync…") }
                case .missing:
                    Label("No usable rsync was found.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case .ready(let binary):
                    LabeledContent("Version", value: binary.capabilities.isOpenRsync
                                   ? "openrsync (\(binary.capabilities.version?.description ?? "?")-compatible)"
                                   : "rsync \(binary.capabilities.version?.description ?? "?")")
                    LabeledContent("Location") {
                        Text(binary.url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("Source", value: originLabel(binary.origin))
                    if binary.capabilities.isOpenRsync {
                        Label("macOS's built-in rsync lacks features \(AppInfo.name) relies on (live progress, creation dates). Install rsync with Homebrew or use the bundled one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            } header: {
                Text("In use")
            }

            Section {
                HStack {
                    TextField("Custom rsync", text: $customPath, prompt: Text("Automatic"))
                    Button("Choose…") {
                        if let path = FinderActions.chooseFile(startingAt: "/opt/homebrew/bin") { customPath = path }
                    }
                    if !customPath.isEmpty {
                        Button("Use Automatic") { customPath = "" }
                    }
                }
                .onChange(of: customPath) { Task { await model.locateRsync() } }
            } header: {
                Text("Binary")
            } footer: {
                Text("Automatic uses the rsync bundled with \(AppInfo.name), then Homebrew's.")
                    .foregroundStyle(.secondary)
            }

            Section("License") {
                Text("rsync is free software by Andrew Tridgell, Wayne Davison and others, distributed under the GNU General Public License v3. Its source code is available at rsync.samba.org.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("rsync source code", destination: URL(string: "https://rsync.samba.org/")!)
            }
        }
        .formStyle(.grouped)
    }

    private func originLabel(_ origin: RsyncBinary.Origin) -> String {
        switch origin {
        case .bundled: "Bundled with \(AppInfo.name)"
        case .homebrew: "Homebrew"
        case .custom: "Custom"
        case .system: "macOS"
        }
    }
}
