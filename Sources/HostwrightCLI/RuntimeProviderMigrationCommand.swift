import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

struct RuntimeProviderMigrationCommandRunner {
    let options: RuntimeProviderMigrationCLIOptions
    let environment: CLIEnvironment

    func run() -> CLIRunResult {
        do {
            let manifestText = try hostwrightReadManifestText(
                path: options.manifestPath,
                environment: environment
            )
            let validated = try hostwrightValidatedManifest(
                text: manifestText,
                teamProfilePath: nil,
                environment: environment
            )
            let mapping = ManifestRuntimeMapper.map(validated.manifest)
            guard mapping.issues.isEmpty else {
                throw RuntimeProviderMigrationError.invalidRequest(
                    mapping.issues.map(\.message).joined(separator: " ")
                )
            }

            let projectName = mapping.desiredState.projectName
            let projectID = "project-\(projectName)"
            let store = SQLiteStateStore(
                configuration: try hostwrightStateStoreConfiguration(
                    explicitPath: options.stateDatabasePath,
                    environment: environment
                )
            )
            try store.migrate()

            let resumable = try options.confirmationToken.flatMap { token in
                try SQLiteRuntimeProviderMigrationJournal.resumableRecord(
                    store: store,
                    projectID: projectID,
                    confirmationToken: token
                )
            }
            if let resumable,
               resumable.plan.targetProviderID != options.targetProviderID {
                throw RuntimeProviderMigrationError.planChanged
            }

            let request = try migrationRequest(
                projectID: projectID,
                desiredState: mapping.desiredState,
                store: store,
                resumablePlan: resumable?.plan,
                resumableOperationID: resumable?.operationID
            )
            let source = try environment.runtimeAdapterForProvider(request.sourceProviderID)
            let target = try environment.runtimeAdapterForProvider(request.targetProviderID)

            if options.confirmationToken == nil {
                let engine = RuntimeProviderMigrationEngine(journal: RuntimeProviderMigrationPreviewJournal())
                let plan = try hostwrightWaitForAsync {
                    try await engine.dryRun(request: request, source: source, target: target)
                }
                return render(plan: plan)
            }

            guard let confirmationToken = options.confirmationToken else {
                throw RuntimeProviderMigrationError.confirmationMismatch
            }
            let plan: RuntimeProviderMigrationPlan
            let operationID: String
            let fencingToken: String
            if let resumable {
                plan = resumable.plan
                operationID = resumable.operationID
                fencingToken = resumable.fencingToken
            } else {
                let previewEngine = RuntimeProviderMigrationEngine(
                    journal: RuntimeProviderMigrationPreviewJournal()
                )
                plan = try hostwrightWaitForAsync {
                    try await previewEngine.dryRun(request: request, source: source, target: target)
                }
                guard plan.confirmationToken == confirmationToken else {
                    throw RuntimeProviderMigrationError.confirmationMismatch
                }
                operationID = hostwrightUniqueID(prefix: "operation-runtime-migration")
                fencingToken = HostwrightResourceUUID.generate()
            }

            let journal = SQLiteRuntimeProviderMigrationJournal(
                store: store,
                plan: plan,
                request: request
            )
            let engine = RuntimeProviderMigrationEngine(journal: journal)
            let result = try hostwrightWaitForAsync {
                try await engine.execute(
                    plan: plan,
                    request: request,
                    confirmationToken: confirmationToken,
                    operationID: operationID,
                    fencingToken: fencingToken,
                    source: source,
                    target: target
                )
            }
            return render(result: result)
        } catch let error as RuntimeProviderMigrationError {
            return failure(error)
        } catch let error as StateStoreError {
            return failure(
                code: .stateStoreUnavailable,
                message: error.description
            )
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(code: diagnostic.code, message: diagnostic.message)
        } catch {
            return failure(
                code: .runtimeUnavailable,
                message: RuntimeRedactionPolicy.default.redact(String(describing: error))
            )
        }
    }

    private func migrationRequest(
        projectID: String,
        desiredState: DesiredRuntimeState,
        store: SQLiteStateStore,
        resumablePlan: RuntimeProviderMigrationPlan?,
        resumableOperationID: String?
    ) throws -> RuntimeProviderMigrationRequest {
        let project = try store.desiredStates.loadProject(id: projectID)
        let sourceProviderID: RuntimeProviderID
        let sourceProviderGeneration: Int
        let projectUUID: String
        let projectGeneration: Int?
        var bindingAlreadyCommitted = false

        if let resumablePlan {
            guard resumablePlan.projectName == desiredState.projectName,
                  resumablePlan.targetProviderID == options.targetProviderID else {
                throw RuntimeProviderMigrationError.planChanged
            }
            sourceProviderID = resumablePlan.sourceProviderID
            sourceProviderGeneration = resumablePlan.sourceProviderGeneration
            projectUUID = resumablePlan.projectUUID
            projectGeneration = resumablePlan.projectGeneration

            guard let currentProvider = project.mutationProvider.flatMap(RuntimeProviderBinding.stableID(for:)),
                  (currentProvider == sourceProviderID &&
                      project.providerGeneration == sourceProviderGeneration) ||
                    (currentProvider == resumablePlan.targetProviderID &&
                      project.providerGeneration == resumablePlan.targetProviderGeneration) else {
                throw RuntimeProviderMigrationError.planChanged
            }
            bindingAlreadyCommitted = currentProvider == resumablePlan.targetProviderID &&
                project.providerGeneration == resumablePlan.targetProviderGeneration
        } else {
            guard let persistedProvider = project.mutationProvider,
                  let stableProvider = RuntimeProviderBinding.stableID(for: persistedProvider),
                  project.providerGeneration > 0 else {
                throw RuntimeProviderMigrationError.invalidRequest(
                    "Project \(desiredState.projectName) does not have a valid runtime provider binding."
                )
            }
            guard stableProvider != options.targetProviderID else {
                throw RuntimeProviderMigrationError.invalidRequest(
                    "Project \(desiredState.projectName) is already bound to \(options.targetProviderID.rawValue)."
                )
            }
            sourceProviderID = stableProvider
            sourceProviderGeneration = project.providerGeneration
            projectUUID = project.resourceUUID
            projectGeneration = nil
        }

        let resources: [RuntimeProviderMigrationResource]
        if bindingAlreadyCommitted, let resumablePlan {
            let planByIdentity = Dictionary(
                uniqueKeysWithValues: resumablePlan.resources.map { ($0.identity, $0) }
            )
            resources = try desiredState.services.sorted {
                $0.identity.displayName < $1.identity.displayName
            }.map { desired in
                guard let resource = planByIdentity[desired.identity.displayName],
                      resource.resourceIdentifier == desired.identity.managedResourceIdentifier else {
                    throw RuntimeProviderMigrationError.planChanged
                }
                return RuntimeProviderMigrationResource(
                    desiredService: desired,
                    ownership: RuntimeInventoryOwnershipEvidence(
                        resourceUUID: resource.resourceUUID,
                        projectUUID: resumablePlan.projectUUID,
                        resourceGeneration: resource.resourceGeneration,
                        projectGeneration: resumablePlan.projectGeneration,
                        providerID: resumablePlan.sourceProviderID,
                        providerGeneration: resumablePlan.sourceProviderGeneration,
                        fencingToken: resource.sourceFencingToken
                    )
                )
            }
            guard resources.count == resumablePlan.resources.count else {
                throw RuntimeProviderMigrationError.planChanged
            }
        } else {
            let hints = try store.ownership.runtimeHints(
                projectID: projectID,
                projectName: desiredState.projectName,
                providerID: sourceProviderID
            )
            let hintsByIdentity = Dictionary(grouping: hints, by: \.identity)
            resources = try desiredState.services.sorted {
                $0.identity.displayName < $1.identity.displayName
            }.map { desired -> RuntimeProviderMigrationResource in
                guard let matching = hintsByIdentity[desired.identity],
                      matching.count == 1,
                      let ownership = matching[0].ownership else {
                    throw RuntimeProviderMigrationError.ambiguousOwnership(
                        desired.identity.managedResourceIdentifier
                    )
                }
                return RuntimeProviderMigrationResource(
                    desiredService: desired,
                    ownership: ownership
                )
            }
            guard resources.count == hints.count else {
                throw RuntimeProviderMigrationError.ambiguousOwnership(desiredState.projectName)
            }
        }

        let ownershipProjectGenerations = Set(resources.map(\.ownership.projectGeneration))
        guard ownershipProjectGenerations.count == 1,
              let observedProjectGeneration = ownershipProjectGenerations.first,
              observedProjectGeneration > 0,
              projectGeneration == nil || projectGeneration == observedProjectGeneration,
              resources.allSatisfy({ resource in
                  resource.ownership.projectUUID == projectUUID &&
                    resource.ownership.providerGeneration == sourceProviderGeneration
              }) else {
            throw RuntimeProviderMigrationError.invalidRequest(
                "Persisted ownership does not match the project provider generation."
            )
        }

        let activeOperationIDs = try store.operationGroups.loadProject(projectID: projectID)
            .filter { $0.status == .active && $0.operationID != resumableOperationID }
            .map(\.operationID)
            .sorted()

        return RuntimeProviderMigrationRequest(
            projectName: desiredState.projectName,
            projectUUID: projectUUID,
            projectGeneration: observedProjectGeneration,
            sourceProviderID: sourceProviderID,
            sourceProviderGeneration: sourceProviderGeneration,
            targetProviderID: options.targetProviderID,
            resources: resources,
            activeOperationIDs: activeOperationIDs,
            expectedSourceCapabilitySHA256: resumablePlan?.sourceCapabilitySHA256,
            expectedTargetCapabilitySHA256: resumablePlan?.targetCapabilitySHA256
        )
    }

    private func render(plan: RuntimeProviderMigrationPlan) -> CLIRunResult {
        if options.output == .json {
            return CLIRunResult(standardOutput: CLIJSON.codable(plan))
        }
        let effects = plan.plannedEffects.map {
            "- \($0.kind.rawValue) [\($0.providerID.rawValue)]\($0.resourceUUID.map { " \($0)" } ?? "")"
        }.joined(separator: "\n")
        let rollback = plan.rollbackActions.map {
            "- \($0.kind.rawValue) [\($0.providerID.rawValue)] \($0.resourceUUID)"
        }.joined(separator: "\n")
        return CLIRunResult(
            standardOutput: """
            Runtime provider migration dry-run
            Project: \(plan.projectName)
            Source: \(plan.sourceProviderID.rawValue) generation \(plan.sourceProviderGeneration)
            Target: \(plan.targetProviderID.rawValue) generation \(plan.targetProviderGeneration)
            Source observation: \(plan.sourceObservationSHA256)
            Target observation: \(plan.targetObservationSHA256)
            Required local images: \(plan.requiredLocalImages.count)
            Planned effects:
            \(effects)
            Rollback actions:
            \(rollback)
            Confirmation token: \(plan.confirmationToken)

            """
        )
    }

    private func render(result: RuntimeProviderMigrationResult) -> CLIRunResult {
        let report = RuntimeProviderMigrationCLIResult(
            operationID: result.operationID,
            projectUUID: result.projectUUID,
            providerID: result.providerID,
            providerGeneration: result.providerGeneration,
            checkpoint: result.checkpoint,
            resumed: result.resumed
        )
        if options.output == .json {
            return CLIRunResult(standardOutput: CLIJSON.codable(report))
        }
        return CLIRunResult(
            standardOutput: """
            Runtime provider migration completed
            Operation: \(result.operationID)
            Project UUID: \(result.projectUUID)
            Provider: \(result.providerID.rawValue)
            Provider generation: \(result.providerGeneration)
            Checkpoint: \(result.checkpoint.rawValue)
            Resumed: \(result.resumed)

            """
        )
    }

    private func failure(_ error: RuntimeProviderMigrationError) -> CLIRunResult {
        let code: HostwrightErrorCode
        switch error {
        case .confirmationMismatch, .planChanged, .observationChanged, .staleCapability:
            code = .confirmationMismatch
        case .invalidRequest:
            code = .commandUsage
        case .providerFailure, .incompatibleProvider, .missingLocalImage,
             .invalidLocalImageEvidence:
            code = .runtimeUnavailable
        case .activeOperations, .ambiguousOwnership, .targetCollision,
             .unsupportedOwnedResource, .fencingConflict, .fenceLost,
             .unverifiedTargetResource, .compensationFailed, .cancelledAfterCompensation:
            code = .unsafeExposure
        }
        return failure(
            code: code,
            message: RuntimeProviderMigrationDiagnostic.message(error)
        )
    }

    private func failure(code: HostwrightErrorCode, message: String) -> CLIRunResult {
        let redacted = RuntimeRedactionPolicy.default.redact(message)
        let exitCode = CLIExitCode.mapped(from: code)
        if options.output == .json {
            return CLIRunResult(
                standardError: CLIJSON.error(
                    code: code,
                    message: redacted,
                    exitCode: exitCode
                ),
                exitCode: exitCode.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(code.rawValue): \(redacted)\n",
            exitCode: exitCode.rawValue
        )
    }
}

private struct RuntimeProviderMigrationCLIResult: Codable {
    let operationID: String
    let projectUUID: String
    let providerID: RuntimeProviderID
    let providerGeneration: Int
    let checkpoint: RuntimeProviderMigrationCheckpoint
    let resumed: Bool
}

private actor RuntimeProviderMigrationPreviewJournal: RuntimeProviderMigrationJournaling {
    func beginOrResume(
        _ intent: RuntimeProviderMigrationIntent
    ) async throws -> RuntimeProviderMigrationAcquireResult {
        throw RuntimeProviderMigrationError.invalidRequest(
            "A dry-run cannot acquire a migration operation."
        )
    }

    func verifyFence(operationID: String, fencingToken: String) async throws -> Bool {
        false
    }

    func recordCheckpoint(
        operationID: String,
        fencingToken: String,
        checkpoint: RuntimeProviderMigrationCheckpoint,
        verificationSHA256: String
    ) async throws {
        throw RuntimeProviderMigrationError.invalidRequest(
            "A dry-run cannot persist a migration checkpoint."
        )
    }

    func commitProviderBinding(
        _ commit: RuntimeProviderMigrationBindingCommit
    ) async throws -> RuntimeProviderMigrationBindingCommitResult {
        throw RuntimeProviderMigrationError.invalidRequest(
            "A dry-run cannot commit a provider binding."
        )
    }

    func finish(
        operationID: String,
        fencingToken: String,
        status: RuntimeProviderMigrationTerminalStatus,
        checkpoint: RuntimeProviderMigrationCheckpoint
    ) async throws {
        throw RuntimeProviderMigrationError.invalidRequest(
            "A dry-run cannot finish a migration operation."
        )
    }
}

private enum RuntimeProviderMigrationDiagnostic {
    static func message(_ error: RuntimeProviderMigrationError) -> String {
        switch error {
        case .invalidRequest(let detail):
            return "Runtime provider migration request is invalid: \(detail)"
        case .activeOperations(let identifiers):
            return "Runtime provider migration is blocked by active operations: \(identifiers.sorted().joined(separator: ", "))."
        case .staleCapability(let providerID, let expected, let current):
            return "Runtime provider \(providerID.rawValue) capability changed; expected \(expected), observed \(current). Generate a new dry-run."
        case .incompatibleProvider(let providerID, _):
            return "Runtime provider \(providerID.rawValue) does not satisfy the migration capability contract."
        case .ambiguousOwnership(let identifier):
            return "Runtime provider migration refused ambiguous ownership for \(identifier)."
        case .targetCollision(let identifier):
            return "Runtime provider migration refused target collision \(identifier)."
        case .unsupportedOwnedResource(let identifier):
            return "Runtime provider migration does not support owned resource \(identifier)."
        case .missingLocalImage(let image):
            return "Target provider does not have required local image \(image)."
        case .invalidLocalImageEvidence(let image):
            return "Target provider returned invalid local image evidence for \(image)."
        case .confirmationMismatch:
            return "Migration confirmation token does not match the current dry-run."
        case .planChanged:
            return "The confirmed migration plan no longer matches durable state. Generate a new dry-run unless an existing operation is resumable."
        case .fencingConflict(let operationID):
            return "Runtime provider migration is fenced by active operation \(operationID)."
        case .fenceLost:
            return "Runtime provider migration lost its durable fencing lease."
        case .observationChanged(let providerID, let expected, let current):
            return "Runtime provider \(providerID.rawValue) observation changed; expected \(expected), observed \(current). Generate a new dry-run."
        case .providerFailure(let providerID, let checkpoint):
            return "Runtime provider \(providerID.rawValue) failed at migration checkpoint \(checkpoint.rawValue)."
        case .unverifiedTargetResource(let identifier):
            return "Target resource \(identifier) could not be verified; the source binding remains authoritative."
        case .compensationFailed:
            return "Runtime provider migration compensation could not be verified. Manual recovery is required."
        case .cancelledAfterCompensation:
            return "Runtime provider migration was cancelled after verified compensation."
        }
    }
}
