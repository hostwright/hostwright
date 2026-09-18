import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightCore
import HostwrightDistribution
import HostwrightState

enum HostwrightControlIdentityBootstrap {
    static func bootstrapCurrentProcess() throws {
        try bootstrap(
            installerIdentity: DarwinCurrentControlCodeIdentity.inspect(),
            companionIdentity: nil,
            installerProcessID: getpid()
        )
    }

    static func bootstrapAPIProcesses(managedService: Bool = false) throws {
        if managedService { try validateManagedPaths() }
        let installerProcessID = getppid()
        try bootstrap(
            installerIdentity: DarwinCurrentControlCodeIdentity.inspect(processID: installerProcessID),
            companionIdentity: DarwinCurrentControlCodeIdentity.inspect(),
            desktopIdentity: try discoverDesktopIdentity(installerProcessID: installerProcessID),
            managedService: managedService,
            installerProcessID: installerProcessID
        )
    }

    static func validateManagedPaths(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let selected = try HostwrightLocalPathResolver.resolve(
            homeDirectory: homeDirectory, environment: environment
        )
        let managed = try HostwrightLocalPathResolver.resolve(
            homeDirectory: homeDirectory, environment: [:]
        )
        guard selected.layout == managed.layout,
              selected.stateDatabasePath == managed.stateDatabasePath else {
            throw HostwrightDiagnostic(
                code: .daemonDenied,
                message: "Managed installation requires the current user's default local paths. For an isolated foreground daemon, use daemon bootstrap-identities with the same local path settings."
            )
        }
    }

    private static func bootstrap(
        installerIdentity: CodeIdentity,
        companionIdentity: CodeIdentity?,
        desktopIdentity: CodeIdentity? = nil,
        managedService: Bool = false,
        installerProcessID: pid_t
    ) throws {
        try validateBootstrapPair(
            installer: installerIdentity,
            companion: companionIdentity,
            desktop: desktopIdentity
        )
        let resolution = try HostwrightLocalPathResolver.resolve(
            environment: managedService ? [:] : ProcessInfo.processInfo.environment
        )
        let store = SQLiteStateStore(
            configuration: StateStoreConfiguration(localPathResolution: resolution)
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
        if let prefix = try rootInstalledPrefix(processID: installerProcessID) {
            try DistributionInstalledLifecycle().withOwnerStateBootstrap(
                prefix: prefix, configuration: store.configuration,
                installerIdentity: installerIdentity, companionIdentity: companionIdentity,
                desktopIdentity: desktopIdentity
            ) { preparedStore in
                try bootstrap(store: preparedStore, userID: UInt32(geteuid()),
                    codeIdentity: installerIdentity, companionIdentity: companionIdentity,
                    desktopIdentity: desktopIdentity, timestamp: timestamp)
            }
        } else {
            _ = try StateUpgradeService(store: store).migrateToLatestWithVerifiedBackup()
            try bootstrap(store: store, userID: UInt32(geteuid()),
                codeIdentity: installerIdentity, companionIdentity: companionIdentity,
                desktopIdentity: desktopIdentity, timestamp: timestamp)
        }
    }

    private static func rootInstalledPrefix(processID: pid_t) throws -> URL? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else {
            throw ControlPeerAuthenticationError.codeUnavailable
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executable = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .standardizedFileURL.resolvingSymlinksInPath()
        let bin = executable.deletingLastPathComponent()
        guard executable.lastPathComponent == "hostwright", bin.lastPathComponent == "bin" else { return nil }
        let prefix = bin.deletingLastPathComponent()
        var metadata = stat()
        guard lstat(prefix.path, &metadata) == 0 else { throw ControlPeerAuthenticationError.codeUnavailable }
        guard metadata.st_uid == 0 else { return nil }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o022 == 0,
              prefix.resolvingSymlinksInPath().path == prefix.path else {
            throw ControlPeerAuthenticationError.codeUnavailable
        }
        return prefix
    }

    static func bootstrap(
        store: SQLiteStateStore,
        userID: UInt32,
        codeIdentity: CodeIdentity,
        companionIdentity: CodeIdentity? = nil,
        desktopIdentity: CodeIdentity? = nil,
        timestamp: String
    ) throws {
        try validateBootstrapPair(
            installer: codeIdentity,
            companion: companionIdentity,
            desktop: desktopIdentity
        )
        try store.controlIdentities.applyBootstrap(ControlIdentityBootstrapRequest(
            expectedIdentities: try store.controlIdentities.listIdentities(),
            userID: userID, installer: codeIdentity, companion: companionIdentity,
            desktop: desktopIdentity, timestamp: timestamp
        ))
    }

    private static func validateBootstrapPair(
        installer: CodeIdentity,
        companion: CodeIdentity?,
        desktop: CodeIdentity?
    ) throws {
        try installer.validate()
        let installerIdentifierAllowed: Bool
        switch installer.validationMode {
        case .installedRequirement:
            installerIdentifierAllowed = ["hostwright", "dev.hostwright.cli"]
                .contains(installer.signingIdentifier)
        case .pinnedAdHoc:
            installerIdentifierAllowed = installer.signingIdentifier == "dev.hostwright.cli"
                || adHocIdentifier(installer.signingIdentifier, base: "hostwright")
        }
        guard installerIdentifierAllowed else {
            throw StateStoreError.invalidRecord(
                "The bootstrap installer code identity is not Hostwright CLI."
            )
        }
        if let companion {
            try companion.validate()
            let companionIdentifierAllowed = companion.validationMode == .installedRequirement
                ? companion.signingIdentifier == "hostwright-control"
                : adHocIdentifier(companion.signingIdentifier, base: "hostwright-control")
            guard companionIdentifierAllowed,
                  companion.validationMode == installer.validationMode,
                  companion.teamIdentifier == installer.teamIdentifier else {
                throw StateStoreError.invalidRecord(
                    "The bootstrap companion code identity does not match the installer trust domain."
                )
            }
        }
        if installer.validationMode == .installedRequirement {
            guard installer.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier else {
                throw StateStoreError.invalidRecord(
                    "The bootstrap installer team identity is not trusted."
                )
            }
        }
        guard let desktop else { return }
        try desktop.validate()
        let desktopIdentifierAllowed = desktop.validationMode == .installedRequirement
            ? desktop.signingIdentifier == "dev.hostwright.desktop"
            : adHocIdentifier(desktop.signingIdentifier, base: "hostwright-desktop")
        guard desktopIdentifierAllowed,
              desktop.validationMode == installer.validationMode,
              desktop.teamIdentifier == installer.teamIdentifier else {
            throw StateStoreError.invalidRecord(
                "The bootstrap desktop identity does not match the installer trust domain."
            )
        }
    }

    private static func discoverDesktopIdentity(installerProcessID: pid_t) throws -> CodeIdentity? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(installerProcessID, &buffer, UInt32(buffer.count))
        guard count > 0 else { throw ControlPeerAuthenticationError.codeUnavailable }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let installerURL = URL(
            fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)
        ).standardizedFileURL
        let directory = installerURL.deletingLastPathComponent()
        let candidate = directory.lastPathComponent == "bin"
            ? directory.deletingLastPathComponent().appendingPathComponent(
                "libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop"
            )
            : directory.appendingPathComponent("hostwright-desktop")
        var status = stat()
        guard lstat(candidate.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw ControlPeerAuthenticationError.codeUnavailable
        }
        return try DarwinCurrentControlCodeIdentity.inspect(executablePath: candidate.path)
    }

    private static func adHocIdentifier(_ value: String, base: String) -> Bool {
        value == base || value.range(
            of: "^\(NSRegularExpression.escapedPattern(for: base))-[a-f0-9]{40}$",
            options: .regularExpression
        ) != nil
    }

}
