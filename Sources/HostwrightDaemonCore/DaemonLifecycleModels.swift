import Foundation
import HostwrightCore

public struct DaemonLifecycleLayout: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let homeDirectory: String
    public let userID: UInt32
    public let label: String
    public let domain: String
    public let propertyListPath: String
    public let lifecycleDirectory: String
    public let journalPath: String
    public let statusPath: String
    public let rollbackPath: String
    public let logDirectory: String
    public let standardOutputPath: String
    public let standardErrorPath: String
    public let homebrewLabel: String
    public let homebrewPropertyListPath: String

    public init(homeDirectory: String, userID: UInt32) {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let lifecycle = home.appendingPathComponent(
            "Library/Application Support/Hostwright/daemon",
            isDirectory: true
        )
        let logs = home.appendingPathComponent("Library/Logs/Hostwright", isDirectory: true)

        self.schemaVersion = 1
        self.homeDirectory = homeDirectory
        self.userID = userID
        self.label = "dev.hostwright.daemon"
        self.domain = "gui/\(userID)"
        self.propertyListPath = launchAgents
            .appendingPathComponent("dev.hostwright.daemon.plist")
            .path
        self.lifecycleDirectory = lifecycle.path
        self.journalPath = lifecycle.appendingPathComponent("lifecycle-v1.json").path
        self.statusPath = lifecycle.appendingPathComponent("status-v1.json").path
        self.rollbackPath = lifecycle.appendingPathComponent("rollback-v1.json").path
        self.logDirectory = logs.path
        self.standardOutputPath = logs.appendingPathComponent("hostwrightd.log").path
        self.standardErrorPath = logs.appendingPathComponent("hostwrightd.error.log").path
        self.homebrewLabel = "homebrew.mxcl.hostwright"
        self.homebrewPropertyListPath = launchAgents
            .appendingPathComponent("homebrew.mxcl.hostwright.plist")
            .path
    }

    public static var currentUser: DaemonLifecycleLayout {
        DaemonLifecycleLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            userID: UInt32(geteuid())
        )
    }

    public var serviceTarget: String {
        "\(domain)/\(label)"
    }

    public var homebrewServiceTarget: String {
        "\(domain)/\(homebrewLabel)"
    }
}

public struct DaemonLaunchAgentSpecification: Equatable, Sendable {
    public let layout: DaemonLifecycleLayout
    public let daemonExecutablePath: String
    public let configPath: String

    public init(
        layout: DaemonLifecycleLayout,
        daemonExecutablePath: String,
        configPath: String
    ) throws {
        self.layout = layout
        self.daemonExecutablePath = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            daemonExecutablePath,
            role: "managed daemon executable"
        )
        self.configPath = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            configPath,
            role: "managed daemon configuration"
        )
    }

    public func propertyListData() throws -> Data {
        let propertyList: [String: Any] = [
            "Label": layout.label,
            "ProgramArguments": [
                daemonExecutablePath,
                "--service",
                "--config",
                configPath
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "Umask": "0077",
            "StandardOutPath": layout.standardOutputPath,
            "StandardErrorPath": layout.standardErrorPath
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
