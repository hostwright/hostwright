import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightSecrets

public struct CLIEnvironment: @unchecked Sendable {
    public var fileExists: (String) -> Bool
    public var readTextFile: (String) throws -> String
    public var writeTextFile: (String, String) throws -> Void
    public var executablePath: (String) -> String?
    public var runtimeAdapter: () -> any RuntimeAdapter
    public var secretStore: () -> any SecretStore
    public var swiftVersion: () -> String?
    public var platformSnapshot: () -> PlatformSnapshot
    public var operatingSystemDescription: () -> String

    public init(
        fileExists: @escaping (String) -> Bool,
        readTextFile: @escaping (String) throws -> String,
        writeTextFile: @escaping (String, String) throws -> Void,
        executablePath: @escaping (String) -> String?,
        runtimeAdapter: @escaping () -> any RuntimeAdapter = { RuntimeAdapterFactory.defaultLocal() },
        secretStore: @escaping () -> any SecretStore = { UnavailableKeychainSecretStore() },
        swiftVersion: @escaping () -> String?,
        platformSnapshot: @escaping () -> PlatformSnapshot,
        operatingSystemDescription: @escaping () -> String
    ) {
        self.fileExists = fileExists
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.executablePath = executablePath
        self.runtimeAdapter = runtimeAdapter
        self.secretStore = secretStore
        self.swiftVersion = swiftVersion
        self.platformSnapshot = platformSnapshot
        self.operatingSystemDescription = operatingSystemDescription
    }

    public static let live = CLIEnvironment(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
        writeTextFile: { path, text in try text.write(toFile: path, atomically: true, encoding: .utf8) },
        executablePath: { ProcessLookup.executablePath(named: $0) },
        runtimeAdapter: { RuntimeAdapterFactory.defaultLocal() },
        secretStore: { UnavailableKeychainSecretStore() },
        swiftVersion: { ProcessLookup.swiftVersionSummary() },
        platformSnapshot: { PlatformSnapshot.current },
        operatingSystemDescription: { ProcessInfo.processInfo.operatingSystemVersionString }
    )
}
