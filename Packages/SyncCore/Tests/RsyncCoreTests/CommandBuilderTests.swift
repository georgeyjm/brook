import Foundation
import SyncModel
import Testing
@testable import RsyncCore

@Suite struct CommandBuilderTests {
    let home = "/Users/test"

    func context(_ purpose: CommandBuilder.Purpose = .sync, hosts: [RemoteHost] = [], unattended: Bool = false,
                 maxDelete: Int? = nil, capabilities: RsyncCapabilities = .assumedModern) -> CommandBuilder.Context {
        CommandBuilder.Context(hosts: hosts, capabilities: capabilities, purpose: purpose,
                               unattended: unattended, maxDelete: maxDelete, homeDirectory: home)
    }

    func job(_ source: Endpoint = .local("/Users/test/Photos"), _ destination: Endpoint = .local("/Volumes/Backup"),
             mode: SyncMode = .copy, copyFolderItself: Bool = true) -> SyncJob {
        SyncJob(name: "Test", source: source, destination: destination, mode: mode, copyFolderItself: copyFolderItself)
    }

    @Test func basicCopyUsesSafeDefaults() throws {
        let args = try CommandBuilder.arguments(for: job(), context: context())
        #expect(args == [
            "--archive", "--8-bit-output", "--itemize-changes", "--stats", "--info=progress2",
            "--xattrs", "--crtimes",
            "/Users/test/Photos", "/Volumes/Backup/",
        ])
        #expect(!args.contains("--delete"))
    }

    @Test func trailingSlashFollowsFolderToggle() throws {
        let itself = try CommandBuilder.arguments(for: job(.local("/Users/test/Photos/"), copyFolderItself: true), context: context())
        let contents = try CommandBuilder.arguments(for: job(.local("/Users/test/Photos"), copyFolderItself: false), context: context())
        #expect(itself.suffix(2) == ["/Users/test/Photos", "/Volumes/Backup/"])
        #expect(contents.suffix(2) == ["/Users/test/Photos/", "/Volumes/Backup/"])
    }

    @Test func rootPathsStayRoot() {
        #expect(CommandBuilder.shapeTrailingSlash("/", side: .source, copyFolderItself: true) == "/")
        #expect(CommandBuilder.shapeTrailingSlash("///", side: .destination, copyFolderItself: true) == "/")
    }

    @Test func tildeExpandsToHome() throws {
        let args = try CommandBuilder.arguments(for: job(.local("~/Documents")), context: context())
        #expect(args.suffix(2).first == "/Users/test/Documents")
    }

    @Test func previewAddsDryRun() throws {
        let args = try CommandBuilder.arguments(for: job(), context: context(.preview))
        #expect(args.contains("--dry-run"))
    }

    @Test func mirrorDeletesAndHonoursMaxDelete() throws {
        var mirror = job(mode: .mirror)
        mirror.options.deleteExcluded = true
        let args = try CommandBuilder.arguments(for: mirror, context: context(maxDelete: 50))
        #expect(args.contains("--delete"))
        #expect(args.contains("--delete-excluded"))
        #expect(args.contains("--max-delete=50"))
    }

    @Test func deleteExcludedIgnoredInCopyMode() throws {
        var copy = job()
        copy.options.deleteExcluded = true
        let args = try CommandBuilder.arguments(for: copy, context: context(maxDelete: 50))
        #expect(!args.contains("--delete-excluded"))
        #expect(!args.contains { $0.hasPrefix("--max-delete") })
    }

    @Test func optionsMapToFlags() throws {
        var j = job()
        j.options = RsyncOptions(
            compareByChecksum: true, compress: true, bandwidthLimitKBps: 500,
            preserveExtendedAttributes: false, preserveCreationDates: false, preserveACLs: true,
            preserveHardLinks: true, keepPartialFiles: true, skipNewerAtDestination: true,
            stayOnOneFileSystem: true, backupDirectory: ".old", extraArguments: ["--numeric-ids", ""]
        )
        let args = try CommandBuilder.arguments(for: j, context: context())
        for flag in ["--checksum", "--compress", "--bwlimit=500", "--acls", "--hard-links", "--partial",
                     "--update", "--one-file-system", "--backup", "--backup-dir=.old", "--numeric-ids"] {
            #expect(args.contains(flag), "missing \(flag)")
        }
        #expect(!args.contains("--xattrs"))
        #expect(!args.contains("--crtimes"))
        #expect(!args.contains(""))
    }

    @Test func filtersKeepOrderAndSkipDisabled() throws {
        var j = job()
        j.filters = [
            FilterRule(kind: .include, pattern: "keep.tmp"),
            FilterRule(kind: .exclude, pattern: "*.tmp"),
            FilterRule(kind: .exclude, pattern: "off", isEnabled: false),
            FilterRule(kind: .exclude, pattern: ""),
        ]
        let args = try CommandBuilder.arguments(for: j, context: context())
        let filters = args.filter { $0.hasPrefix("--include") || $0.hasPrefix("--exclude") }
        #expect(filters == ["--include=keep.tmp", "--exclude=*.tmp"])
    }

    @Test func remoteDestinationBuildsSSHCommand() throws {
        let host = RemoteHost(name: "NAS", hostname: "nas.local", user: "me", port: 2222,
                              identityFile: "~/.ssh/my key", sshOptions: ["ProxyJump=bastion"], remoteRsyncPath: "/usr/local/bin/rsync")
        let j = job(.local("/Users/test/Photos"), .remote(hostID: host.id, path: "/volume1/backup"))
        let args = try CommandBuilder.arguments(for: j, context: context(hosts: [host], unattended: true))
        #expect(args.contains("--rsh=/usr/bin/ssh -p 2222 -i '/Users/test/.ssh/my key' -o ProxyJump=bastion -o ConnectTimeout=20 -o BatchMode=yes"))
        #expect(args.contains("--rsync-path=/usr/local/bin/rsync"))
        #expect(args.last == "me@nas.local:/volume1/backup/")
    }

    @Test func remoteSourceWithAliasAndNoUser() throws {
        let host = RemoteHost(name: "Server", hostname: "myserver")
        let j = job(.remote(hostID: host.id, path: "~/www"), .local("/Users/test/Mirror"), copyFolderItself: false)
        let args = try CommandBuilder.arguments(for: j, context: context(hosts: [host]))
        #expect(args.suffix(2) == ["myserver:~/www/", "/Users/test/Mirror/"])
        #expect(args.contains("--rsh=/usr/bin/ssh -o ConnectTimeout=20"))
    }

    @Test func userConnectTimeoutIsRespected() throws {
        let host = RemoteHost(name: "S", hostname: "s", sshOptions: ["ConnectTimeout=5"])
        let command = try CommandBuilder.sshCommand(for: host, context: context(hosts: [host]))
        #expect(command == "/usr/bin/ssh -o ConnectTimeout=5")
    }

    @Test func errors() {
        let host = RemoteHost(name: "S", hostname: "s")
        #expect(throws: CommandBuilder.BuildError.remoteToRemote) {
            try CommandBuilder.arguments(for: job(.remote(hostID: host.id, path: "/a"), .remote(hostID: host.id, path: "/b")),
                                         context: context(hosts: [host]))
        }
        #expect(throws: CommandBuilder.BuildError.unknownHost(.destination)) {
            try CommandBuilder.arguments(for: job(.local("/a"), .remote(hostID: UUID(), path: "/b")), context: context())
        }
        #expect(throws: CommandBuilder.BuildError.emptyPath(.source)) {
            try CommandBuilder.arguments(for: job(.local("  ")), context: context())
        }
        #expect(throws: CommandBuilder.BuildError.relativeLocalPath(.destination)) {
            try CommandBuilder.arguments(for: job(.local("/a"), .local("relative/dir")), context: context())
        }
        let bad = RemoteHost(name: "S", hostname: "s", identityFile: "/a'b\"c")
        #expect(throws: CommandBuilder.BuildError.self) {
            try CommandBuilder.sshCommand(for: bad, context: context(hosts: [bad]))
        }
    }

    @Test func olderRsyncGetsProtectArgsAndNoInfoFlags() throws {
        let host = RemoteHost(name: "S", hostname: "s")
        let old = RsyncCapabilities(version: RsyncVersion(3, 0, 9), protocolVersion: 30, isOpenRsync: false, features: ["xattrs"])
        let args = try CommandBuilder.arguments(for: job(.local("/a"), .remote(hostID: host.id, path: "/b")),
                                                context: context(hosts: [host], capabilities: old))
        #expect(args.contains("--protect-args"))
        #expect(!args.contains("--info=progress2"))
        #expect(!args.contains("--crtimes"))
    }

    @Test func landingPathExplainsWhereFilesGo() {
        #expect(CommandBuilder.landingPath(for: job(.local("/Users/test/Photos/"), .local("/Volumes/Backup/"))) == "/Volumes/Backup/Photos")
        #expect(CommandBuilder.landingPath(for: job(.local("/Users/test/Photos"), .local("/Volumes/Backup"), copyFolderItself: false)) == "/Volumes/Backup")
        #expect(CommandBuilder.landingPath(for: job(.local("/Users/test/Photos"), .local("/"))) == "/Photos")
    }

    @Test func displayStringQuotesForShell() {
        let display = CommandBuilder.displayString(executable: "/usr/bin/rsync",
                                                   arguments: ["--archive", "/Users/a b/it's", "--exclude=*.tmp"])
        #expect(display == #"/usr/bin/rsync --archive '/Users/a b/it'\''s' '--exclude=*.tmp'"#)
    }
}

@Suite struct ShellWordsTests {
    @Test func splitsLikeAShell() throws {
        #expect(try ShellWords.split(#"--exclude='My Folder' --bwlimit=10  "a \"b\"" c\ d"#) ==
                ["--exclude=My Folder", "--bwlimit=10", #"a "b""#, "c d"])
        #expect(try ShellWords.split("   ") == [])
        #expect(try ShellWords.split("''") == [""])
        #expect(throws: ShellWords.SplitError.unterminatedQuote) { try ShellWords.split("'oops") }
    }

    @Test func joinRoundTrips() throws {
        let words = ["--exclude=My Folder", "it's", "plain"]
        #expect(try ShellWords.split(ShellWords.join(words)) == words)
    }
}
