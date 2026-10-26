import SwiftUI
import SyncModel

/// First-run screen: explains the app in one line and offers starting points.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "water.waves")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.wiggle, options: .nonRepeating)
                    Text("Keep your files in sync")
                        .font(.largeTitle.weight(.bold))
                    Text("Copy folders to a drive, a server or another folder, by hand or on a schedule.\nOnly what changed is copied, so it's fast after the first time.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    TemplateCard(
                        title: "Back up to a drive",
                        detail: "Copy a folder to an external drive. Nothing at the destination is ever deleted.",
                        symbol: "externaldrive.fill", tint: .blue
                    ) { start(template: .driveBackup) }
                    TemplateCard(
                        title: "Mirror to a server",
                        detail: "Keep an exact copy on a NAS or server over SSH, including deletions.",
                        symbol: "server.rack", tint: .purple
                    ) { start(template: .mirrorToServer) }
                    TemplateCard(
                        title: "Download from a server",
                        detail: "Bring a folder from a server to this Mac and keep it up to date.",
                        symbol: "arrow.down.circle.fill", tint: .green
                    ) { start(template: .downloadFromServer) }
                }
                .frame(maxWidth: 760)

                Label("Or drop a folder anywhere in this window", systemImage: "hand.point.up.left")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private enum Template { case driveBackup, mirrorToServer, downloadFromServer }

    private func start(template: Template) {
        let firstHost = model.hosts.first?.id
        var job = SyncJob(name: "", source: .local(""), destination: .local(""))
        switch template {
        case .driveBackup:
            job.symbol = "externaldrive.fill"
            job.tint = .blue
            job.mode = .copy
        case .mirrorToServer:
            job.symbol = "server.rack"
            job.tint = .purple
            job.mode = .mirror
            if let firstHost { job.destination = .remote(hostID: firstHost, path: "") }
        case .downloadFromServer:
            job.symbol = "arrow.down.circle.fill"
            job.tint = .green
            job.copyFolderItself = false
            if let firstHost { job.source = .remote(hostID: firstHost, path: "") }
        }
        model.editor = AppModel.EditorRequest(job: job, isNew: true)
    }
}

private struct TemplateCard: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: SyncTint
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SyncIcon(symbol: symbol, tint: tint, size: 40)
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .contentShape(.rect)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .scaleEffect(isHovered ? 1.02 : 1)
            .animation(.snappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
