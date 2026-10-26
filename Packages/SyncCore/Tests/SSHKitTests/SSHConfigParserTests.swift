import Foundation
import Testing
@testable import SSHKit

@Suite struct SSHConfigParserTests {
    @Test func parsesHostsAndSkipsPatterns() {
        let config = """
        # Global defaults
        Host *
            ServerAliveInterval 60

        Host nas backup-box
            HostName 192.168.1.20
            User admin
            Port=2222
            IdentityFile "~/.ssh/nas key"

        Host web-*
            User deploy

        Match host foo
            User ignored

        Host prod
          HostName = prod.example.com
          ProxyJump bastion
          User first
          User second
        """
        let hosts = SSHConfigParser.parse(config)
        #expect(hosts.map(\.alias) == ["nas", "backup-box", "prod"])
        #expect(hosts[0] == SSHConfigHost(alias: "nas", hostName: "192.168.1.20", user: "admin", port: 2222, identityFile: "~/.ssh/nas key"))
        #expect(hosts[1].hostName == "192.168.1.20")
        #expect(hosts[2].hostName == "prod.example.com")
        #expect(hosts[2].proxyJump == "bastion")
        #expect(hosts[2].user == "first")
    }

    @Test func followsIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "conf.d"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Include conf.d/*.conf\nHost main\n  HostName main.example\n".write(to: dir.appending(path: "config"), atomically: true, encoding: .utf8)
        try "Host extra\n  HostName extra.example\n".write(to: dir.appending(path: "conf.d/a.conf"), atomically: true, encoding: .utf8)
        try "Include ../config\n".write(to: dir.appending(path: "conf.d/loop.conf"), atomically: true, encoding: .utf8)

        let hosts = SSHConfigParser.hosts(in: dir.appending(path: "config"))
        #expect(Set(hosts.map(\.alias)) == ["main", "extra"])
    }

    @Test func missingFileIsEmpty() {
        #expect(SSHConfigParser.hosts(in: URL(filePath: "/nonexistent/config")).isEmpty)
    }
}
