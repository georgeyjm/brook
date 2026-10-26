import Foundation

/// The one place the product name lives in code. (Also: project.yml, Info.plist.)
enum AppInfo {
    static let name = "Brook"

    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// User preferences stored in `UserDefaults`.
enum Preferences {
    static let customRsyncPathKey = "customRsyncPath"
    static let notifyOnSuccessKey = "notifyOnSuccess"
    static let historyLimitKey = "historyLimit"
    static let showMenuBarExtraKey = "showMenuBarExtra"

    static func register() {
        UserDefaults.standard.register(defaults: [
            notifyOnSuccessKey: false,
            historyLimitKey: 50,
            showMenuBarExtraKey: true,
        ])
    }

    static var customRsyncPath: String? {
        let value = UserDefaults.standard.string(forKey: customRsyncPathKey)
        return value?.isEmpty == false ? value : nil
    }

    static var notifyOnSuccess: Bool { UserDefaults.standard.bool(forKey: notifyOnSuccessKey) }
    static var historyLimit: Int { max(5, UserDefaults.standard.integer(forKey: historyLimitKey)) }
}
