import RsyncCore
import SwiftUI
import SyncEngine
import SyncModel

/// Create or edit a sync. Basics first; Options and Advanced are collapsed, and the exact
/// rsync command is always visible at the bottom.
struct SyncEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var job: SyncJob
    @State private var extraArgumentsText: String
    @State private var showOptions = false
    @State private var showAdvanced = false
    @State private var newServerSide: EndpointSide?
    let isNew: Bool

    init(request: AppModel.EditorRequest) {
        _job = State(initialValue: request.job)
        _extraArgumentsText = State(initialValue: ShellWords.join(request.job.options.extraArguments))
        isNew = request.isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                IdentitySection(job: $job)
                LocationsSection(job: $job, onAddServer: { newServerSide = $0 })
                ModeSection(job: $job)
                ScheduleSection(job: $job)
                OptionsSection(job: $job, isExpanded: $showOptions)
                AdvancedSection(job: $job, extraArgumentsText: $extraArgumentsText,
                                extraArgumentsError: extraArgumentsError, isExpanded: $showAdvanced)
            }
            .formStyle(.grouped)

            CommandPreview(job: jobForPreview)
            footer
        }
        .frame(width: 640)
        .frame(minHeight: 560, idealHeight: 780)
        .sheet(item: $newServerSide) { side in
            HostEditorView(host: RemoteHost(name: "", hostname: ""), isNew: true) { host in
                let endpoint = Endpoint.remote(hostID: host.id, path: "")
                if side == .source { job.source = endpoint } else { job.destination = endpoint }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create Sync" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(validationProblem != nil)
        }
        .padding(16)
    }

    // MARK: - Validation & saving

    private var parsedExtraArguments: Result<[String], ShellWords.SplitError> {
        Result { () throws(ShellWords.SplitError) -> [String] in try ShellWords.split(extraArgumentsText) }
    }

    private var extraArgumentsError: String? {
        if case .failure = parsedExtraArguments { return "A quote isn't closed." }
        return nil
    }

    private var jobForPreview: SyncJob {
        var preview = job
        if case .success(let args) = parsedExtraArguments { preview.options.extraArguments = args }
        return preview
    }

    private var validationProblem: String? {
        if job.source.isRemote && job.destination.isRemote {
            return "One side must be a folder on this Mac."
        }
        if case .local(let path, _) = job.source, path.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose what to sync."
        }
        if case .local(let path, _) = job.destination, path.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose where to sync to."
        }
        for endpoint in [job.source, job.destination] {
            if let hostID = endpoint.hostID, model.host(id: hostID) == nil { return "Choose a server." }
        }
        if !job.source.isRemote && !job.destination.isRemote {
            let source = (job.source.path as NSString).standardizingPath
            let destination = (job.destination.path as NSString).standardizingPath
            if source == destination { return "The source and destination are the same folder." }
            if destination.hasPrefix(source + "/") && job.filters.isEmpty {
                return "The destination is inside the source, which would copy it into itself."
            }
        }
        if extraArgumentsError != nil { return "Fix the extra rsync arguments." }
        return nil
    }

    private func save() {
        var result = jobForPreview
        result.name = result.name.trimmingCharacters(in: .whitespaces)
        if result.name.isEmpty {
            let folder = (result.source.path as NSString).lastPathComponent
            result.name = folder.isEmpty ? "Untitled Sync" : folder
        }
        result.source = refreshVolume(result.source)
        result.destination = refreshVolume(result.destination)
        model.save(job: result)
        dismiss()
    }

    /// Records which drive a local folder is on, so we can later tell "drive not connected"
    /// apart from "empty folder". Keeps the old identity when the drive isn't mounted now.
    private func refreshVolume(_ endpoint: Endpoint) -> Endpoint {
        guard case .local(let path, let old) = endpoint else { return endpoint }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return .local(path: expanded, volume: old) }
        return .local(path: expanded, volume: SystemVolumes.identity(forPath: expanded))
    }
}

enum EndpointSide: String, Identifiable {
    case source, destination
    var id: Self { self }
}

// MARK: - Identity

private struct IdentitySection: View {
    @Binding var job: SyncJob
    @State private var showIconPicker = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Button { showIconPicker = true } label: {
                    SyncIcon(symbol: job.symbol, tint: job.tint, size: 40)
                }
                .buttonStyle(.plain)
                .help("Change icon and color")
                .popover(isPresented: $showIconPicker) { IconPicker(symbol: $job.symbol, tint: $job.tint) }

                TextField(text: $job.name, prompt: Text("Name this sync")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct IconPicker: View {
    @Binding var symbol: String
    @Binding var tint: SyncTint

    static let symbols = [
        "folder.fill", "externaldrive.fill", "internaldrive.fill", "server.rack", "cloud.fill", "archivebox.fill",
        "photo.fill", "camera.fill", "film.fill", "music.note", "doc.fill", "books.vertical.fill",
        "briefcase.fill", "house.fill", "laptopcomputer", "desktopcomputer", "terminal.fill", "hammer.fill",
        "gamecontroller.fill", "heart.fill", "star.fill", "tray.full.fill", "shippingbox.fill", "arrow.down.circle.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(SyncTint.allCases, id: \.self) { color in
                    Circle()
                        .fill(color.color.gradient)
                        .frame(width: 22, height: 22)
                        .overlay { if color == tint { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        .onTapGesture { tint = color }
                        .accessibilityLabel(color.rawValue)
                        .accessibilityAddTraits(.isButton)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 6), spacing: 8) {
                ForEach(Self.symbols, id: \.self) { name in
                    Button { symbol = name } label: {
                        Image(systemName: name)
                            .font(.title3)
                            .frame(width: 34, height: 34)
                            .background(name == symbol ? tint.color.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Locations

private struct LocationsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var job: SyncJob
    var onAddServer: (EndpointSide) -> Void

    var body: some View {
        Section("What to sync") {
            EndpointEditor(label: "From", endpoint: $job.source, chooseTitle: "Choose Folder to Sync",
                           onAddServer: { onAddServer(.source) })
            EndpointEditor(label: "To", endpoint: $job.destination, chooseTitle: "Choose Destination",
                           onAddServer: { onAddServer(.destination) })
            HStack {
                Spacer()
                Button("Swap From and To", systemImage: "arrow.up.arrow.down") {
                    let source = job.source
                    job.source = job.destination
                    job.destination = source
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }
}

private struct EndpointEditor: View {
    @Environment(AppModel.self) private var model
    let label: String
    @Binding var endpoint: Endpoint
    let chooseTitle: String
    var onAddServer: () -> Void

    private enum Location: Hashable {
        case mac
        case host(UUID)
        case addServer
    }

    private var location: Binding<Location> {
        Binding {
            endpoint.hostID.map { .host($0) } ?? .mac
        } set: { newValue in
            switch newValue {
            case .mac where endpoint.isRemote: endpoint = .local("")
            case .host(let id): endpoint = .remote(hostID: id, path: endpoint.isRemote ? endpoint.path : "")
            case .addServer: onAddServer()
            default: break
            }
        }
    }

    var body: some View {
        Picker(label, selection: location) {
            Label("This Mac", systemImage: "laptopcomputer").tag(Location.mac)
            if !model.hosts.isEmpty {
                Divider()
                ForEach(model.hosts) { host in
                    Label(host.name, systemImage: "server.rack").tag(Location.host(host.id))
                }
            }
            Divider()
            Label("Add Server…", systemImage: "plus").tag(Location.addServer)
        }

        switch endpoint {
        case .local(let path, let volume):
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    if path.isEmpty {
                        Text("None chosen").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: volume != nil || path.hasPrefix("/Volumes/") ? "externaldrive.fill" : "folder.fill")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .help(path)
                    }
                    Button("Choose…") {
                        if let chosen = FinderActions.chooseFolder(prompt: "Choose", startingAt: path.isEmpty ? nil : path) {
                            endpoint = .local(path: chosen, volume: SystemVolumes.identity(forPath: chosen))
                        }
                    }
                }
            }
        case .remote(let hostID, let path):
            TextField("Folder on server", text: Binding(
                get: { path },
                set: { endpoint = .remote(hostID: hostID, path: $0) }
            ), prompt: Text("/path/to/folder (empty = home folder)"))
        }
    }
}

// MARK: - Mode

private struct ModeSection: View {
    @Environment(AppModel.self) private var model
    @Binding var job: SyncJob

    var body: some View {
        Section("How") {
            HStack(spacing: 10) {
                ModeCard(
                    isSelected: job.mode == .copy,
                    title: "Copy new & changed",
                    detail: "Adds and updates files. Never deletes anything at the destination.",
                    symbol: "arrow.right.doc.on.clipboard",
                    color: .accentColor
                ) { job.mode = .copy }
                ModeCard(
                    isSelected: job.mode == .mirror,
                    title: "Mirror",
                    detail: "Makes the destination identical, deleting files that aren't in the source.",
                    symbol: "arrow.left.and.right.square",
                    color: .orange
                ) { job.mode = .mirror }
            }
            .padding(.vertical, 4)

            Picker("Copy", selection: $job.copyFolderItself) {
                Text("The folder itself").tag(true)
                Text("Only what's inside it").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()

            if !job.destination.path.isEmpty && !(job.source.path.isEmpty && !job.source.isRemote) {
                Label {
                    Text("Files will end up in \(Text(landing).fontWeight(.medium))/…")
                } icon: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var landing: String {
        let path = (CommandBuilder.landingPath(for: job) as NSString).abbreviatingWithTildeInPath
        if let hostID = job.destination.hostID, let host = model.host(id: hostID) { return "\(host.name):\(path)" }
        return path
    }
}

private struct ModeCard: View {
    var isSelected: Bool
    var title: String
    var detail: String
    var symbol: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(isSelected ? color : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? color : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? color.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? color : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Schedule

private struct ScheduleSection: View {
    @Binding var job: SyncJob

    private enum Kind: String, CaseIterable, Identifiable {
        case manual = "Only when I click Sync"
        case hourly = "Every few hours"
        case daily = "Every day"
        case weekly = "On certain days"
        case monthly = "Every month"
        var id: Self { self }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch job.schedule?.rule {
            case nil: .manual
            case .hourly?: .hourly
            case .daily?: .daily
            case .weekly?: .weekly
            case .monthly?: .monthly
            }
        } set: { newKind in
            let time = currentTime
            let rule: ScheduleRule? = switch newKind {
            case .manual: nil
            case .hourly: .hourly(every: 4)
            case .daily: .daily(at: time)
            case .weekly: .weekly(days: [.monday, .wednesday, .friday], at: time)
            case .monthly: .monthly(day: 1, at: time)
            }
            if let rule {
                var schedule = job.schedule ?? JobSchedule(rule: rule)
                schedule.rule = rule
                job.schedule = schedule
            } else {
                job.schedule = nil
            }
        }
    }

    private var currentTime: TimeOfDay {
        switch job.schedule?.rule {
        case .daily(let t)?, .weekly(_, let t)?, .monthly(_, let t)?: t
        default: TimeOfDay(hour: 21, minute: 0)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            currentTime.date
        } set: { date in
            let time = TimeOfDay(date: date)
            switch job.schedule?.rule {
            case .daily?: job.schedule?.rule = .daily(at: time)
            case .weekly(let days, _)?: job.schedule?.rule = .weekly(days: days, at: time)
            case .monthly(let day, _)?: job.schedule?.rule = .monthly(day: day, at: time)
            default: break
            }
        }
    }

    var body: some View {
        Section {
            Picker("Run", selection: kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }

            switch job.schedule?.rule {
            case .hourly(let every)?:
                Stepper("Every \(every) hour\(every == 1 ? "" : "s")",
                        value: Binding(get: { every }, set: { job.schedule?.rule = .hourly(every: $0) }), in: 1...24)
            case .daily?:
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            case .weekly(let days, let time)?:
                LabeledContent("On") {
                    HStack(spacing: 4) {
                        ForEach(Weekday.localeOrdered, id: \.self) { day in
                            let isOn = days.contains(day)
                            Button(day.veryShortName) {
                                var newDays = days
                                if isOn { newDays.remove(day) } else { newDays.insert(day) }
                                if !newDays.isEmpty { job.schedule?.rule = .weekly(days: newDays, at: time) }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 28)
                            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                            .foregroundStyle(isOn ? .white : .primary)
                            .accessibilityLabel(day.shortName)
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                }
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            case .monthly(let day, let time)?:
                Stepper("On day \(day)\(day > 28 ? " (or the month's last day)" : "")",
                        value: Binding(get: { day }, set: { job.schedule?.rule = .monthly(day: $0, at: time) }), in: 1...31)
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            case nil:
                EmptyView()
            }

            if job.schedule != nil {
                Toggle("Catch up on runs missed while the Mac was asleep or off",
                       isOn: Binding(get: { job.schedule?.catchUpMissedRuns ?? true },
                                     set: { job.schedule?.catchUpMissedRuns = $0 }))
            }
        } header: {
            Text("When")
        } footer: {
            if job.schedule != nil {
                Text("Scheduled syncs run while \(AppInfo.name) is open or in the menu bar.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Options

private struct OptionsSection: View {
    @Binding var job: SyncJob
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    FiltersEditor(filters: $job.filters)
                    Divider()

                    Toggle("Keep Finder tags and other file metadata", isOn: $job.options.preserveExtendedAttributes)
                        .help("--xattrs")
                    Toggle("Keep creation dates", isOn: $job.options.preserveCreationDates)
                        .help("--crtimes")
                    Toggle("Compare file contents, not just size and date", isOn: $job.options.compareByChecksum)
                        .help("--checksum: slower, but catches changes that keep the same size and date")
                    Toggle("Don't overwrite files that are newer at the destination", isOn: $job.options.skipNewerAtDestination)
                        .help("--update")
                    Toggle("Resume big files if interrupted", isOn: $job.options.keepPartialFiles)
                        .help("--partial")
                    Toggle("Compress while transferring (helps on slow networks)", isOn: $job.options.compress)
                        .help("--compress")
                    Toggle("Stay on one drive (skip other mounted volumes)", isOn: $job.options.stayOnOneFileSystem)
                        .help("--one-file-system")

                    HStack {
                        Toggle("Limit speed to", isOn: Binding(
                            get: { job.options.bandwidthLimitKBps != nil },
                            set: { job.options.bandwidthLimitKBps = $0 ? 5_000 : nil }
                        ))
                        TextField("KB/s", value: $job.options.bandwidthLimitKBps, format: .number)
                            .frame(width: 90)
                            .disabled(job.options.bandwidthLimitKBps == nil)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                    .help("--bwlimit")

                    HStack {
                        Toggle("Keep replaced files in", isOn: Binding(
                            get: { job.options.backupDirectory != nil },
                            set: { job.options.backupDirectory = $0 ? ".replaced" : nil }
                        ))
                        TextField("Folder", text: Binding(
                            get: { job.options.backupDirectory ?? "" },
                            set: { job.options.backupDirectory = $0 }
                        ))
                        .disabled(job.options.backupDirectory == nil)
                    }
                    .help("--backup --backup-dir: overwritten and deleted files are moved here (relative to the destination) instead of being lost")

                    if job.mode == .mirror {
                        Divider()
                        SafetyEditor(safety: $job.safety)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct FiltersEditor: View {
    @Binding var filters: [FilterRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skip these files").font(.headline)
                Spacer()
                Menu("Add", systemImage: "plus") {
                    Button("Custom Rule") { filters.append(FilterRule(pattern: "")) }
                    Divider()
                    ForEach(FilterRule.presets, id: \.pattern) { preset in
                        Button(preset.title) { filters.append(FilterRule(pattern: preset.pattern)) }
                            .disabled(filters.contains { $0.pattern == preset.pattern })
                    }
                }
                .fixedSize()
            }
            if filters.isEmpty {
                Text("Everything is copied. Add rules to skip things like caches or .DS_Store files.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($filters) { $rule in
                HStack {
                    Picker("", selection: $rule.kind) {
                        Text("Skip").tag(FilterRule.Kind.exclude)
                        Text("Always copy").tag(FilterRule.Kind.include)
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Pattern", text: $rule.pattern, prompt: Text("*.tmp, Caches/, /top-level-only"))
                        .font(.body.monospaced())
                    Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
                        .help("Enabled")
                    Button("Remove", systemImage: "minus.circle.fill") { filters.removeAll { $0.id == rule.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            if !filters.isEmpty {
                Text("Rules apply top to bottom. A trailing / matches folders only; a leading / matches from the top of the sync.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SafetyEditor: View {
    @Binding var safety: SafetySettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mirror safety").font(.headline)
            Toggle("Ask before deleting many files", isOn: $safety.deletionGuardEnabled)
            if safety.deletionGuardEnabled {
                Stepper("More than \(safety.maxDeletedFiles.formatted()) files", value: $safety.maxDeletedFiles, in: 1...1_000_000, step: 50)
                    .padding(.leading, 20)
                Stepper("Or more than \(Int(safety.maxDeletedFraction * 100))% of the destination",
                        value: Binding(get: { Int(safety.maxDeletedFraction * 100) }, set: { safety.maxDeletedFraction = Double($0) / 100 }),
                        in: 1...100, step: 5)
                    .padding(.leading, 20)
                Text("Scheduled runs that would delete more are skipped and you're notified.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
            Toggle("Require a preview before the first sync", isOn: $safety.requirePreviewBeforeFirstMirror)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSection: View {
    @Binding var job: SyncJob
    @Binding var extraArgumentsText: String
    var extraArgumentsError: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra rsync arguments").font(.headline)
                        TextField("", text: $extraArgumentsText, prompt: Text("--numeric-ids --exclude='My Folder'"))
                            .font(.body.monospaced())
                        if let extraArgumentsError {
                            Text(extraArgumentsError).font(.caption).foregroundStyle(.red)
                        } else {
                            Text("Added as-is, after \(AppInfo.name)'s own options. Quote values with spaces.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Keep ACLs (access control lists)", isOn: $job.options.preserveACLs)
                        .help("--acls")
                    Toggle("Keep hard links", isOn: $job.options.preserveHardLinks)
                        .help("--hard-links")
                    if job.mode == .mirror {
                        Toggle("Also delete skipped files at the destination", isOn: $job.options.deleteExcluded)
                            .help("--delete-excluded")
                    }

                    Divider()
                    HookEditor(title: "Before sync", text: Binding(get: { job.hooks.beforeRun ?? "" },
                                                                    set: { job.hooks.beforeRun = $0.isEmpty ? nil : $0 }))
                    Toggle("Don't sync if this command fails", isOn: $job.hooks.abortIfBeforeRunFails)
                        .disabled(job.hooks.beforeRun == nil)
                    HookEditor(title: "After sync", text: Binding(get: { job.hooks.afterRun ?? "" },
                                                                   set: { job.hooks.afterRun = $0.isEmpty ? nil : $0 }))
                    Text("Shell commands run with zsh. Available variables: $SYNC_NAME, $SYNC_SOURCE, $SYNC_DESTINATION, $SYNC_TRIGGER, and $SYNC_EXIT_CODE (after sync).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

private struct HookEditor: View {
    var title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(height: 48)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.secondary, in: .rect(cornerRadius: 6))
        }
    }
}

// MARK: - Command preview

private struct CommandPreview: View {
    @Environment(AppModel.self) private var model
    let job: SyncJob

    var body: some View {
        let (command, error) = build()
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Command", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let command {
                    Button("Copy", systemImage: "doc.on.doc") { FinderActions.copy(command) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Copy the rsync command")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command ?? error ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(command == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background.secondary)
    }

    private func build() -> (String?, String?) {
        let executable = model.rsync?.url.path ?? "rsync"
        let context = CommandBuilder.Context(hosts: model.hosts, capabilities: model.rsync?.capabilities ?? .assumedModern)
        do {
            let args = try CommandBuilder.arguments(for: job, context: context)
            return (CommandBuilder.displayString(executable: executable, arguments: args), nil)
        } catch {
            return (nil, "The command appears once both sides are chosen.")
        }
    }
}
