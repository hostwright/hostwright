#if HOSTWRIGHT_TEST_RUNTIME
import Darwin
import Foundation
import HostwrightCLI
import HostwrightCore
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightRuntime

enum HostwrightTestRuntimeCommand {
    private static let usage = """
        Usage: hostwrightd --test-runtime --node-home <private-directory> --foreground --config <hostwright.yaml> [options]
        The manifest, daemon state, and recording history belong to this node home.

        """

    static func run(arguments: [String], shutdownToken: DaemonShutdownToken) async -> DaemonProcessResult {
        if arguments == ["--help"] {
            return DaemonProcessResult(standardOutput: usage)
        }
        do {
            return try await runNode(arguments: arguments, shutdownToken: shutdownToken)
        } catch {
            let message = RuntimeRedactionPolicy.default.redact(String(describing: error))
            return DaemonProcessResult(standardError: "\(message)\n", exitCode: 64)
        }
    }

    struct Node: Sendable {
        let configuration: DaemonConfiguration
        let runtime: HostwrightTestRecordingRuntime
        let environment: CLIEnvironment
        let readConfiguration: @Sendable (
            String, DaemonConfigurationTargetKind, DaemonConfigurationTarget?
        ) throws -> DaemonConfigurationSnapshot
    }

    static func node(arguments: [String]) throws -> Node {
        guard arguments.count > 2, arguments[0] == "--node-home",
              !arguments.dropFirst(2).contains(where: {
                  ["--state-db", "--lock-file", "--service"].contains($0)
              }) else {
            throw DaemonError.invalidConfiguration(usage)
        }
        let home = try validatedHome(arguments[1])
        let overrides = [
            HostwrightLocalPathResolver.applicationSupportOverride: home.appendingPathComponent("support").path,
            HostwrightLocalPathResolver.cacheOverride: home.appendingPathComponent("cache").path,
            HostwrightLocalPathResolver.logOverride: home.appendingPathComponent("logs").path
        ]
        let command = try DaemonCommand.parse(
            arguments: Array(arguments.dropFirst(2)),
            homeDirectory: home.path,
            environment: overrides
        )
        guard case .run(let configuration) = command, configuration.mode == .foregroundDev,
              let resolution = configuration.stateStoreConfiguration.localPathResolution else {
            throw DaemonError.invalidConfiguration(usage)
        }

        let manifestPath = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            configuration.configPath, role: "rehearsal manifest"
        )
        guard manifestPath == configuration.configPath,
              URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path == home.path else {
            throw DaemonError.invalidConfiguration("The rehearsal manifest must be a file in the node home.")
        }
        let read: @Sendable (String, DaemonConfigurationTargetKind, DaemonConfigurationTarget?) throws
            -> DaemonConfigurationSnapshot = { path, kind, expected in
            guard path == manifestPath, kind == .manifest else {
                throw DaemonError.invalidConfiguration("The recording daemon reads only its configured manifest.")
            }
            let snapshot = try SecureDaemonConfigurationReader.read(path: path, kind: kind, expected: expected)
            try validateRehearsalManifest(ManifestValidator.validated(snapshot.text))
            return snapshot
        }
        _ = try read(manifestPath, .manifest, nil)

        let runtime = HostwrightTestRecordingRuntime(homeDirectory: home, useLifecycleBinding: true)
        let environment = CLIEnvironment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readTextFile: { try read($0, .manifest, nil).text },
            writeTextFile: { _, _ in throw unsupportedHostEffect },
            writeNewTextFile: { _, _ in throw unsupportedHostEffect },
            executablePath: { _ in nil },
            localPathResolution: { explicitPath in
                if let explicitPath, explicitPath != configuration.stateDatabasePath {
                    throw DaemonError.invalidConfiguration("The state path must match the recording daemon's node.")
                }
                return resolution
            },
            runtimeAdapter: { runtime },
            networkProviderForProvider: { _ in throw unsupportedHostEffect },
            storageProviderRootURL: { home.appendingPathComponent("storage", isDirectory: true) },
            swiftVersion: { nil },
            platformSnapshot: { .current },
            operatingSystemDescription: { ProcessInfo.processInfo.operatingSystemVersionString }
        )
        return Node(
            configuration: configuration,
            runtime: runtime,
            environment: environment,
            readConfiguration: read
        )
    }

    private static func runNode(arguments: [String], shutdownToken: DaemonShutdownToken) async throws -> DaemonProcessResult {
        let node = try node(arguments: arguments)
        return await HostwrightDaemonMain.run(
            configuration: node.configuration,
            runtimeAdapter: node.runtime,
            reconciliationDriver: LocalLifecycleDaemonReconciler(environment: node.environment),
            shutdownToken: shutdownToken,
            controlServiceFactory: {
                try HostwrightDaemonControlService.make(configuration: $0, commandEnvironment: node.environment)
            },
            readConfiguration: node.readConfiguration
        )
    }

    private static let unsupportedHostEffect = RuntimeAdapterError.mutationUnavailableByPolicy(
        "The recording daemon cannot perform this host effect."
    )

    private static func validatedHome(_ raw: String) throws -> URL {
        let path = try HostwrightLocalPathResolver.normalizedAbsolutePath(raw, role: "rehearsal node home")
        let canonical = try SecureExecutableResolver.verifyWorkingDirectory(path: path)
        var metadata = stat()
        guard canonical == path, path != FileManager.default.homeDirectoryForCurrentUser.path,
              lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o700 else {
            throw DaemonError.invalidConfiguration("The recording daemon requires a dedicated, owner-only node home.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func validateRehearsalManifest(_ manifest: HostwrightManifest) throws {
        guard manifest.volumes.isEmpty, manifest.networks.isEmpty, manifest.ingress.isEmpty,
              manifest.certificates.isEmpty, manifest.tunnels.isEmpty,
              manifest.imageTrust == nil, manifest.imageSBOM == nil,
              manifest.imageVulnerability == nil, manifest.imageProvenance == nil,
              manifest.services.allSatisfy({ service in
                  service.volumes.isEmpty && service.mounts.isEmpty && service.networks.isEmpty &&
                      service.networkPolicy == nil && service.ports.isEmpty && service.publishedPorts.isEmpty &&
                      service.publishedSockets.isEmpty && service.hostAccess.isEmpty && service.secretEnv.isEmpty &&
                      service.health == nil && service.probes == HostwrightProbes() && service.hooks == HostwrightHooks()
              }) else {
            throw DaemonError.invalidConfiguration(
                "The recording daemon accepts stateless workloads without host resources, secrets, probes, or hooks."
            )
        }
    }
}
#endif
