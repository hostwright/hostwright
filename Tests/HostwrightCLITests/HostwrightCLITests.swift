import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightHealth
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightSecrets
@testable import HostwrightState

final class HostwrightCLITests: XCTestCase {
    final class FileBox {
        var files: [String: String]
        var readCounts: [String: Int] = [:]
        var writeCount = 0

        init(files: [String: String] = [:]) {
            self.files = files
        }
    }

    let fakeSecret = "plain-secret-token"

    var safeStackFile: String {
        """
        name: demo
        services:
          api:
            image: ghcr.io/example/api:latest
            command: ["serve"]
            ports:
              - "8080:8080"
            environment:
              APP_ENV: development

        """
    }

    var composeExportManifest: String {
        """
        version: 3
        project: compose-cli
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 2
                memory: 1GiB

        """
    }

    var composeDesiredManifest: String {
        """
        version: 3
        project: compose-cli
        services:
          api:
            image: ghcr.io/example/api:2
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 2
                memory: 1GiB

        """
    }

    var composeUnrepresentableManifest: String {
        """
        version: 3
        project: compose-cli
        imagePolicy: require-digest
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 2
                memory: 1GiB

        """
    }

    var singleServiceManifest: String {
        """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            command: ["serve"]
            env:
              APP_ENV: development
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            ports:
              - "8080:8080"

        """
    }

    var restartableServiceManifest: String {
        """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            ports:
              - "8080:8080"
            restart:
              policy: on-failure

        """
    }

    var managedRestartHealthManifest: String {
        """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            ports:
              - "8080:8080"
            health:
              command: ["false"]
              interval: 60s
            restart:
              policy: on-failure

        """
    }

    var twoServiceManifest: String {
        """
        version: 3
        project: demo
        services:
          api:
            image: local/demo:latest
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            ports:
              - "8080:8080"
          worker:
            image: local/worker:latest
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
            ports:
              - "8081:8080"

        """
    }

    var fakeAdapterMetadata: RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "fake-apply-adapter",
            adapterVersion: "test",
            runtimeName: "fake-runtime",
            runtimeVersion: nil,
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        )
    }

    func environment(
        files: FileBox,
        containerPath: String? = nil,
        runtimeAdapter: (any RuntimeAdapter)? = nil,
        secretStore: (any SecretStore)? = nil,
        platform: PlatformSnapshot = PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
        writeError: Error? = nil,
        resourceSnapshot: ResourceIntelligenceSnapshot? = nil,
        doctorSnapshot: DoctorSystemSnapshot? = nil,
        localPathResolution: ((String?) throws -> HostwrightLocalPathResolution)? = nil
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { files.files[$0] != nil },
            readTextFile: { path in
                files.readCounts[path, default: 0] += 1
                guard let text = files.files[path] else {
                    throw CLIUsageError("missing file")
                }
                return text
            },
            writeTextFile: { path, text in
                files.writeCount += 1
                if let writeError {
                    throw writeError
                }
                files.files[path] = text
            },
            writeNewTextFile: { path, text in
                files.writeCount += 1
                if let writeError {
                    throw writeError
                }
                guard files.files[path] == nil else {
                    throw POSIXError(.EEXIST)
                }
                files.files[path] = text
            },
            executablePath: { name in name == "container" ? containerPath : "/usr/bin/\(name)" },
            localPathResolution: localPathResolution ?? { explicitPath in
                try HostwrightLocalPathResolver.resolve(
                    explicitStateDatabasePath: explicitPath,
                    homeDirectory: "/nonexistent/hostwright-cli-tests",
                    environment: [:]
                )
            },
            runtimeAdapter: { runtimeAdapter ?? ScriptedApplyRuntimeAdapter() },
            secretStore: { secretStore ?? UnavailableKeychainSecretStore() },
            swiftVersion: { "Swift 6.3.3" },
            platformSnapshot: { platform },
            operatingSystemDescription: { "macOS 26.5" },
            resourceSnapshot: { resourceSnapshot },
            doctorSystemSnapshot: {
                doctorSnapshot ?? self.healthyDoctorSystemSnapshot(
                    containerAvailable: containerPath != nil
                )
            }
        )
    }

    func composeReadOnlyEnvironment(files: FileBox) -> CLIEnvironment {
        var result = environment(files: files)
        result.localPathResolution = { _ in
            XCTFail("Compose source-only commands must not resolve or create state.")
            throw CLIUsageError("unexpected state access")
        }
        result.runtimeAdapter = {
            XCTFail("Compose source-only commands must not request a runtime adapter.")
            return ScriptedApplyRuntimeAdapter()
        }
        result.runtimeAdapterForProvider = { _ in
            XCTFail("Compose source-only commands must not request a runtime provider.")
            return ScriptedApplyRuntimeAdapter()
        }
        return result
    }

    func healthyDoctorSystemSnapshot(
        containerAvailable: Bool = true,
        developmentBuild: Bool = false
    ) -> DoctorSystemSnapshot {
        DoctorSystemSnapshot(
            localNetwork: DoctorLocalNetworkSnapshot(
                loopbackAvailable: true,
                activeNonLoopbackInterfaceCount: 1,
                hasIPv4: true,
                hasIPv6: true
            ),
            signingTrust: DoctorSigningTrustSnapshot(
                codeSignature: .developerID,
                gatekeeper: .accepted,
                developmentBuild: developmentBuild
            ),
            resourcePressure: DoctorResourcePressureSnapshot(
                physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                reclaimableMemoryBytes: 8 * 1_024 * 1_024 * 1_024,
                reclaimableMemoryPercent: 50,
                thermalState: .nominal
            ),
            tools: [
                DoctorToolSnapshot(
                    identifier: "apple-container-cli",
                    available: containerAvailable,
                    requiredForRuntime: true
                ),
                DoctorToolSnapshot(
                    identifier: "codesign",
                    available: true,
                    requiredForRuntime: false
                ),
                DoctorToolSnapshot(
                    identifier: "gatekeeper-spctl",
                    available: true,
                    requiredForRuntime: false
                ),
                DoctorToolSnapshot(
                    identifier: "swift-toolchain",
                    available: true,
                    requiredForRuntime: false
                )
            ]
        )
    }

    func phase26ResourceSnapshot() -> ResourceIntelligenceSnapshot {
        ResourceIntelligenceSnapshot(
            method: .fixture,
            operatingSystemDescription: "macOS 26.5",
            platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
            physicalMemoryBytes: 68_719_476_736,
            activeProcessorCount: 12,
            thermalState: .nominal,
            appleContainerExecutablePath: "/usr/local/bin/container",
            appleContainerVersion: "container 1.0.0",
            workloadProfile: .localAIModelMemoryPressure,
            imageArchitectures: [
                ResourceImageArchitectureEvidence(
                    imageReference: "example.local/worker@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    reportedArchitecture: "linux/amd64"
                )
            ]
        )
    }

    func planHash(for manifestText: String, observed: ObservedRuntimeState) throws -> String {
        let manifest = try ManifestValidator.validated(manifestText)
        let capabilityBound = ObservedRuntimeState(
            projectName: observed.projectName,
            services: observed.services,
            adapterMetadata: observed.adapterMetadata,
            capabilitySHA256: observed.adapterMetadata == nil
                ? observed.capabilitySHA256
                : observed.capabilitySHA256 ?? ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.canonicalSHA256
        )
        return ReconciliationPlanner().plan(manifest: manifest, observedState: capabilityBound).planHash
    }

    func planHash(fromStatusOutput output: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("Plan hash: ") })
        return String(line.replacingOccurrences(of: "Plan hash: ", with: ""))
    }

    func doctorFileSetSnapshot(directory: String) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
            return (name, try Data(contentsOf: URL(fileURLWithPath: path)))
        })
    }

    func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func saveDesiredManifest(store: SQLiteStateStore, manifestText: String) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-demo",
            manifestPath: HostwrightIdentity.manifestFileName,
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: try ManifestValidator.validated(manifestText),
            timestamp: "2026-07-01T00:00:00Z"
        )
    }

    func saveOwnership(store: SQLiteStateStore) throws {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        try store.ownership.upsert(
            OwnershipRecord(
                id: "ownership-api",
                resourceIdentifier: identity.managedResourceIdentifier,
                resourceType: "container",
                projectID: "project-demo",
                serviceName: "api",
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                createdAt: "2026-07-01T00:00:00Z",
                observedAt: "2026-07-01T00:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion
            )
        )
    }

    func saveFreshUnhealthyHealthResult(store: SQLiteStateStore) throws {
        try store.healthResults.append([
            HealthCheckResultRecord(
                id: hostwrightUniqueID(prefix: "health-api"),
                projectID: "project-demo",
                serviceName: "api",
                checkedAt: hostwrightTimestamp(),
                status: .unhealthy,
                exitStatus: 1,
                timedOut: false,
                commandJSONRedacted: #"["false"]"#,
                stdoutRedacted: "",
                stderrRedacted: "",
                metadataJSONRedacted: "{}"
            )
        ])
    }

    func runningObservedService(
        healthState: RuntimeHealthState,
        lifecycleState: RuntimeLifecycleState = .running
    ) -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: "demo",
            services: [
                ObservedRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "demo", serviceName: "api"),
                    resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
                    image: "local/demo:latest",
                    lifecycleState: lifecycleState,
                    healthState: healthState
                )
            ],
            adapterMetadata: fakeAdapterMetadata,
            capabilitySHA256: ScriptedApplyRuntimeAdapter.testCapabilitySnapshot.canonicalSHA256
        )
    }

    func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    final class ScriptedApplyRuntimeAdapter: RuntimeAdapter, @unchecked Sendable {
        typealias ExecuteHook = @Sendable (PlannedRuntimeAction) throws -> Void

        static let testCapabilitySnapshot = RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerCLI,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerCLI,
                        version: "1.1.0",
                        build: "109",
                        fingerprint: "099d8db0"
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerAPIService,
                        version: "1.1.0",
                        build: "109",
                        fingerprint: "099d8db0"
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26, minor: 5, patch: 0),
                macOSBuild: "25F90",
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map {
                RuntimeProviderFeatureStatus(
                    feature: $0,
                    state: .available,
                    reason: .implemented
                )
            }
        )
        static let changedCapabilitySnapshot = RuntimeCapabilitySnapshot(
            descriptor: testCapabilitySnapshot.descriptor,
            host: RuntimeProviderHostPlatform(
                macOSVersion: testCapabilitySnapshot.host.macOSVersion,
                macOSBuild: "25F91",
                architecture: testCapabilitySnapshot.host.architecture
            ),
            features: testCapabilitySnapshot.features
        )

        let observedState: ObservedRuntimeState
        let postExecuteObservedState: ObservedRuntimeState?
        let observeError: RuntimeAdapterError?
        let executeError: RuntimeAdapterError?
        let readinessReport: RuntimeReadinessReport
        let readinessError: RuntimeAdapterError?
        let logsText: String
        let onExecute: ExecuteHook?
        let capabilitySnapshots: [RuntimeCapabilitySnapshot]
        var capabilitySnapshotIndex = 0
        var didAttemptExecution = false
        var executedActions: [PlannedRuntimeAction] = []
        var confirmations: [RuntimeMutationConfirmation] = []
        var logRequests: [RuntimeServiceIdentity] = []
        var logResourceIdentifiers: [String] = []
        var observedDesiredStates: [DesiredRuntimeState] = []

        init(
            observedState: ObservedRuntimeState? = nil,
            postExecuteObservedState: ObservedRuntimeState? = nil,
            observeError: RuntimeAdapterError? = nil,
            executeError: RuntimeAdapterError? = nil,
            readinessReport: RuntimeReadinessReport = RuntimeReadinessReport(
                runtimeName: "fake-runtime",
                cliVersion: "1.1.0",
                serviceState: .running,
                serviceVersion: "1.1.0",
                serviceBuild: "test"
            ),
            readinessError: RuntimeAdapterError? = nil,
            logsText: String = "",
            onExecute: ExecuteHook? = nil,
            capabilitySnapshots: [RuntimeCapabilitySnapshot] = [ScriptedApplyRuntimeAdapter.testCapabilitySnapshot]
        ) {
            precondition(!capabilitySnapshots.isEmpty)
            let source = observedState ?? ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    providerID: .appleContainerCLI,
                    adapterName: "fake-apply-adapter",
                    adapterVersion: "test",
                    runtimeName: "fake-runtime",
                    runtimeVersion: nil,
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
                )
            )
            self.observedState = ObservedRuntimeState(
                projectName: source.projectName,
                services: source.services,
                adapterMetadata: source.adapterMetadata,
                capabilitySHA256: source.adapterMetadata == nil
                    ? source.capabilitySHA256
                    : source.capabilitySHA256 ?? Self.testCapabilitySnapshot.canonicalSHA256
            )
            self.postExecuteObservedState = postExecuteObservedState.map { source in
                ObservedRuntimeState(
                    projectName: source.projectName,
                    services: source.services,
                    adapterMetadata: source.adapterMetadata,
                    capabilitySHA256: source.adapterMetadata == nil
                        ? source.capabilitySHA256
                        : source.capabilitySHA256 ?? Self.testCapabilitySnapshot.canonicalSHA256
                )
            }
            self.observeError = observeError
            self.executeError = executeError
            self.readinessReport = readinessReport
            self.readinessError = readinessError
            self.logsText = logsText
            self.onExecute = onExecute
            self.capabilitySnapshots = capabilitySnapshots
        }

        func metadata() async -> RuntimeAdapterMetadata {
            observedState.adapterMetadata!
        }

        func capabilities() async throws -> [RuntimeCapability] {
            [.readOnlyObservation, .lifecycleMutation, .logStreaming, .cleanup]
        }

        func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
            let index = min(capabilitySnapshotIndex, capabilitySnapshots.count - 1)
            capabilitySnapshotIndex += 1
            return capabilitySnapshots[index]
        }

        func runtimeReadiness() async throws -> RuntimeReadinessReport {
            if let readinessError {
                throw readinessError
            }
            return readinessReport
        }

        func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
            observedDesiredStates.append(desiredState)
            if let observeError {
                throw observeError
            }
            if didAttemptExecution, let postExecuteObservedState {
                return postExecuteObservedState
            }
            return observedState
        }

        func plan(desiredState: DesiredRuntimeState, observedState: ObservedRuntimeState) async throws -> RuntimePlan {
            RuntimePlan(actions: [])
        }

        func execute(_ action: PlannedRuntimeAction, confirmation: RuntimeMutationConfirmation?) async throws -> RuntimeEvent {
            didAttemptExecution = true
            executedActions.append(action)
            if let confirmation {
                confirmations.append(confirmation)
            }
            try onExecute?(action)
            if let executeError {
                throw executeError
            }
            return RuntimeEvent(
                identity: action.identity,
                message: "\(action.kind.rawValue) token=plain-secret-token",
                resourceIdentifier: action.resourceIdentifier
            )
        }

        func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
            logRequests.append(service.identity)
            logResourceIdentifiers.append(service.resourceIdentifier)
            return RuntimeLogResult(identity: service.identity, text: RuntimeRedactionPolicy.default.redact(logsText), lineLimit: min(max(1, tail), 1_000))
        }
    }
}
