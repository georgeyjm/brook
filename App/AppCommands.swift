import SwiftUI

/// Menu bar commands and keyboard shortcuts.
struct AppCommands: Commands {
    let model: AppModel

    private var selectedJobID: UUID? {
        if case .sync(let id)? = model.selection { id } else { nil }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Sync…") { model.newJob() }
                .keyboardShortcut("n")
        }

        CommandMenu("Sync") {
            let id = selectedJobID
            let running = id.map(model.runs.isRunning) ?? false

            Button("Sync Now") { if let id { model.runs.start(id, kind: .sync) } }
                .keyboardShortcut("r")
                .disabled(id == nil || running)
            Button("Preview Changes") { if let id { model.runs.start(id, kind: .preview) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(id == nil || running)
            Button("Stop") { if let id { model.runs.stop(id) } }
                .keyboardShortcut(".")
                .disabled(!running)

            Divider()

            Button("Edit…") { if let id { model.edit(id) } }
                .keyboardShortcut("e")
                .disabled(id == nil)
            Button("Duplicate") { if let id { model.duplicate(id) } }
                .keyboardShortcut("d")
                .disabled(id == nil)
        }
    }
}
