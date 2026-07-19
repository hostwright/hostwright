import Darwin
import Foundation
@_spi(Phase03Qualification) import HostwrightCLI
import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightState

enum RuntimeQualificationMigrationDriverError: Error, Equatable {
    case invalidSpecification
    case providerPreflightFailed
    case stateFoundationFailed
    case expectedRefusalMissing
    case migrationFailed
    case ownershipMismatch
    case rollbackFailed
    case recoveryFailed
    case cleanupFailed
}

struct RuntimeQualificationMigrationSpecification: Equatable, Sendable {
    let sourceProviderID: RuntimeProviderID
    let targetProviderID: RuntimeProviderID
    let expectedSourceVersion: String
    let expectedTargetVersion: String
    let localImage: String

    func validated() throws -> Self {
        guard sourceProviderID != targetProviderID,
              Set([sourceProviderID, targetProviderID]) == Set([
                  .appleContainerCLI, .appleContainerization,
              ]),
              !localImage.isEmpty,
              localImage.utf8.count <= 512,
              localImage.rangeOfCharacter(from: .controlCharacters) == nil,
              Self.version(expectedSourceVersion, matches: sourceProviderID),
              Self.version(expectedTargetVersion, matches: targetProviderID) else {
            throw RuntimeQualificationMigrationDriverError.invalidSpecification
        }
        return self
    }

    private static func version(_ value: String, matches providerID: RuntimeProviderID) -> Bool {
        switch providerID {
        case .appleContainerCLI: ["1.0.0", "1.1.0"].contains(value)
        case .appleContainerization:
            value == ContainerizationRuntimeAssetContract.frameworkVersion
        default: false
        }
    }
}

struct RuntimeQualificationMigrationEvidence: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceProviderID: String
    let targetProviderID: String
    let projectUUID: String
    let resourceUUID: String
    let fixtureImageReference: String
    let fixtureImageDescriptorDigest: String
    let fixtureImageVariantDigest: String
    let sourceCapabilitySHA256: String
    let targetCapabilitySHA256: String
    let staleConfirmationRefused: Bool
    let targetCollisionRefused: Bool
    let unavailableImageRefused: Bool
    let rollbackVerified: Bool
    let checkpointRecovered: Bool
    let forwardCheckpoint: String
    let reverseCheckpoint: String
    let stateSchemaVersion: Int
    let sourceInventoryBeforeSHA256: String
    let sourceInventoryAfterSHA256: String
    let targetInventoryBeforeSHA256: String
    let targetInventoryAfterSHA256: String
    let cleanupComplete: Bool
}

struct RuntimeQualificationMigrationStateFoundation: Sendable {
    let directory: URL
    let store: SQLiteStateStore
    let projectID: String
    let projectName: String
    let serviceName: String
    let projectUUID: String
    let resourceUUID: String
    let sourceFencingToken: String
    let migrationFencingToken: String
    private let cleanupMarker: String

    static func make(
        sourceProviderID: RuntimeProviderID,
        image: String,
        parentDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> RuntimeQualificationMigrationStateFoundation {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let projectName = "m\(suffix.prefix(8))"
        let serviceName = "s\(suffix.dropFirst(8).prefix(8))"
        let projectID = "project-\(projectName)"
        let directory = parentDirectory.appendingPathComponent(
            "hostwright-phase03-migration-\(suffix)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let cleanupMarker = UUID().uuidString.lowercased()
            let markerURL = directory.appendingPathComponent(".hostwright-phase03-owned")
            try Data((cleanupMarker + "\n").utf8).write(
                to: markerURL,
                options: .withoutOverwriting
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: markerURL.path
            )
            let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
            try store.migrate()
            guard try store.schemaVersion() == 7 else {
                throw RuntimeQualificationMigrationDriverError.stateFoundationFailed
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: directory.appendingPathComponent("hostwright.yaml").path,
                manifestHash: String(repeating: "a", count: 64),
                desiredGeneration: 1,
                manifest: HostwrightManifest(
                    version: HostwrightManifest.currentVersion,
                    project: projectName,
                    services: [HostwrightService(
                        name: serviceName,
                        image: image,
                        command: ["sleep", "3600"]
                    )]
                ),
                timestamp: timestamp,
                mutationProvider: sourceProviderID.rawValue
            )
            let project = try store.desiredStates.loadProject(id: projectID)
            guard let service = try store.desiredStates.loadDesiredServices(
                projectID: projectID
            ).first else {
                throw RuntimeQualificationMigrationDriverError.stateFoundationFailed
            }
            let sourceFence = UUID().uuidString.lowercased()
            let migrationFence = UUID().uuidString.lowercased()
            let identity = RuntimeServiceIdentity(
                projectName: projectName, serviceName: serviceName
            )
            try store.ownership.upsert(OwnershipRecord(
                id: "ownership-\(service.resourceUUID)",
                resourceIdentifier: identity.managedResourceIdentifier,
                resourceType: "container",
                projectID: projectID,
                serviceName: serviceName,
                runtimeAdapter: sourceProviderID.rawValue,
                createdAt: timestamp,
                observedAt: timestamp,
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                resourceUUID: service.resourceUUID,
                resourceGeneration: 1,
                projectResourceUUID: project.resourceUUID,
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: sourceFence
            ))
            return RuntimeQualificationMigrationStateFoundation(
                directory: directory,
                store: store,
                projectID: projectID,
                projectName: projectName,
                serviceName: serviceName,
                projectUUID: project.resourceUUID,
                resourceUUID: service.resourceUUID,
                sourceFencingToken: sourceFence,
                migrationFencingToken: migrationFence,
                cleanupMarker: cleanupMarker
            )
        } catch {
            let originalError = error
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            throw originalError
        }
    }

    func remove() throws {
        var directoryMetadata = stat()
        let markerURL = directory.appendingPathComponent(".hostwright-phase03-owned")
        var markerMetadata = stat()
        guard NSString(string: directory.path).standardizingPath == directory.path,
              directory.lastPathComponent.hasPrefix("hostwright-phase03-migration-"),
              lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              lstat(markerURL.path, &markerMetadata) == 0,
              markerMetadata.st_mode & S_IFMT == S_IFREG,
              markerMetadata.st_uid == geteuid(),
              markerMetadata.st_nlink == 1,
              markerMetadata.st_mode & 0o7777 == 0o600,
              try String(contentsOf: markerURL, encoding: .utf8) == cleanupMarker + "\n" else {
            throw RuntimeQualificationMigrationDriverError.cleanupFailed
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw RuntimeQualificationMigrationDriverError.cleanupFailed
        }
    }
}

private struct RuntimeQualificationMigrationProviderBoundary: Sendable {
    let adapter: any RuntimeAdapter
    private let helperClient: ContainerizationHelperClient?
    private let helperSocketURL: URL?

    static func make(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        recorder: RuntimeQualificationCommandRecorder
    ) async throws -> RuntimeQualificationMigrationProviderBoundary {
        let boundary: RuntimeQualificationMigrationProviderBoundary
        switch providerID {
        case .appleContainerCLI:
            boundary = .init(
                adapter: AppleContainerCLIAdapter(
                    processRunner: RuntimeQualificationRecordingProcessRunner(recorder: recorder)
                ),
                helperClient: nil,
                helperSocketURL: nil
            )
        case .appleContainerization:
            guard let hostExecutable = Bundle.main.executableURL else {
                throw RuntimeQualificationMigrationDriverError.providerPreflightFailed
            }
            let client = ContainerizationHelperClient(
                configuration: try .installed(hostExecutableURL: hostExecutable)
            )
            boundary = .init(
                adapter: AppleContainerizationRuntimeAdapter(client: client),
                helperClient: client,
                helperSocketURL: try ContainerizationHelperClientConfiguration.installed(
                    hostExecutableURL: hostExecutable
                ).socketURL
            )
        default:
            throw RuntimeQualificationMigrationDriverError.invalidSpecification
        }
        let snapshot = try await boundary.adapter.capabilitySnapshot()
        guard snapshot.descriptor.providerID == providerID,
              try await boundary.adapter.runtimeVersion() == expectedVersion,
              RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).isEmpty else {
            _ = await boundary.shutdown()
            throw RuntimeQualificationMigrationDriverError.providerPreflightFailed
        }
        return boundary
    }

    func shutdown() async -> Bool {
        guard let helperClient, let helperSocketURL else { return true }
        await helperClient.shutdown()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            var metadata = stat()
            errno = 0
            if lstat(helperSocketURL.path, &metadata) != 0, errno == ENOENT {
                return true
            }
            usleep(10_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }
}

private actor RuntimeQualificationMigrationPreviewJournal: RuntimeProviderMigrationJournaling {
    func beginOrResume(_ intent: RuntimeProviderMigrationIntent) async throws
        -> RuntimeProviderMigrationAcquireResult {
        throw RuntimeProviderMigrationError.invalidRequest("Preview cannot acquire an operation.")
    }
    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool { false }
    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        throw RuntimeProviderMigrationError.invalidRequest("Preview cannot record a checkpoint.")
    }
    func commitProviderBinding(_ commit: RuntimeProviderMigrationBindingCommit) async throws
        -> RuntimeProviderMigrationBindingCommitResult {
        throw RuntimeProviderMigrationError.invalidRequest("Preview cannot commit a binding.")
    }
    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {
        throw RuntimeProviderMigrationError.invalidRequest("Preview cannot finish an operation.")
    }
}

private actor RuntimeQualificationMigrationStartFaultBoundary: RuntimeAdapter {
    private let base: any RuntimeAdapter
    private var armed = true

    init(base: any RuntimeAdapter) { self.base = base }
    func metadata() async -> RuntimeAdapterMetadata { await base.metadata() }
    func capabilities() async throws -> [RuntimeCapability] { try await base.capabilities() }
    func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await base.capabilitySnapshot()
    }
    func inventory() async throws -> RuntimeInventory { try await base.inventory() }
    func observe(desiredState: DesiredRuntimeState) async throws -> ObservedRuntimeState {
        try await base.observe(desiredState: desiredState)
    }
    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        try await base.plan(desiredState: desiredState, observedState: observedState)
    }
    func logs(for service: ObservedRuntimeService, tail: Int) async throws -> RuntimeLogResult {
        try await base.logs(for: service, tail: tail)
    }
    func runtimeVersion() async throws -> String { try await base.runtimeVersion() }
    func runtimeReadiness() async throws -> RuntimeReadinessReport {
        try await base.runtimeReadiness()
    }
    func localImageEvidence(for imageReference: String) async throws -> RuntimeLocalImageEvidence {
        try await base.localImageEvidence(for: imageReference)
    }
    func resourceUsage(for resourceIdentifier: String) async throws
        -> RuntimeResourceUsageSnapshot {
        try await base.resourceUsage(for: resourceIdentifier)
    }
    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        if action.kind == .start, armed {
            armed = false
            throw RuntimeAdapterError.runtimeUnavailable(
                "Injected bounded Phase 03 migration checkpoint failure."
            )
        }
        return try await base.execute(action, confirmation: confirmation)
    }
}

private actor RuntimeQualificationMigrationCheckpointPrimingJournal:
    RuntimeProviderMigrationJournaling {
    private let base: any RuntimeProviderMigrationJournaling
    private let desired: DesiredRuntimeService
    private let sourceOwnership: RuntimeInventoryOwnershipEvidence
    private let targetProviderID: RuntimeProviderID
    private let targetProviderGeneration: Int
    private let migrationFencingToken: String
    private let source: any RuntimeAdapter
    private let target: any RuntimeAdapter
    private let sourceCapabilitySHA256: String
    private let targetCapabilitySHA256: String
    private var primed = false

    init(
        base: any RuntimeProviderMigrationJournaling,
        desired: DesiredRuntimeService,
        sourceOwnership: RuntimeInventoryOwnershipEvidence,
        targetProviderID: RuntimeProviderID,
        targetProviderGeneration: Int,
        migrationFencingToken: String,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter,
        sourceCapabilitySHA256: String,
        targetCapabilitySHA256: String
    ) {
        self.base = base
        self.desired = desired
        self.sourceOwnership = sourceOwnership
        self.targetProviderID = targetProviderID
        self.targetProviderGeneration = targetProviderGeneration
        self.migrationFencingToken = migrationFencingToken
        self.source = source
        self.target = target
        self.sourceCapabilitySHA256 = sourceCapabilitySHA256
        self.targetCapabilitySHA256 = targetCapabilitySHA256
    }

    func beginOrResume(
        _ intent: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult {
        let result = try await base.beginOrResume(intent)
        guard !primed else { return result }
        guard case .acquired = result else {
            throw RuntimeQualificationMigrationDriverError.recoveryFailed
        }
        primed = true
        try await RuntimeQualificationMigrationDriver.mutate(
            .stop,
            adapter: source,
            desired: desired,
            ownership: sourceOwnership,
            capabilitySHA256: sourceCapabilitySHA256,
            operationID: intent.operationID
        )
        try await base.recordCheckpoint(
            operationID: intent.operationID,
            fencingToken: intent.fencingToken,
            checkpoint: .sourceQuiesced,
            verificationSHA256: try await source.inventory().semanticSHA256
        )
        try await base.recordCheckpoint(
            operationID: intent.operationID,
            fencingToken: intent.fencingToken,
            checkpoint: .sourceVerified,
            verificationSHA256: try await source.inventory().semanticSHA256
        )
        let targetOwnership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: sourceOwnership.resourceUUID,
            projectUUID: sourceOwnership.projectUUID,
            resourceGeneration: sourceOwnership.resourceGeneration,
            projectGeneration: sourceOwnership.projectGeneration,
            providerID: targetProviderID,
            providerGeneration: targetProviderGeneration,
            fencingToken: migrationFencingToken
        )
        try await RuntimeQualificationMigrationDriver.mutate(
            .create,
            adapter: target,
            desired: desired,
            ownership: targetOwnership,
            capabilitySHA256: targetCapabilitySHA256,
            operationID: intent.operationID
        )
        try await base.recordCheckpoint(
            operationID: intent.operationID,
            fencingToken: intent.fencingToken,
            checkpoint: .targetCreated,
            verificationSHA256: try await target.inventory().semanticSHA256
        )
        return .resumed(RuntimeProviderMigrationLease(
            operationID: intent.operationID,
            fencingToken: intent.fencingToken,
            confirmationToken: intent.confirmationToken,
            checkpoint: .targetCreated
        ))
    }

    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool {
        try await base.verifyFence(operationID: operationID, fencingToken: fencingToken)
    }
    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        try await base.recordCheckpoint(
            operationID: operationID,
            fencingToken: fencingToken,
            checkpoint: checkpoint,
            verificationSHA256: verificationSHA256
        )
    }
    func commitProviderBinding(
        _ commit: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult {
        try await base.commitProviderBinding(commit)
    }
    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {
        try await base.finish(
            operationID: operationID,
            fencingToken: fencingToken,
            status: status,
            checkpoint: checkpoint
        )
    }
}

struct RuntimeQualificationMigrationDriver {
    private let specification: RuntimeQualificationMigrationSpecification
    let recorder: RuntimeQualificationCommandRecorder

    init(
        specification: RuntimeQualificationMigrationSpecification,
        recorder: RuntimeQualificationCommandRecorder = RuntimeQualificationCommandRecorder()
    ) throws {
        self.specification = try specification.validated()
        self.recorder = recorder
    }

    func run() async throws -> RuntimeQualificationMigrationEvidence {
        let source = try await RuntimeQualificationMigrationProviderBoundary.make(
            providerID: specification.sourceProviderID,
            expectedVersion: specification.expectedSourceVersion,
            recorder: recorder
        )
        let target: RuntimeQualificationMigrationProviderBoundary
        do {
            target = try await RuntimeQualificationMigrationProviderBoundary.make(
                providerID: specification.targetProviderID,
                expectedVersion: specification.expectedTargetVersion,
                recorder: recorder
            )
        } catch {
            guard await source.shutdown() else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            throw error
        }
        await recorder.record(
            arguments: ["hostwright-runtime-conformance", "migration",
                        specification.sourceProviderID.rawValue,
                        specification.targetProviderID.rawValue],
            exitStatus: 0
        )
        var cleanupContext: (
            workspace: RuntimeQualificationMigrationStateFoundation,
            identity: RuntimeServiceIdentity
        )?
        do {
            let sourceSnapshot = try await source.adapter.capabilitySnapshot()
            let targetSnapshot = try await target.adapter.capabilitySnapshot()
            let sourceImage = try await source.adapter.localImageEvidence(
                for: specification.localImage
            )
            let targetImage = try await target.adapter.localImageEvidence(
                for: specification.localImage
            )
            guard sourceImage.reference == specification.localImage,
                  targetImage.reference == specification.localImage,
                  sourceImage.descriptorDigest == targetImage.descriptorDigest,
                  sourceImage.variantDigest == targetImage.variantDigest,
                  Self.validOCIDigest(sourceImage.descriptorDigest),
                  Self.validOCIDigest(sourceImage.variantDigest) else {
                throw RuntimeQualificationMigrationDriverError.providerPreflightFailed
            }

            let workspace = try RuntimeQualificationMigrationStateFoundation.make(
                sourceProviderID: specification.sourceProviderID,
                image: specification.localImage
            )
            let identity = RuntimeServiceIdentity(
                projectName: workspace.projectName,
                serviceName: workspace.serviceName
            )
            cleanupContext = (workspace, identity)
            let desired = DesiredRuntimeService(
                identity: identity,
                image: specification.localImage,
                command: ["sleep", "3600"]
            )
            let sourceOwnership = RuntimeInventoryOwnershipEvidence(
                resourceUUID: workspace.resourceUUID,
                projectUUID: workspace.projectUUID,
                resourceGeneration: 1,
                projectGeneration: 1,
                providerID: specification.sourceProviderID,
                providerGeneration: 1,
                fencingToken: workspace.sourceFencingToken
            )
            let sourceBefore = try await Self.unmanagedDigest(
                source.adapter, excluding: workspace.resourceUUID
            )
            let targetBefore = try await Self.unmanagedDigest(
                target.adapter, excluding: workspace.resourceUUID
            )

            try await Self.requireAbsent(
                identity: identity,
                resourceUUID: workspace.resourceUUID,
                adapters: [source.adapter, target.adapter]
            )
            try await Self.mutate(
                .create, adapter: source.adapter, desired: desired,
                ownership: sourceOwnership,
                capabilitySHA256: sourceSnapshot.canonicalSHA256,
                operationID: "phase03-migration-source-create"
            )
            try await Self.mutate(
                .start, adapter: source.adapter, desired: desired,
                ownership: sourceOwnership,
                capabilitySHA256: sourceSnapshot.canonicalSHA256,
                operationID: "phase03-migration-source-start"
            )

            let request = Self.request(
                workspace: workspace,
                desired: desired,
                ownership: sourceOwnership,
                sourceProviderID: specification.sourceProviderID,
                sourceProviderGeneration: 1,
                targetProviderID: specification.targetProviderID,
                sourceCapabilitySHA256: sourceSnapshot.canonicalSHA256,
                targetCapabilitySHA256: targetSnapshot.canonicalSHA256
            )
            let plan = try await RuntimeProviderMigrationEngine(
                journal: RuntimeQualificationMigrationPreviewJournal()
            ).dryRun(request: request, source: source.adapter, target: target.adapter)

            try await Self.verifyStaleConfirmation(
                plan: plan, request: request, store: workspace.store,
                source: source.adapter, target: target.adapter
            )
            try await Self.verifyCollision(
                plan: plan, request: request, desired: desired,
                workspace: workspace, source: source.adapter, target: target.adapter,
                targetSnapshot: targetSnapshot
            )
            try await Self.verifyUnavailableImage(
                target.adapter, resourceUUID: workspace.resourceUUID
            )
            try await Self.verifyRollback(
                plan: plan, request: request, workspace: workspace,
                source: source.adapter, target: target.adapter
            )

            let forward = try await Self.resumeAtTargetCreated(
                plan: plan, request: request, desired: desired,
                workspace: workspace, source: source.adapter, target: target.adapter,
                sourceSnapshot: sourceSnapshot, targetSnapshot: targetSnapshot
            )
            try Self.verifyState(
                workspace, providerID: specification.targetProviderID,
                generation: 2, fencingToken: workspace.migrationFencingToken
            )

            let migratedOwnership = RuntimeInventoryOwnershipEvidence(
                resourceUUID: workspace.resourceUUID,
                projectUUID: workspace.projectUUID,
                resourceGeneration: 1,
                projectGeneration: 1,
                providerID: specification.targetProviderID,
                providerGeneration: 2,
                fencingToken: workspace.migrationFencingToken
            )
            let reverseRequest = Self.request(
                workspace: workspace,
                desired: desired,
                ownership: migratedOwnership,
                sourceProviderID: specification.targetProviderID,
                sourceProviderGeneration: 2,
                targetProviderID: specification.sourceProviderID,
                sourceCapabilitySHA256: targetSnapshot.canonicalSHA256,
                targetCapabilitySHA256: sourceSnapshot.canonicalSHA256
            )
            let reversePlan = try await RuntimeProviderMigrationEngine(
                journal: RuntimeQualificationMigrationPreviewJournal()
            ).dryRun(request: reverseRequest, source: target.adapter, target: source.adapter)
            let reverseFence = UUID().uuidString.lowercased()
            let reverse = try await RuntimeProviderMigrationEngine(
                journal: RuntimeProviderMigrationJournalFactory.sqlite(
                    store: workspace.store,
                    plan: reversePlan,
                    request: reverseRequest
                )
            ).execute(
                plan: reversePlan,
                request: reverseRequest,
                confirmationToken: reversePlan.confirmationToken,
                operationID: "phase03-migration-reverse-\(UUID().uuidString.lowercased())",
                fencingToken: reverseFence,
                source: target.adapter,
                target: source.adapter
            )
            guard reverse.checkpoint == .sourceRetired,
                  reverse.providerID == specification.sourceProviderID,
                  reverse.providerGeneration == 3 else {
                throw RuntimeQualificationMigrationDriverError.migrationFailed
            }
            try Self.verifyState(
                workspace, providerID: specification.sourceProviderID,
                generation: 3, fencingToken: reverseFence
            )
            let finalOwnership = RuntimeInventoryOwnershipEvidence(
                resourceUUID: workspace.resourceUUID,
                projectUUID: workspace.projectUUID,
                resourceGeneration: 1,
                projectGeneration: 1,
                providerID: specification.sourceProviderID,
                providerGeneration: 3,
                fencingToken: reverseFence
            )
            try await Self.removeExact(
                source.adapter, desired: desired, ownership: finalOwnership,
                capabilitySHA256: sourceSnapshot.canonicalSHA256
            )
            try await Self.requireAbsent(
                identity: identity,
                resourceUUID: workspace.resourceUUID,
                adapters: [source.adapter, target.adapter]
            )
            let sourceAfter = try await Self.unmanagedDigest(
                source.adapter, excluding: workspace.resourceUUID
            )
            let targetAfter = try await Self.unmanagedDigest(
                target.adapter, excluding: workspace.resourceUUID
            )
            guard sourceBefore == sourceAfter, targetBefore == targetAfter else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            let stateSchemaVersion = try workspace.store.schemaVersion()
            try workspace.remove()
            cleanupContext = nil
            guard await source.shutdown(), await target.shutdown() else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            return RuntimeQualificationMigrationEvidence(
                schemaVersion: 1,
                sourceProviderID: specification.sourceProviderID.rawValue,
                targetProviderID: specification.targetProviderID.rawValue,
                projectUUID: workspace.projectUUID,
                resourceUUID: workspace.resourceUUID,
                fixtureImageReference: sourceImage.reference,
                fixtureImageDescriptorDigest: sourceImage.descriptorDigest,
                fixtureImageVariantDigest: sourceImage.variantDigest,
                sourceCapabilitySHA256: sourceSnapshot.canonicalSHA256,
                targetCapabilitySHA256: targetSnapshot.canonicalSHA256,
                staleConfirmationRefused: true,
                targetCollisionRefused: true,
                unavailableImageRefused: true,
                rollbackVerified: true,
                checkpointRecovered: forward.resumed,
                forwardCheckpoint: String(describing: forward.checkpoint),
                reverseCheckpoint: String(describing: reverse.checkpoint),
                stateSchemaVersion: stateSchemaVersion,
                sourceInventoryBeforeSHA256: sourceBefore,
                sourceInventoryAfterSHA256: sourceAfter,
                targetInventoryBeforeSHA256: targetBefore,
                targetInventoryAfterSHA256: targetAfter,
                cleanupComplete: true
            )
        } catch {
            let originalError = error
            var cleanupSucceeded = true
            if let cleanupContext {
                do {
                    try await Self.cleanup(
                        identity: cleanupContext.identity,
                        resourceUUID: cleanupContext.workspace.resourceUUID,
                        adapters: [source.adapter, target.adapter]
                    )
                    try await Self.requireAbsent(
                        identity: cleanupContext.identity,
                        resourceUUID: cleanupContext.workspace.resourceUUID,
                        adapters: [source.adapter, target.adapter]
                    )
                    try cleanupContext.workspace.remove()
                } catch {
                    cleanupSucceeded = false
                }
            }
            let sourceStopped = await source.shutdown()
            let targetStopped = await target.shutdown()
            guard cleanupSucceeded, sourceStopped, targetStopped else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            throw originalError
        }
    }
}

private extension RuntimeQualificationMigrationDriver {
    static func validOCIDigest(_ value: String) -> Bool {
        value.range(
            of: #"^sha256:[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    static func request(
        workspace: RuntimeQualificationMigrationStateFoundation,
        desired: DesiredRuntimeService,
        ownership: RuntimeInventoryOwnershipEvidence,
        sourceProviderID: RuntimeProviderID,
        sourceProviderGeneration: Int,
        targetProviderID: RuntimeProviderID,
        sourceCapabilitySHA256: String,
        targetCapabilitySHA256: String
    ) -> RuntimeProviderMigrationRequest {
        RuntimeProviderMigrationRequest(
            projectName: workspace.projectName,
            projectUUID: workspace.projectUUID,
            projectGeneration: 1,
            sourceProviderID: sourceProviderID,
            sourceProviderGeneration: sourceProviderGeneration,
            targetProviderID: targetProviderID,
            resources: [RuntimeProviderMigrationResource(
                desiredService: desired,
                ownership: ownership
            )],
            expectedSourceCapabilitySHA256: sourceCapabilitySHA256,
            expectedTargetCapabilitySHA256: targetCapabilitySHA256
        )
    }

    static func verifyStaleConfirmation(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        store: SQLiteStateStore,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws {
        let sourceBefore = try await source.inventory().semanticSHA256
        let targetBefore = try await target.inventory().semanticSHA256
        do {
            _ = try await RuntimeProviderMigrationEngine(
                journal: RuntimeProviderMigrationJournalFactory.sqlite(
                    store: store, plan: plan, request: request
                )
            ).execute(
                plan: plan,
                request: request,
                confirmationToken: RuntimeProviderMigrationPlan.confirmationPrefix
                    + String(repeating: "0", count: 64),
                operationID: "phase03-stale-confirmation",
                fencingToken: UUID().uuidString.lowercased(),
                source: source,
                target: target
            )
            throw RuntimeQualificationMigrationDriverError.expectedRefusalMissing
        } catch let error as RuntimeProviderMigrationError {
            guard error == .confirmationMismatch else { throw error }
        }
        guard try await source.inventory().semanticSHA256 == sourceBefore,
              try await target.inventory().semanticSHA256 == targetBefore else {
            throw RuntimeQualificationMigrationDriverError.expectedRefusalMissing
        }
    }

    static func verifyCollision(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        desired: DesiredRuntimeService,
        workspace: RuntimeQualificationMigrationStateFoundation,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter,
        targetSnapshot: RuntimeCapabilitySnapshot
    ) async throws {
        let collision = RuntimeInventoryOwnershipEvidence(
            resourceUUID: UUID().uuidString.lowercased(),
            projectUUID: workspace.projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: request.targetProviderID,
            providerGeneration: plan.targetProviderGeneration,
            fencingToken: UUID().uuidString.lowercased()
        )
        try await mutate(
            .create, adapter: target, desired: desired, ownership: collision,
            capabilitySHA256: targetSnapshot.canonicalSHA256,
            operationID: "phase03-migration-collision-create"
        )
        do {
            _ = try await RuntimeProviderMigrationEngine(
                journal: RuntimeQualificationMigrationPreviewJournal()
            ).dryRun(request: request, source: source, target: target)
            throw RuntimeQualificationMigrationDriverError.expectedRefusalMissing
        } catch let error as RuntimeProviderMigrationError {
            guard error == .targetCollision(desired.identity.managedResourceIdentifier) else {
                try? await removeExact(
                    target, desired: desired, ownership: collision,
                    capabilitySHA256: targetSnapshot.canonicalSHA256
                )
                throw error
            }
        }
        try await removeExact(
            target, desired: desired, ownership: collision,
            capabilitySHA256: targetSnapshot.canonicalSHA256
        )
    }

    static func verifyUnavailableImage(
        _ adapter: any RuntimeAdapter,
        resourceUUID: String
    ) async throws {
        let missing = "example.invalid/hostwright-phase03-\(resourceUUID.prefix(8)):missing"
        do {
            _ = try await adapter.localImageEvidence(for: missing)
            throw RuntimeQualificationMigrationDriverError.expectedRefusalMissing
        } catch is RuntimeQualificationMigrationDriverError {
            throw RuntimeQualificationMigrationDriverError.expectedRefusalMissing
        } catch let error as RuntimeAdapterError {
            let metadata = await adapter.metadata()
            let normalized = RuntimeNormalizedFailure.normalize(
                error,
                providerID: metadata.providerID.rawValue,
                providerVersion: metadata.runtimeVersion ?? "unknown",
                operationID: "phase03-migration-missing-image"
            )
            guard normalized.category == .rejected else { throw error }
        } catch {
            throw error
        }
    }

    static func verifyRollback(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        workspace: RuntimeQualificationMigrationStateFoundation,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter
    ) async throws {
        do {
            _ = try await RuntimeProviderMigrationEngine(
                journal: RuntimeProviderMigrationJournalFactory.sqlite(
                    store: workspace.store, plan: plan, request: request
                )
            ).execute(
                plan: plan,
                request: request,
                confirmationToken: plan.confirmationToken,
                operationID: "phase03-migration-rollback-\(UUID().uuidString.lowercased())",
                fencingToken: UUID().uuidString.lowercased(),
                source: source,
                target: RuntimeQualificationMigrationStartFaultBoundary(base: target)
            )
            throw RuntimeQualificationMigrationDriverError.rollbackFailed
        } catch let error as RuntimeProviderMigrationError {
            guard case .providerFailure(let providerID, let checkpoint) = error,
                  providerID == request.targetProviderID,
                  checkpoint == .targetVerified else {
                throw error
            }
        }
        let sourceInventory = try await source.inventory()
        let targetInventory = try await target.inventory()
        guard let restored = sourceInventory.containers.first(where: {
            $0.ownership?.resourceUUID == workspace.resourceUUID
        }),
        restored.lifecycle == .running,
        restored.ownership?.fencingToken == workspace.sourceFencingToken,
        !targetInventory.containers.contains(where: {
            $0.ownership?.resourceUUID == workspace.resourceUUID
        }) else {
            throw RuntimeQualificationMigrationDriverError.rollbackFailed
        }
        try verifyState(
            workspace,
            providerID: request.sourceProviderID,
            generation: request.sourceProviderGeneration,
            fencingToken: workspace.sourceFencingToken
        )
    }

    static func resumeAtTargetCreated(
        plan: RuntimeProviderMigrationPlan,
        request: RuntimeProviderMigrationRequest,
        desired: DesiredRuntimeService,
        workspace: RuntimeQualificationMigrationStateFoundation,
        source: any RuntimeAdapter,
        target: any RuntimeAdapter,
        sourceSnapshot: RuntimeCapabilitySnapshot,
        targetSnapshot: RuntimeCapabilitySnapshot
    ) async throws -> RuntimeProviderMigrationResult {
        let operationID = "phase03-migration-resume-\(UUID().uuidString.lowercased())"
        guard let sourceOwnership = request.resources.first?.ownership else {
            throw RuntimeQualificationMigrationDriverError.recoveryFailed
        }
        let durableJournal = RuntimeProviderMigrationJournalFactory.sqlite(
            store: workspace.store, plan: plan, request: request
        )
        let journal = RuntimeQualificationMigrationCheckpointPrimingJournal(
            base: durableJournal,
            desired: desired,
            sourceOwnership: sourceOwnership,
            targetProviderID: request.targetProviderID,
            targetProviderGeneration: plan.targetProviderGeneration,
            migrationFencingToken: workspace.migrationFencingToken,
            source: source,
            target: target,
            sourceCapabilitySHA256: sourceSnapshot.canonicalSHA256,
            targetCapabilitySHA256: targetSnapshot.canonicalSHA256
        )
        let result = try await RuntimeProviderMigrationEngine(journal: journal).execute(
            plan: plan,
            request: request,
            confirmationToken: plan.confirmationToken,
            operationID: operationID,
            fencingToken: workspace.migrationFencingToken,
            source: source,
            target: target
        )
        guard result.resumed, result.checkpoint == .sourceRetired else {
            throw RuntimeQualificationMigrationDriverError.recoveryFailed
        }
        return result
    }

    static func mutate(
        _ kind: PlannedRuntimeActionKind,
        adapter: any RuntimeAdapter,
        desired: DesiredRuntimeService,
        ownership: RuntimeInventoryOwnershipEvidence,
        capabilitySHA256: String,
        operationID: String
    ) async throws {
        _ = try await adapter.execute(
            PlannedRuntimeAction(
                kind: kind,
                identity: desired.identity,
                resourceIdentifier: desired.identity.managedResourceIdentifier,
                isDestructive: [.stop, .remove, .restart].contains(kind),
                summary: "Phase 03 runtime provider migration qualification.",
                desiredService: desired
            ),
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Phase 03 maintainer migration qualification.",
                planHash: capabilitySHA256,
                context: RuntimeMutationContext(
                    providerID: ownership.providerID,
                    capabilitySHA256: capabilitySHA256,
                    operationID: operationID,
                    resourceUUID: ownership.resourceUUID,
                    resourceGeneration: ownership.resourceGeneration,
                    projectResourceUUID: ownership.projectUUID,
                    projectGeneration: ownership.projectGeneration,
                    providerGeneration: ownership.providerGeneration,
                    fencingToken: ownership.fencingToken
                )
            )
        )
    }

    static func removeExact(
        _ adapter: any RuntimeAdapter,
        desired: DesiredRuntimeService,
        ownership: RuntimeInventoryOwnershipEvidence,
        capabilitySHA256: String
    ) async throws {
        let inventory = try await adapter.inventory()
        guard let container = inventory.containers.first(where: {
            $0.ownership?.resourceUUID == ownership.resourceUUID
        }) else { return }
        guard container.name == desired.identity.managedResourceIdentifier,
              container.ownership == ownership else {
            throw RuntimeQualificationMigrationDriverError.ownershipMismatch
        }
        if container.lifecycle == .running {
            try await mutate(
                .stop, adapter: adapter, desired: desired, ownership: ownership,
                capabilitySHA256: capabilitySHA256,
                operationID: "phase03-migration-cleanup-stop"
            )
        }
        try await mutate(
            .remove, adapter: adapter, desired: desired, ownership: ownership,
            capabilitySHA256: capabilitySHA256,
            operationID: "phase03-migration-cleanup-remove"
        )
    }

    static func cleanup(
        identity: RuntimeServiceIdentity,
        resourceUUID: String,
        adapters: [any RuntimeAdapter]
    ) async throws {
        for adapter in adapters {
            let inventory = try await adapter.inventory()
            guard let container = inventory.containers.first(where: {
                $0.ownership?.resourceUUID == resourceUUID
            }) else { continue }
            guard let ownership = container.ownership,
                  container.name == identity.managedResourceIdentifier else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
            let snapshot = try await adapter.capabilitySnapshot()
            try await removeExact(
                adapter,
                desired: DesiredRuntimeService(
                    identity: identity,
                    image: container.imageReference,
                    command: container.initConfiguration.arguments
                ),
                ownership: ownership,
                capabilitySHA256: snapshot.canonicalSHA256
            )
        }
    }

    static func requireAbsent(
        identity: RuntimeServiceIdentity,
        resourceUUID: String,
        adapters: [any RuntimeAdapter]
    ) async throws {
        for adapter in adapters {
            let inventory = try await adapter.inventory()
            guard !inventory.containers.contains(where: {
                $0.ownership?.resourceUUID == resourceUUID ||
                    $0.name == identity.managedResourceIdentifier
            }) else {
                throw RuntimeQualificationMigrationDriverError.cleanupFailed
            }
        }
    }

    static func unmanagedDigest(
        _ adapter: any RuntimeAdapter,
        excluding resourceUUID: String
    ) async throws -> String {
        let inventory = try await adapter.inventory()
        let containers = inventory.containers.filter {
            $0.ownership?.resourceUUID != resourceUUID
        }.map {
            RuntimeInventoryContainer(
                runtimeID: $0.runtimeID,
                name: $0.name,
                imageID: $0.imageID,
                imageReference: $0.imageReference,
                lifecycle: $0.lifecycle,
                health: $0.health,
                labels: $0.labels,
                ownership: $0.ownership,
                initConfiguration: $0.initConfiguration,
                ports: $0.ports,
                mounts: $0.mounts,
                networks: $0.networks,
                allocation: $0.allocation,
                usage: nil,
                services: $0.services
            )
        }
        return try RuntimeInventoryBuilder.build(
            machine: inventory.machine,
            containers: containers,
            images: inventory.images,
            networks: inventory.networks,
            volumes: inventory.volumes
        ).semanticSHA256
    }

    static func verifyState(
        _ workspace: RuntimeQualificationMigrationStateFoundation,
        providerID: RuntimeProviderID,
        generation: Int,
        fencingToken: String
    ) throws {
        let project = try workspace.store.desiredStates.loadProject(id: workspace.projectID)
        let ownership = try workspace.store.ownership.loadAll().first {
            $0.resourceUUID == workspace.resourceUUID
        }
        guard project.resourceUUID == workspace.projectUUID,
              project.mutationProvider == providerID.rawValue,
              project.providerGeneration == generation,
              ownership?.runtimeAdapter == providerID.rawValue,
              ownership?.providerGeneration == generation,
              ownership?.fencingToken == fencingToken else {
            throw RuntimeQualificationMigrationDriverError.stateFoundationFailed
        }
    }
}
