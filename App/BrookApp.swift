import SwiftUI

@main
struct BrookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @AppStorage(Preferences.showMenuBarExtraKey) private var showMenuBarExtra = true

    init() {
        Preferences.register()
        let model = AppModel()
        _model = State(initialValue: model)
        NotificationService.shared.activate()
    }

    var body: some Scene {
        Window(AppInfo.name, id: AppDelegate.mainWindowID) {
            RootView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear { appDelegate.attach(model) }
        }
        .defaultSize(width: 1040, height: 700)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(appDelegate: appDelegate)
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
