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

/// "From → To" as two tiles side by side, with a swap button between them.
private struct LocationsSection: View {
    @Binding var job: SyncJob
    var onAddServer: (EndpointSide) -> Void

    var body: some View {
        Section("What to sync") {
            HStack(alignment: .center, spacing: 10) {
                EndpointTile(title: "From", endpoint: $job.source, emptyTitle: "Choose a folder to sync",
                             onAddServer: { onAddServer(.source) })
                VStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(job.mode == .mirror ? Color.orange : Color.accentColor)
                        .accessibilityHidden(true)
                    Button("Swap", systemImage: "arrow.left.arrow.right") {
                        let source = job.source
                        job.source = job.destination
                        job.destination = source
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Swap From and To")
                }
                EndpointTile(title: "To", endpoint: $job.destination, emptyTitle: "Choose where to copy to",
                             onAddServer: { onAddServer(.destination) })
            }
            .padding(.vertical, 4)
        }
    }
}

/// One side of a sync: a folder on this Mac (click to choose, or drop a folder on it) or a
/// path on a server. The corner menu switches between the two.
private struct EndpointTile: View {
    @Environment(AppModel.self) private var model
    let title: String
    @Binding var endpoint: Endpoint
    let emptyTitle: String
    var onAddServer: () -> Void

    @State private var isDropTargeted = false

    private var isEmpty: Bool { !endpoint.isRemote && endpoint.path.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                locationMenu
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isEmpty || isDropTargeted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1),
                              style: StrokeStyle(lineWidth: isEmpty || isDropTargeted ? 1.5 : 1, dash: isEmpty ? [5, 4] : []))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            endpoint = .local(path: folder.path, volume: SystemVolumes.identity(forPath: folder.path))
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch endpoint {
        case .local(let path, let volume):
            Button { choose(startingAt: path) } label: {
                HStack(spacing: 10) {
                    Image(systemName: path.isEmpty ? "folder.badge.plus"
                          : (volume != nil || path.hasPrefix("/Volumes/")) ? "externaldrive.fill" : "folder.fill")
                        .font(.title2)
                        .foregroundStyle(path.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.isEmpty ? emptyTitle : (path as NSString).lastPathComponent)
                            .font(.headline)
                            .foregroundStyle(path.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        Text(path.isEmpty ? "or drop a folder here" : subtitle(path: path, volume: volume))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(path.isEmpty ? "Choose a folder" : "\(path)\nClick to choose a different folder")

        case .remote(let hostID, let path):
            VStack(alignment: .leading, spacing: 4) {
                TextField(text: Binding(get: { path }, set: { endpoint = .remote(hostID: hostID, path: $0) }),
                          prompt: Text("Home folder")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Text("A folder on \(model.host(id: hostID)?.name ?? "the server"), like /volume1/photos or ~/Documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var locationMenu: some View {
        let hostID = endpoint.hostID
        let currentName = hostID.flatMap { model.host(id: $0)?.name } ?? "This Mac"
        return Menu {
            Button("This Mac", systemImage: "laptopcomputer") {
                if endpoint.isRemote { endpoint = .local("") }
            }
            if !model.hosts.isEmpty {
                Section("Servers") {
                    ForEach(model.hosts) { host in
                        Button(host.name, systemImage: "server.rack") {
                            endpoint = .remote(hostID: host.id, path: endpoint.isRemote ? endpoint.path : "")
                        }
                    }
                }
            }
            Divider()
            Button("Add Server…", systemImage: "plus", action: onAddServer)
        } label: {
            Label(currentName, systemImage: hostID == nil ? "laptopcomputer" : "server.rack")
                .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Choose whether this side is on this Mac or a server")
    }

    private func subtitle(path: String, volume: VolumeIdentity?) -> String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        if let volume { return "On \(volume.name) · \(parent)" }
        return parent
    }

    private func choose(startingAt path: String) {
        if let chosen = FinderActions.chooseFolder(prompt: "Choose", startingAt: path.isEmpty ? nil : path) {
            endpoint = .local(path: chosen, volume: SystemVolumes.identity(forPath: chosen))
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
        case manual = "Manually"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
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
            Picker("Run", selection: kind.animation(.snappy)) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 2)

            switch job.schedule?.rule {
            case nil:
                Text("Runs only when you click Sync Now.")
                    .foregroundStyle(.secondary)
            case .hourly(let every)?:
                Stepper("Every \(every) hour\(every == 1 ? "" : "s")",
                        value: Binding(get: { every }, set: { job.schedule?.rule = .hourly(every: $0) }), in: 1...24)
            case .daily?:
                DatePicker("Every day at", selection: timeBinding, displayedComponents: .hourAndMinute)
            case .weekly(let days, let time)?:
                LabeledContent("On") {
                    WeekdayPicker(days: days) { job.schedule?.rule = .weekly(days: $0, at: time) }
                }
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            case .monthly(let day, let time)?:
                Stepper("On day \(day)\(day > 28 ? " (or the month's last day)" : "")",
                        value: Binding(get: { day }, set: { job.schedule?.rule = .monthly(day: $0, at: time) }), in: 1...31)
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
            }

            if job.schedule != nil {
                Toggle(isOn: Binding(get: { job.schedule?.catchUpMissedRuns ?? true },
                                     set: { job.schedule?.catchUpMissedRuns = $0 })) {
                    Text("Catch up on missed runs")
                    Text("If the Mac was asleep or off at the scheduled time, sync as soon as possible afterwards.")
                }
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

private struct WeekdayPicker: View {
    let days: Set<Weekday>
    let onChange: (Set<Weekday>) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Weekday.localeOrdered, id: \.self) { day in
                let isOn = days.contains(day)
                Button(day.veryShortName) {
                    var newDays = days
                    if isOn { newDays.remove(day) } else { newDays.insert(day) }
                    if !newDays.isEmpty { onChange(newDays) }
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
}

// MARK: - Collapsible sections

/// A whole-row, clickable section heading with a one-line summary of what's inside.
private struct CollapsibleHeader: View {
    let title: String
    let symbol: String
    let summary: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides \(title.lowercased())")
    }
}

// MARK: - Options

private struct OptionsSection: View {
    @Binding var job: SyncJob
    @Binding var isExpanded: Bool

    private var summary: String {
        var parts: [String] = []
        let rules = job.filters.filter { $0.isEnabled && !$0.pattern.isEmpty }.count
        if rules > 0 { parts.append("\(rules) skip rule\(rules == 1 ? "" : "s")") }
        if job.options.compareByChecksum { parts.append("compares contents") }
        if job.options.bandwidthLimitKBps != nil { parts.append("speed limit") }
        if job.options.backupDirectory != nil { parts.append("keeps replaced files") }
        if job.options.compress { parts.append("compressed") }
        return parts.isEmpty ? "Skip files, speed limit, file details" : parts.joined(separator: " · ").capitalizedFirst
    }

    var body: some View {
        Section {
            CollapsibleHeader(title: "Options", symbol: "slider.horizontal.3", summary: summary, isExpanded: $isExpanded)

            if isExpanded {
                FilterRows(filters: $job.filters)

                Toggle(isOn: $job.options.preserveExtendedAttributes) {
                    Text("Keep Finder tags and file metadata")
                }
                .help("--xattrs")
                Toggle("Keep creation dates", isOn: $job.options.preserveCreationDates)
                    .help("--crtimes")
                Toggle(isOn: $job.options.compareByChecksum) {
                    Text("Compare file contents")
                    Text("Slower, but catches changes that keep the same size and date.")
                }
                .help("--checksum")
                Toggle("Don't overwrite newer files at the destination", isOn: $job.options.skipNewerAtDestination)
                    .help("--update")
                Toggle(isOn: $job.options.keepPartialFiles) {
                    Text("Resume big files if interrupted")
                }
                .help("--partial")
                Toggle(isOn: $job.options.compress) {
                    Text("Compress while transferring")
                    Text("Helps on slow networks; slows down fast ones.")
                }
                .help("--compress")
                Toggle(isOn: $job.options.stayOnOneFileSystem) {
                    Text("Stay on one drive")
                    Text("Skip other drives that are mounted inside the source.")
                }
                .help("--one-file-system")

                Toggle("Limit transfer speed", isOn: Binding(
                    get: { job.options.bandwidthLimitKBps != nil },
                    set: { job.options.bandwidthLimitKBps = $0 ? 5_000 : nil }
                ))
                .help("--bwlimit")
                if job.options.bandwidthLimitKBps != nil {
                    LabeledContent("Maximum speed") {
                        HStack(spacing: 6) {
                            TextField(value: $job.options.bandwidthLimitKBps, format: .number) { EmptyView() }
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("KB/s").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 16)
                }

                Toggle(isOn: Binding(
                    get: { job.options.backupDirectory != nil },
                    set: { job.options.backupDirectory = $0 ? ".replaced" : nil }
                )) {
                    Text("Keep replaced and deleted files")
                    Text("Move them into a folder at the destination instead of discarding them.")
                }
                .help("--backup --backup-dir")
                if job.options.backupDirectory != nil {
                    LabeledContent("Folder name") {
                        TextField(text: Binding(get: { job.options.backupDirectory ?? "" },
                                                set: { job.options.backupDirectory = $0 }),
                                  prompt: Text(".replaced")) { EmptyView() }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }
                    .padding(.leading, 16)
                }

                if job.mode == .mirror {
                    SafetyRows(safety: $job.safety)
                }
            }
        }
    }
}

/// "Skip files" rules: a sub-heading row with an Add menu, then one row per rule.
private struct FilterRows: View {
    @Binding var filters: [FilterRule]

    var body: some View {
        LabeledContent {
            Menu("Add Rule", systemImage: "plus") {
                Button("Custom Pattern") { filters.append(FilterRule(pattern: "")) }
                Section("Common") {
                    ForEach(FilterRule.presets, id: \.pattern) { preset in
                        Button(preset.title) { filters.append(FilterRule(pattern: preset.pattern)) }
                            .disabled(filters.contains { $0.pattern == preset.pattern })
                    }
                }
            }
            .menuStyle(.button)
            .fixedSize()
        } label: {
            Text("Skip files")
            Text(filters.isEmpty
                 ? "Everything is copied. Add rules to skip things like caches or .DS_Store files."
                 : "Rules apply top to bottom. End with / to match folders only; start with / to match only at the top level.")
        }

        ForEach($filters) { $rule in
            HStack(spacing: 8) {
                Picker(selection: $rule.kind) {
                    Text("Skip").tag(FilterRule.Kind.exclude)
                    Text("Always copy").tag(FilterRule.Kind.include)
                } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
                .help("Skip matching files, or always copy them even if a later rule would skip them")

                TextField(text: $rule.pattern, prompt: Text("e.g. *.tmp or Caches/")) { EmptyView() }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Button("Remove Rule", systemImage: "xmark.circle.fill") {
                    withAnimation(.snappy) { filters.removeAll { $0.id == rule.id } }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
        }
    }
}

private struct SafetyRows: View {
    @Binding var safety: SafetySettings

    var body: some View {
        Toggle(isOn: $safety.deletionGuardEnabled) {
            Text("Ask before deleting many files")
            Text("Scheduled runs that would delete more are skipped, and you're notified.")
        }
        if safety.deletionGuardEnabled {
            Stepper("More than \(safety.maxDeletedFiles.formatted()) files", value: $safety.maxDeletedFiles, in: 1...1_000_000, step: 50)
                .padding(.leading, 16)
            Stepper("Or more than \(Int(safety.maxDeletedFraction * 100))% of the destination",
                    value: Binding(get: { Int(safety.maxDeletedFraction * 100) }, set: { safety.maxDeletedFraction = Double($0) / 100 }),
                    in: 1...100, step: 5)
                .padding(.leading, 16)
        }
        Toggle("Require a preview before the first sync", isOn: $safety.requirePreviewBeforeFirstMirror)
    }
}

// MARK: - Advanced

private struct AdvancedSection: View {
    @Binding var job: SyncJob
    @Binding var extraArgumentsText: String
    var extraArgumentsError: String?
    @Binding var isExpanded: Bool

    private var summary: String {
        var parts: [String] = []
        if !extraArgumentsText.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("extra arguments") }
        if job.options.preserveACLs { parts.append("ACLs") }
        if job.options.preserveHardLinks { parts.append("hard links") }
        if job.hooks.beforeRun != nil || job.hooks.afterRun != nil { parts.append("commands") }
        return parts.isEmpty ? "rsync arguments, permissions, before and after commands" : parts.joined(separator: " · ").capitalizedFirst
    }

    var body: some View {
        Section {
            CollapsibleHeader(title: "Advanced", symbol: "wrench.and.screwdriver", summary: summary, isExpanded: $isExpanded)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra rsync arguments")
                    TextField(text: $extraArgumentsText, prompt: Text("--numeric-ids --exclude='My Folder'")) { EmptyView() }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    if let extraArgumentsError {
                        Text(extraArgumentsError).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Added after \(AppInfo.name)'s own options. Quote values that contain spaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Toggle("Keep ACLs (access control lists)", isOn: $job.options.preserveACLs)
                    .help("--acls")
                Toggle("Keep hard links", isOn: $job.options.preserveHardLinks)
                    .help("--hard-links")
                if job.mode == .mirror {
                    Toggle("Also delete skipped files at the destination", isOn: $job.options.deleteExcluded)
                        .help("--delete-excluded")
                }

                HookEditor(title: "Before syncing, run", text: Binding(get: { job.hooks.beforeRun ?? "" },
                                                                         set: { job.hooks.beforeRun = $0.isEmpty ? nil : $0 }))
                if job.hooks.beforeRun != nil {
                    Toggle("Don't sync if this command fails", isOn: $job.hooks.abortIfBeforeRunFails)
                        .padding(.leading, 16)
                }
                HookEditor(title: "After syncing, run", text: Binding(get: { job.hooks.afterRun ?? "" },
                                                                        set: { job.hooks.afterRun = $0.isEmpty ? nil : $0 }))
                Text("Commands run with zsh and can use $SYNC_NAME, $SYNC_SOURCE, $SYNC_DESTINATION, $SYNC_TRIGGER and, after syncing, $SYNC_EXIT_CODE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HookEditor: View {
    var title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(height: 44)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 6))
        }
        .padding(.vertical, 4)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
