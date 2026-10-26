import AppKit
import SwiftUI
import SyncModel

/// The colored rounded-square icon that identifies a sync.
struct SyncIcon: View {
    var symbol: String
    var tint: SyncTint
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            }
            .accessibilityHidden(true)
    }
}

/// A rounded card with Liquid Glass styling used for detail sections.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "")
                    .labelStyle(TitleOnlyIfNoIcon(hasIcon: systemImage != nil))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct TitleOnlyIfNoIcon: LabelStyle {
    var hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        if hasIcon { Label(configuration) } else { configuration.title }
    }
}

/// Small rounded label like "Mirror" or "3 new".
struct Pill: View {
    var text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: .capsule)
    }
}

/// Count with a caption, used in run summaries.
struct StatTile: View {
    var value: String
    var label: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum FinderActions {
    static func reveal(_ path: String) {
        let url = URL(filePath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Folder picker. Returns the chosen path, or nil if cancelled.
    @MainActor
    static func chooseFolder(prompt: String = "Choose", startingAt path: String? = nil, canChooseFiles: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = canChooseFiles
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.showsHiddenFiles = false
        if let path, !path.isEmpty { panel.directoryURL = URL(filePath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseFile(prompt: String = "Choose", startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = prompt
        if let path { panel.directoryURL = URL(filePath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
