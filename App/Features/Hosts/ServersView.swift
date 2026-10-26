import RsyncCore
import SSHKit
import SwiftUI
import SyncEngine
import SyncModel

/// Saved SSH servers that syncs can copy to or from.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HostEditRequest?
    @State private var configHosts: [SSHConfigHost] = []

    var body: some View {
        Group {
            if model.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No servers yet", systemImage: "server.rack")
                } description: {
                    Text("Add a NAS or server you can reach over SSH, then use it as a sync's source or destination.")
                } actions: {
                    Button("Add Server…") { add(RemoteHost(name: "", hostname: "")) }
                        .buttonStyle(.glassProminent)
                    if !configHosts.isEmpty { importMenu }
                }
            } else {
                List {
                    ForEach(model.hosts) { host in
                        Button { edit(host) } label: { ServerRow(host: host) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Edit…") { edit(host) }
                                Button("Delete", role: .destructive) { model.deleteHost(host.id) }
                                    .disabled(!model.jobsUsing(hostID: host.id).isEmpty)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                if !configHosts.isEmpty { importMenu }
                Button("Add Server", systemImage: "plus") { add(RemoteHost(name: "", hostname: "")) }
            }
        }
        .task { configHosts = SSHConfigParser.hosts() }
        .sheet(item: $editing) { request in
            HostEditorView(host: request.host, isNew: request.isNew)
        }
    }

    private var importMenu: some View {
        Menu("Add from SSH Config", systemImage: "doc.text") {
            ForEach(configHosts, id: \.alias) { entry in
                Button(entry.hostName.map { "\(entry.alias) (\($0))" } ?? entry.alias) {
                    // Use the alias as the address so ssh applies the rest of the config itself.
                    add(RemoteHost(name: entry.alias, hostname: entry.alias))
                }
            }
        }
        .help("Your ~/.ssh/config hosts")
    }

    private func add(_ host: RemoteHost) {
        editing = HostEditRequest(host: host, isNew: true)
    }

    private func edit(_ host: RemoteHost) {
        editing = HostEditRequest(host: host, isNew: false)
    }
}

/// Carries "new or existing" together with the host, so the sheet never sees a stale flag.
private struct HostEditRequest: Identifiable {
    var host: RemoteHost
    var isNew: Bool
    var id: UUID { host.id }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost

    var body: some View {
        let usedBy = model.jobsUsing(hostID: host.id)
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline)
                Text(host.sshTarget + (host.port.map { ":\($0)" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(usedBy.isEmpty ? "Not used" : "Used by \(usedBy.count) sync\(usedBy.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}

/// Add or edit a server, with a "Test Connection" check.
struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var host: RemoteHost
    @State private var portText: String
    @State private var optionsText: String
    @State private var testState: TestState = .idle
    let isNew: Bool
    var onSave: ((RemoteHost) -> Void)?

    enum TestState: Equatable {
        case idle, testing
        case done(ConnectionTester.Outcome)
    }

    init(host: RemoteHost, isNew: Bool, onSave: ((RemoteHost) -> Void)? = nil) {
        _host = State(initialValue: host)
        _portText = State(initialValue: host.port.map(String.init) ?? "")
        _optionsText = State(initialValue: host.sshOptions.joined(separator: "\n"))
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $host.name, prompt: Text("Home NAS"))
                    TextField("Address", text: $host.hostname, prompt: Text("nas.local, 192.168.1.20 or an SSH config alias"))
                    TextField("User name", text: Binding(get: { host.user ?? "" }, set: { host.user = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Optional"))
                    TextField("Port", text: $portText, prompt: Text("22"))
                } header: {
                    Text("Server")
                } footer: {
                    Text("\(AppInfo.name) connects with SSH using your keys (or ssh-agent). Scheduled syncs can't type passwords, so key-based sign-in is required for them.")
                        .foregroundStyle(.secondary)
                }

                Section("Advanced") {
                    LabeledContent("Private key") {
                        HStack {
                            Text(host.identityFile ?? "Automatic")
                                .foregroundStyle(host.identityFile == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if host.identityFile != nil {
                                Button("Clear") { host.identityFile = nil }
                            }
                            Button("Choose…") {
                                let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
                                if let path = FinderActions.chooseFile(startingAt: sshDir) {
                                    host.identityFile = (path as NSString).abbreviatingWithTildeInPath
                                }
                            }
                        }
                    }
                    TextField("rsync on the server", text: Binding(get: { host.remoteRsyncPath ?? "" },
                                                                   set: { host.remoteRsyncPath = $0.isEmpty ? nil : $0 }),
                              prompt: Text("rsync"))
                        .help("Path to rsync on the server, e.g. /usr/local/bin/rsync")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SSH options (one per line)")
                        TextEditor(text: $optionsText)
                            .font(.body.monospaced())
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                            .background(.background.secondary, in: .rect(cornerRadius: 6))
                        Text("For example ProxyJump=bastion or ServerAliveInterval=30").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        testResult
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Test Connection") { Task { await test() } }
                            .fixedSize()
                            .disabled(host.hostname.isEmpty || testState == .testing)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    let used = model.jobsUsing(hostID: host.id)
                    Button("Delete Server", role: .destructive) {
                        model.deleteHost(host.id)
                        dismiss()
                    }
                    .disabled(!used.isEmpty)
                    .help(used.isEmpty ? "" : "Used by: \(used.map(\.name).joined(separator: ", "))")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Server" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty || !portIsValid)
            }
            .padding(16)
        }
        .frame(width: 520)
        .frame(minHeight: 520)
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .idle:
            Text("Check that \(AppInfo.name) can sign in without a password.").foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting…") }
        case .done(.success(let version)):
            Label("Connected. The server has \(version).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .done(.warning(let message)):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .done(.failure(let diagnosis)):
            VStack(alignment: .leading, spacing: 2) {
                Label(diagnosis.title, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if let hint = hint(for: diagnosis.fixIt) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if let detail = diagnosis.detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
        }
    }

    private func hint(for fixIt: Diagnosis.FixIt?) -> String? {
        switch fixIt {
        case .setUpSSHKey?: "Set up an SSH key for this server (ssh-copy-id), or add your key to ssh-agent."
        case .trustHostKey?: "Connect once in Terminal (ssh \(host.sshTarget)) and confirm the server's fingerprint."
        case .checkServerAddress?: "Check the address, port, and that SSH / Remote Login is enabled on the server."
        case .installRemoteRsync?: "Install rsync on the server, or set its path above."
        default: nil
        }
    }

    private var portIsValid: Bool {
        portText.isEmpty || (Int(portText).map { (1...65535).contains($0) } ?? false)
    }

    private func normalized() -> RemoteHost {
        var result = host
        result.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        result.name = host.name.trimmingCharacters(in: .whitespaces).isEmpty ? result.hostname : host.name
        result.port = Int(portText)
        result.sshOptions = optionsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return result
    }

    private func test() async {
        testState = .testing
        testState = .done(await ConnectionTester.test(normalized()))
    }

    private func save() {
        let result = normalized()
        model.save(host: result)
        onSave?(result)
        dismiss()
    }
}
