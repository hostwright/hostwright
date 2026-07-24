import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState

public enum LifecycleCommandRunnerError: Error, Equatable, Sendable {
    case invalidInput(String)
    case mappingBlocked([String])
    case unknownService(String)
    case missingManagedResource(String)
    case ambiguousOwnership(String)
    case unsupportedStorage(String)
    case updateRequiresRolloutPlanner
    case missingLocalImage(String)
    case invalidLocalImageEvidence(String)
    case confirmationMismatch(expected: String, provided: String)

    var diagnostic: HostwrightDiagnostic {
        switch self {
        case .invalidInput(let message):
            HostwrightDiagnostic(code: .manifestValidationFailed, message: message)
        case .mappingBlocked(let messages):
            HostwrightDiagnostic(
                code: .manifestUnsupportedFeature,
                message: messages.joined(separator: "\n")
            )
        case .unknownService(let service):
            HostwrightDiagnostic(
                code: .commandUsage,
                message: "Manifest does not declare service '\(service)'. No mutation was attempted."
            )
        case .missingManagedResource(let identity):
            HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Lifecycle command requires an existing managed resource for \(identity). No mutation was attempted."
            )
        case .ambiguousOwnership(let resourceIdentifier):
            HostwrightDiagnostic(
                code: .unsafeExposure,
                message: "Exact UUID-backed ownership could not be proven for \(resourceIdentifier). No mutation was attempted."
            )
        case .unsupportedStorage(let source):
            HostwrightDiagnostic(
                code: .manifestUnsupportedFeature,
                message: "Mount source '\(source)' is not an existing bind mount. Named volumes and other storage providers require Phase 06. No mutation was attempted."
            )
        case .updateRequiresRolloutPlanner:
            HostwrightDiagnostic(
                code: .runtimeMutationNotImplemented,
                message: "Update is routed through the shared lifecycle engine, but execution requires the Phase 04 rollout planner. No mutation was attempted."
            )
        case .missingLocalImage(let reference):
            HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Required image '\(reference)' is not available locally. Phase 04 does not pull or build images. No mutation was attempted."
            )
        case .invalidLocalImageEvidence(let reference):
            HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message: "Local image evidence for '\(reference)' is incomplete or targets the wrong platform. No mutation was attempted."
            )
        case .confirmationMismatch(let expected, let provided):
            HostwrightDiagnostic(
                code: .confirmationMismatch,
                message: "Confirmed lifecycle plan does not match current manifest, observation, capability, or ownership state. expected=\(expected) provided=\(provided). No mutation was attempted."
            )
        }
    }
}

public struct LifecycleResourceBinding: Equatable, Sendable {
    public let identity: RuntimeServiceIdentity
    public let resourceIdentifier: String
    public let identityVersion: Int
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let projectResourceUUID: String
    public let projectGeneration: Int
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let currentFencingToken: String

    public init(
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String,
        identityVersion: Int = RuntimeManagedResourceIdentity.currentVersion,
        resourceUUID: String,
        resourceGeneration: Int,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        currentFencingToken: String
    ) throws {
        guard !resourceIdentifier.isEmpty,
              RuntimeManagedResourceIdentity.isSupportedIdentifier(resourceIdentifier),
              identityVersion == 1 || identityVersion == RuntimeManagedResourceIdentity.currentVersion,
              HostwrightResourceUUID.isValid(resourceUUID),
              HostwrightResourceUUID.isValid(projectResourceUUID),
              HostwrightResourceUUID.isValid(currentFencingToken),
              resourceGeneration > 0,
              projectGeneration > 0,
              providerGeneration > 0,
              RuntimeProviderID.knownValues.contains(providerID) else {
            throw LifecycleCommandRunnerError.ambiguousOwnership(resourceIdentifier)
        }
        self.identity = identity
        self.resourceIdentifier = resourceIdentifier
        self.identityVersion = identityVersion
        self.resourceUUID = resourceUUID.lowercased()
        self.resourceGeneration = resourceGeneration
        self.projectResourceUUID = projectResourceUUID.lowercased()
        self.projectGeneration = projectGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.currentFencingToken = currentFencingToken.lowercased()
    }

    public init(
        record: OwnershipRecord,
        identity: RuntimeServiceIdentity,
        providerID: RuntimeProviderID
    ) throws {
        guard record.resourceType == "container",
              let projectResourceUUID = record.projectResourceUUID,
              RuntimeProviderBinding.stableID(for: record.runtimeAdapter) == providerID else {
            throw LifecycleCommandRunnerError.ambiguousOwnership(record.resourceIdentifier)
        }
        try self.init(
            identity: identity,
            resourceIdentifier: record.resourceIdentifier,
            identityVersion: record.identityVersion,
            resourceUUID: record.resourceUUID,
            resourceGeneration: record.resourceGeneration,
            projectResourceUUID: projectResourceUUID,
            projectGeneration: record.projectGeneration,
            providerID: providerID,
            providerGeneration: record.providerGeneration,
            currentFencingToken: record.fencingToken
        )
    }

    var ownershipEvidence: RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectResourceUUID,
            resourceGeneration: resourceGeneration,
            projectGeneration: projectGeneration,
            providerID: providerID,
            providerGeneration: providerGeneration,
            fencingToken: currentFencingToken
        )
    }
}

public struct LifecycleCommandPreparation: Sendable {
    public let manifestSHA256: String
    public let manifestBaseDirectory: String
    public let mappingIssues: [PlanIssue]
    public let desiredState: DesiredRuntimeState
    public let previousDesiredState: DesiredRuntimeState?
    public let observedState: ObservedRuntimeState
    public let observationSHA256: String
    public let projectID: String
    public let projectResourceUUID: String
    public let projectGeneration: Int
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let capabilitySHA256: String
    public let planFencingToken: String
    public let resourceBindings: [LifecycleResourceBinding]
    public let unmanagedResourceIdentifiers: Set<String>

    public init(
        manifestSHA256: String,
        manifestBaseDirectory: String,
        mappingIssues: [PlanIssue] = [],
        desiredState: DesiredRuntimeState,
        previousDesiredState: DesiredRuntimeState? = nil,
        observedState: ObservedRuntimeState,
        observationSHA256: String,
        projectID: String,
        projectResourceUUID: String,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        capabilitySHA256: String,
        planFencingToken: String,
        resourceBindings: [LifecycleResourceBinding] = [],
        unmanagedResourceIdentifiers: Set<String> = []
    ) {
        self.manifestSHA256 = manifestSHA256
        self.manifestBaseDirectory = manifestBaseDirectory
        self.mappingIssues = mappingIssues
        self.desiredState = desiredState
        self.previousDesiredState = previousDesiredState
        self.observedState = observedState
        self.observationSHA256 = observationSHA256
        self.projectID = projectID
        self.projectResourceUUID = projectResourceUUID
        self.projectGeneration = projectGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.capabilitySHA256 = capabilitySHA256
        self.planFencingToken = planFencingToken
        self.resourceBindings = resourceBindings
        self.unmanagedResourceIdentifiers = unmanagedResourceIdentifiers
    }
}

public struct LifecycleLocalImageRequirement: Equatable, Sendable {
    public let reference: String
    public let operatingSystem: String
    public let architecture: String

    public init(reference: String, operatingSystem: String, architecture: String) {
        self.reference = reference
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }
}

public struct LifecycleCompiledCommand: Equatable, Sendable {
    public let plan: LifecyclePlan
    public let desiredServicesByNodeKey: [String: DesiredRuntimeService]
    public let localImageRequirements: [LifecycleLocalImageRequirement]

    public init(
        plan: LifecyclePlan,
        desiredServicesByNodeKey: [String: DesiredRuntimeService],
        localImageRequirements: [LifecycleLocalImageRequirement]
    ) {
        self.plan = plan
        self.desiredServicesByNodeKey = desiredServicesByNodeKey
        self.localImageRequirements = localImageRequirements
    }
}

public protocol LifecycleCommandDriving: Sendable {
    func prepare(options: LifecycleCLIOptions) throws -> LifecycleCommandPreparation

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult
}

public struct LifecycleCommandRunner: Sendable {
    public let options: LifecycleCLIOptions
    public let driver: any LifecycleCommandDriving
    public let compiler: LifecycleCommandPlanCompiler

    public init(
        options: LifecycleCLIOptions,
        driver: any LifecycleCommandDriving,
        compiler: LifecycleCommandPlanCompiler = LifecycleCommandPlanCompiler()
    ) {
        self.options = options
        self.driver = driver
        self.compiler = compiler
    }

    public func run() -> CLIRunResult {
        do {
            guard options.dryRun != (options.confirmationPlanSHA256 != nil) else {
                throw LifecycleCommandRunnerError.invalidInput(
                    "Lifecycle execution requires exactly one of dry-run or exact plan confirmation."
                )
            }
            let preparation = try driver.prepare(options: options)
            let compiled = try compiler.compile(options: options, preparation: preparation)

            if let provided = options.confirmationPlanSHA256,
               provided != compiled.plan.planSHA256 {
                throw LifecycleCommandRunnerError.confirmationMismatch(
                    expected: compiled.plan.planSHA256,
                    provided: provided
                )
            }

            if options.dryRun {
                try verifyLocalImages(compiled, preparation: preparation)
                return CLIRunResult(
                    standardOutput: try renderPlan(compiled.plan, output: options.output)
                )
            }

            try driver.revalidate(compiled: compiled, preparation: preparation)
            try verifyLocalImages(compiled, preparation: preparation)
            let result = try driver.execute(
                compiled: compiled,
                preparation: preparation,
                options: options
            )
            return renderExecution(result, plan: compiled.plan)
        } catch let error as LifecycleCommandRunnerError {
            return failure(error.diagnostic)
        } catch let diagnostic as HostwrightDiagnostic {
            return failure(diagnostic)
        } catch let error as RuntimeProviderSelectionError {
            return failure(
                HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message: "Runtime provider selection failed: \(error). \(error.guidance) No mutation was attempted."
                )
            )
        } catch let error as RuntimeAdapterError {
            return failure(
                HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message: "\(RuntimeRedactionPolicy.default.redact(String(describing: error))). No mutation was attempted."
                )
            )
        } catch let error as StateStoreError {
            return failure(
                HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message: "\(RuntimeRedactionPolicy.default.redact(String(describing: error))). No runtime mutation was attempted."
                )
            )
        } catch {
            return failure(
                HostwrightDiagnostic(
                    code: .partialFailure,
                    message: RuntimeRedactionPolicy.default.redact(String(describing: error))
                )
            )
        }
    }

    private func verifyLocalImages(
        _ compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        for requirement in compiled.localImageRequirements {
            let evidence: RuntimeLocalImageEvidence
            do {
                evidence = try driver.localImageEvidence(
                    for: requirement,
                    preparation: preparation
                )
            } catch {
                throw LifecycleCommandRunnerError.missingLocalImage(requirement.reference)
            }
            guard evidence.reference == requirement.reference,
                  evidence.descriptorDigest.range(
                    of: "^sha256:[a-f0-9]{64}$",
                    options: .regularExpression
                  ) != nil,
                  evidence.variantDigest.range(
                    of: "^sha256:[a-f0-9]{64}$",
                    options: .regularExpression
                  ) != nil,
                  evidence.operatingSystem == requirement.operatingSystem,
                  evidence.architecture == requirement.architecture else {
                throw LifecycleCommandRunnerError.invalidLocalImageEvidence(
                    requirement.reference
                )
            }
        }
    }

    private func renderPlan(
        _ plan: LifecyclePlan,
        output: CLIOutputFormat
    ) throws -> String {
        if output == .json {
            return try plan.canonicalJSON() + "\n"
        }
        var lines = [
            "Lifecycle plan \(plan.planSHA256)",
            "Command: \(plan.command.rawValue)",
            "Project: \(plan.projectName)",
            "Provider: \(plan.providerID.rawValue) generation \(plan.providerGeneration)",
            "Nodes: \(plan.nodes.count)"
        ]
        if !plan.availabilityImpacts.isEmpty {
            lines.append("Update availability impacts:")
            for impact in plan.availabilityImpacts {
                lines.append(
                    "- service=\(impact.serviceName) mode=\(impact.mode.rawValue) " +
                        "reason=\(impact.modeReason.rawValue) " +
                        "desiredReplicas=\(impact.desiredReplicas) " +
                        "minimumAvailable=\(impact.minimumAvailable) " +
                        "maximumTemporaryCapacity=\(impact.maximumTemporaryCapacity) " +
                        "requiresDowntime=\(impact.requiresDowntime) " +
                        "summary=\(impact.summary)"
                )
            }
        }
        for node in plan.nodes {
            lines.append(
                "- \(node.key): \(node.action.rawValue) \(node.resourceIdentifier ?? node.resourceUUID)"
            )
        }
        lines.append("Confirm with --confirm-plan \(plan.planSHA256)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderExecution(
        _ result: LifecycleSagaExecutionResult,
        plan: LifecyclePlan
    ) -> CLIRunResult {
        let succeeded = result.status == .succeeded || result.status == .alreadySucceeded
        let exitCode = succeeded ? CLIExitCode.success : CLIExitCode.partialFailure
        let completedNodeKeys = Set(result.completedNodeKeys)
        let orderedCompletedNodeKeys = plan.nodes
            .filter { completedNodeKeys.contains($0.key) }
            .map(\.key)
        if options.output == .json {
            let resourceOutcomes = plan.nodes.map { node -> [String: Any] in
                let identity = resourceOutcomeIdentity(for: node, project: plan.projectName)
                var outcome: [String: Any] = [
                    "action": node.action.rawValue,
                    "node": node.key,
                    "outcome": resourceOutcome(
                        for: node,
                        completedNodeKeys: completedNodeKeys,
                        executionStatus: result.status
                    ),
                    "project": plan.projectName,
                    "resourceUUID": node.resourceUUID
                ]
                if let service = identity.service {
                    outcome["service"] = service
                }
                if let replica = identity.replica {
                    outcome["replica"] = replica
                }
                if let resourceIdentifier = node.resourceIdentifier {
                    outcome["resourceIdentifier"] = resourceIdentifier
                }
                return outcome
            }
            let output = CLIJSON.render([
                "kind": "lifecycle-result",
                "status": result.status.rawValue,
                "operationID": result.operationID,
                "groupID": result.groupID,
                "planSHA256": result.planSHA256,
                "checkpoint": result.checkpoint,
                "completedNodeKeys": orderedCompletedNodeKeys,
                "nodeCount": plan.nodes.count,
                "resourceOutcomes": resourceOutcomes,
                "recoveryHint": result.recoveryHintRedacted
            ])
            return CLIRunResult(
                standardOutput: succeeded ? output : "",
                standardError: succeeded ? "" : output,
                exitCode: exitCode.rawValue
            )
        }
        var lines = [
            "Lifecycle \(result.status.rawValue): plan=\(result.planSHA256) completed=\(orderedCompletedNodeKeys.count)/\(plan.nodes.count) checkpoint=\(result.checkpoint)",
            "Resource outcomes:"
        ]
        for node in plan.nodes {
            let identity = resourceOutcomeIdentity(for: node, project: plan.projectName)
            var fields = [
                "outcome=\(resourceOutcome(for: node, completedNodeKeys: completedNodeKeys, executionStatus: result.status))",
                "project=\(plan.projectName)"
            ]
            if let service = identity.service {
                fields.append("service=\(service)")
            }
            if let replica = identity.replica {
                fields.append("replica=\(replica)")
            }
            fields.append("resourceUUID=\(node.resourceUUID)")
            fields.append("node=\(node.key)")
            fields.append("action=\(node.action.rawValue)")
            if let resourceIdentifier = node.resourceIdentifier {
                fields.append("resourceIdentifier=\(resourceIdentifier)")
            }
            lines.append("- " + fields.joined(separator: " "))
        }
        if !result.recoveryHintRedacted.isEmpty {
            lines.append(result.recoveryHintRedacted)
        }
        let detail = lines.joined(separator: "\n")
        return CLIRunResult(
            standardOutput: succeeded ? detail + "\n" : "",
            standardError: succeeded ? "" : detail + "\n",
            exitCode: exitCode.rawValue
        )
    }

    private func resourceOutcome(
        for node: LifecyclePlanNode,
        completedNodeKeys: Set<String>,
        executionStatus: LifecycleSagaExecutionStatus
    ) -> String {
        if completedNodeKeys.contains(node.key) {
            return "completed"
        }
        return executionStatus == .safeHold ? "safe-hold" : "remaining"
    }

    private func resourceOutcomeIdentity(
        for node: LifecyclePlanNode,
        project: String
    ) -> (service: String?, replica: Int?) {
        if let desired = try? LifecycleRevisionCodec.decodeRedactedDesiredJSON(
            node.desiredSpecificationJSONRedacted
        ) {
            return (desired.logicalServiceName, desired.replicaIndex)
        }
        guard let serviceName = node.serviceName else {
            return (nil, nil)
        }
        let components = serviceName.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1, components[0] == Substring(project) else {
            return (serviceName, nil)
        }
        let replica: Int?
        if components.count > 2, components[2].hasPrefix("replica-") {
            replica = Int(components[2].dropFirst("replica-".count))
        } else {
            replica = nil
        }
        return (String(components[1]), replica)
    }

    private func failure(_ diagnostic: HostwrightDiagnostic) -> CLIRunResult {
        let exit = CLIExitCode.mapped(from: diagnostic.code)
        if options.output == .json {
            return CLIRunResult(
                standardError: CLIJSON.error(
                    code: diagnostic.code,
                    message: diagnostic.message,
                    exitCode: exit
                ),
                exitCode: exit.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(diagnostic.code.rawValue): \(diagnostic.message)\n",
            exitCode: exit.rawValue
        )
    }
}

public struct LifecycleCommandPlanCompiler: Sendable {
    public init() {}

    public func compile(
        options: LifecycleCLIOptions,
        preparation: LifecycleCommandPreparation
    ) throws -> LifecycleCompiledCommand {
        try validate(preparation)
        let blockingIssues = preparation.mappingIssues
            .filter { $0.severity == .blocker || $0.severity == .error }
            .map(\.message)
            .sorted()
        guard blockingIssues.isEmpty else {
            throw LifecycleCommandRunnerError.mappingBlocked(blockingIssues)
        }

        let normalizedDesired = try normalizeMounts(
            in: preparation.desiredState,
            baseDirectory: preparation.manifestBaseDirectory
        )
        let normalizedPrevious = try preparation.previousDesiredState.map {
            try normalizeMounts(in: $0, baseDirectory: preparation.manifestBaseDirectory)
        }
        let desiredWithOwnership = try addOwnershipHints(
            to: normalizedDesired,
            bindings: preparation.resourceBindings,
            preparation: preparation
        )
        let previousWithOwnership = try normalizedPrevious.map {
            try addOwnershipHints(
                to: $0,
                bindings: preparation.resourceBindings,
                preparation: preparation
            )
        }
        let serviceNames = try selectedServiceNames(
            requested: options.serviceNames,
            command: options.command,
            desired: desiredWithOwnership
        )
        let desired = filter(desiredWithOwnership, serviceNames: serviceNames)
        let previous = previousWithOwnership.map {
            filter($0, serviceNames: serviceNames)
        }

        if options.command == .update {
            guard let previous else {
                throw LifecycleCommandRunnerError.invalidInput(
                    "Update requires one previously verified healthy desired revision. No mutation was attempted."
                )
            }
            return try compileUpdate(
                previous: previous,
                desired: desired,
                options: options,
                preparation: preparation
            )
        }

        let drafts: [MultiServiceLifecycleNodeDraft]
        switch options.command {
        case .up:
            do {
                drafts = try reconcile(
                    mode: .up,
                    desired: desired,
                    previous: previous,
                    preparation: preparation,
                    parallelism: options.parallelism
                )
            } catch MultiServiceReconciliationError
                .desiredSpecificationDriftRequiresUpdate(_) {
                guard let previous else {
                    throw LifecycleCommandRunnerError.invalidInput(
                        "Desired drift requires a previously verified healthy revision. No mutation was attempted."
                    )
                }
                return try compileUpdate(
                    previous: previous,
                    desired: desired,
                    options: options,
                    preparation: preparation
                )
            }
        case .down, .stop:
            drafts = try reconcile(
                mode: .down,
                desired: desired,
                previous: previous,
                preparation: preparation,
                parallelism: options.parallelism
            )
        case .rm:
            drafts = try reconcile(
                mode: .remove,
                desired: desired,
                previous: previous,
                preparation: preparation,
                parallelism: options.parallelism
            )
        case .start:
            let planned = try reconcile(
                mode: .up,
                desired: desired,
                previous: previous,
                preparation: preparation,
                parallelism: options.parallelism
            )
            if let missing = planned.first(where: { $0.action == .create }) {
                throw LifecycleCommandRunnerError.missingManagedResource(
                    missing.identity.displayName
                )
            }
            drafts = planned
        case .restart:
            drafts = try restartDrafts(
                desired: desired,
                observed: preparation.observedState,
                bindings: preparation.resourceBindings
            )
        case .run:
            drafts = try runDrafts(
                desired: desired,
                preparation: preparation
            )
        case .update:
            throw LifecycleCommandRunnerError.invalidInput(
                "Update command dispatch reached an invalid compiler state."
            )
        }

        let compiled = try compileNodes(
            drafts: drafts,
            options: options,
            preparation: preparation
        )
        return LifecycleCompiledCommand(
            plan: try LifecyclePlan(
                command: lifecycleCommand(options.command),
                projectID: preparation.projectID,
                projectName: desired.projectName,
                projectResourceUUID: preparation.projectResourceUUID,
                projectGeneration: preparation.projectGeneration,
                providerID: preparation.providerID,
                providerGeneration: preparation.providerGeneration,
                manifestSHA256: preparation.manifestSHA256,
                observationSHA256: preparation.observationSHA256,
                capabilitySHA256: preparation.capabilitySHA256,
                parallelism: options.parallelism,
                nodes: compiled.nodes
            ),
            desiredServicesByNodeKey: compiled.desiredByNode,
            localImageRequirements: compiled.imageRequirements
        )
    }

    private func compileUpdate(
        previous: DesiredRuntimeState,
        desired: DesiredRuntimeState,
        options: LifecycleCLIOptions,
        preparation: LifecycleCommandPreparation
    ) throws -> LifecycleCompiledCommand {
        let bindings = Dictionary(
            preparation.resourceBindings.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resources: [RuntimeServiceIdentity: LifecycleUpdateResourceIdentity] = [:]
        for service in desired.services.sorted(by: {
            $0.identity.displayName < $1.identity.displayName
        }) {
            guard let binding = bindings[service.identity] else {
                throw LifecycleCommandRunnerError.missingManagedResource(
                    service.identity.displayName
                )
            }
            let revisionSHA256 = try LifecycleRevisionCodec.revisionSHA256(for: service)
            let candidateGeneration = binding.resourceGeneration + 1
            let candidateNameIdentity = RuntimeServiceIdentity(
                projectName: service.identity.projectName,
                serviceName: service.identity.serviceName,
                instanceName:
                    "candidate-g\(candidateGeneration)-\(String(revisionSHA256.prefix(12)))"
            )
            let candidateIdentifier = candidateNameIdentity.managedResourceIdentifier
            let candidateUUID = HostwrightResourceUUID.legacy(
                kind: "service-revision",
                identifier:
                    "\(binding.resourceUUID):\(candidateGeneration):\(revisionSHA256)"
            )
            resources[service.identity] = LifecycleUpdateResourceIdentity(
                identity: service.identity,
                currentResourceIdentifier: binding.resourceIdentifier,
                currentResourceUUID: binding.resourceUUID,
                currentGeneration: binding.resourceGeneration,
                candidateResourceIdentifier: candidateIdentifier,
                candidateResourceUUID: candidateUUID,
                candidateGeneration: candidateGeneration
            )
        }

        let update = try LifecycleUpdatePlanner().plan(
            previous: previous,
            desired: desired,
            resources: resources,
            fencingToken: preparation.planFencingToken
        )
        var desiredByNode: [String: DesiredRuntimeService] = [:]
        var images = Set<LifecycleImageRequirementKey>()
        let desiredByResourceIdentifier = Dictionary(
            uniqueKeysWithValues: resources.compactMap { identity, resource in
                desired.services.first(where: { $0.identity == identity }).map {
                    (resource.candidateResourceIdentifier, $0)
                }
            }
        )
        let previousByResourceIdentifier = Dictionary(
            uniqueKeysWithValues: resources.compactMap { identity, resource in
                previous.services.first(where: { $0.identity == identity }).map {
                    (resource.currentResourceIdentifier, $0)
                }
            }
        )
        for node in update.nodes {
            guard let resourceIdentifier = node.resourceIdentifier else { continue }
            let selected = desiredByResourceIdentifier[resourceIdentifier] ??
                previousByResourceIdentifier[resourceIdentifier]
            if let selected {
                desiredByNode[node.key] = selected
                if node.action == .create {
                    images.insert(
                        LifecycleImageRequirementKey(
                            reference: selected.image,
                            operatingSystem: selected.platformOperatingSystem,
                            architecture: selected.platformArchitecture
                        )
                    )
                }
            }
        }
        let plan = try LifecyclePlan(
            command: lifecycleCommand(options.command),
            projectID: preparation.projectID,
            projectName: desired.projectName,
            projectResourceUUID: preparation.projectResourceUUID,
            projectGeneration: preparation.projectGeneration,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            manifestSHA256: preparation.manifestSHA256,
            observationSHA256: preparation.observationSHA256,
            capabilitySHA256: preparation.capabilitySHA256,
            parallelism: options.parallelism,
            availabilityImpacts: update.servicePlans
                .filter { $0.mode == .recreate }
                .map {
                    LifecyclePlanAvailabilityImpact(
                        serviceName: $0.serviceName,
                        mode: $0.mode,
                        modeReason: $0.modeReason,
                        impact: $0.availabilityImpact
                    )
                },
            nodes: update.nodes
        )
        return LifecycleCompiledCommand(
            plan: plan,
            desiredServicesByNodeKey: desiredByNode,
            localImageRequirements: images.sorted().map {
                LifecycleLocalImageRequirement(
                    reference: $0.reference,
                    operatingSystem: $0.operatingSystem,
                    architecture: $0.architecture
                )
            }
        )
    }

    private func validate(_ preparation: LifecycleCommandPreparation) throws {
        let digests = [
            preparation.manifestSHA256,
            preparation.observationSHA256,
            preparation.capabilitySHA256
        ]
        guard let metadata = preparation.observedState.adapterMetadata,
              digests.allSatisfy({
            $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        }),
        !preparation.projectID.isEmpty,
        !preparation.desiredState.projectName.isEmpty,
        preparation.desiredState.projectName == preparation.observedState.projectName,
        HostwrightResourceUUID.isValid(preparation.projectResourceUUID),
        HostwrightResourceUUID.isValid(preparation.planFencingToken),
        preparation.projectGeneration > 0,
        preparation.providerGeneration > 0,
        RuntimeProviderID.knownValues.contains(preparation.providerID),
        metadata.providerID == preparation.providerID,
        RuntimeProviderCompatibility.mutationIncompatibility(metadata) == nil,
        preparation.observedState.capabilitySHA256 == preparation.capabilitySHA256 else {
            throw LifecycleCommandRunnerError.invalidInput(
                "Lifecycle preparation contains invalid or stale project, provider, observation, capability, generation, or digest evidence."
            )
        }
    }

    private func reconcile(
        mode: MultiServiceReconciliationMode,
        desired: DesiredRuntimeState,
        previous: DesiredRuntimeState?,
        preparation: LifecycleCommandPreparation,
        parallelism: Int
    ) throws -> [MultiServiceLifecycleNodeDraft] {
        try MultiServiceReconciliationPlanner(parallelism: parallelism).plan(
            desired: desired,
            observed: preparation.observedState,
            previousDesired: previous,
            mode: mode,
            unmanagedResourceIdentifiers: preparation.unmanagedResourceIdentifiers
        ).nodes
    }

    private func selectedServiceNames(
        requested: [String],
        command: LifecycleCommandKind,
        desired: DesiredRuntimeState
    ) throws -> Set<String> {
        let declared = Set(desired.services.map(\.logicalServiceName))
        if requested.isEmpty {
            return declared
        }
        for service in requested where !declared.contains(service) {
            throw LifecycleCommandRunnerError.unknownService(service)
        }
        let dependencies = Dictionary(
            grouping: desired.services,
            by: \.logicalServiceName
        ).mapValues { services in
            Set(services.flatMap(\.dependencies).map(\.serviceName))
        }
        var selected = Set(requested)
        switch command {
        case .up, .start:
            var changed = true
            while changed {
                changed = false
                for service in selected {
                    for dependency in dependencies[service] ?? [] where selected.insert(dependency).inserted {
                        changed = true
                    }
                }
            }
        case .down, .stop, .rm:
            var changed = true
            while changed {
                changed = false
                for (candidate, candidateDependencies) in dependencies
                    where !selected.contains(candidate) &&
                    !candidateDependencies.isDisjoint(with: selected) {
                    selected.insert(candidate)
                    changed = true
                }
            }
        case .restart, .run, .update:
            break
        }
        return selected
    }

    private func filter(
        _ state: DesiredRuntimeState,
        serviceNames: Set<String>
    ) -> DesiredRuntimeState {
        let services = state.services.filter {
            serviceNames.contains($0.logicalServiceName)
        }
        let identities = Set(services.map(\.identity))
        return DesiredRuntimeState(
            projectName: state.projectName,
            services: services,
            ownedResourceHints: state.ownedResourceHints.filter {
                identities.contains($0.identity)
            }
        )
    }

    private func addOwnershipHints(
        to state: DesiredRuntimeState,
        bindings: [LifecycleResourceBinding],
        preparation: LifecycleCommandPreparation
    ) throws -> DesiredRuntimeState {
        var seenResources = Set<String>()
        var seenIdentities = Set<RuntimeServiceIdentity>()
        var hints = state.ownedResourceHints
        for binding in bindings.sorted(by: {
            $0.resourceIdentifier < $1.resourceIdentifier
        }) {
            guard seenResources.insert(binding.resourceIdentifier).inserted,
                  seenIdentities.insert(binding.identity).inserted,
                  binding.projectResourceUUID == preparation.projectResourceUUID.lowercased(),
                  binding.projectGeneration == preparation.projectGeneration,
                  binding.providerID == preparation.providerID,
                  binding.providerGeneration == preparation.providerGeneration else {
                throw LifecycleCommandRunnerError.ambiguousOwnership(
                    binding.resourceIdentifier
                )
            }
            hints.append(
                RuntimeOwnedResourceHint(
                    resourceIdentifier: binding.resourceIdentifier,
                    identity: binding.identity,
                    identityVersion: binding.identityVersion,
                    ownership: binding.ownershipEvidence
                )
            )
        }
        return DesiredRuntimeState(
            projectName: state.projectName,
            services: state.services,
            ownedResourceHints: Dictionary(
                hints.map { ("\($0.identity.displayName)|\($0.resourceIdentifier)", $0) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.resourceIdentifier < $1.resourceIdentifier }
        )
    }

    private func normalizeMounts(
        in state: DesiredRuntimeState,
        baseDirectory: String
    ) throws -> DesiredRuntimeState {
        guard baseDirectory.hasPrefix("/") else {
            throw LifecycleCommandRunnerError.invalidInput(
                "Manifest base directory must be an absolute path."
            )
        }
        let baseURL = URL(fileURLWithPath: baseDirectory, isDirectory: true)
            .standardizedFileURL
        return DesiredRuntimeState(
            projectName: state.projectName,
            services: try state.services.map { service in
                let mounts = try service.mounts.map { mount -> RuntimeMountReference in
                    let source: String
                    if mount.source.hasPrefix("/") {
                        source = URL(fileURLWithPath: mount.source).standardizedFileURL.path
                    } else if mount.source.hasPrefix("./") || mount.source.hasPrefix("../") {
                        source = URL(
                            fileURLWithPath: mount.source,
                            relativeTo: baseURL
                        ).standardizedFileURL.path
                    } else {
                        throw LifecycleCommandRunnerError.unsupportedStorage(mount.source)
                    }
                    guard FileManager.default.fileExists(atPath: source) else {
                        throw LifecycleCommandRunnerError.unsupportedStorage(source)
                    }
                    return RuntimeMountReference(
                        source: source,
                        target: mount.target,
                        access: mount.access == .unknown ? .readWrite : mount.access
                    )
                }
                return copy(service, identity: service.identity, mounts: mounts)
            },
            ownedResourceHints: state.ownedResourceHints
        )
    }

    private func restartDrafts(
        desired: DesiredRuntimeState,
        observed: ObservedRuntimeState,
        bindings: [LifecycleResourceBinding]
    ) throws -> [MultiServiceLifecycleNodeDraft] {
        let observedByIdentity = Dictionary(
            observed.services.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bindingByIdentity = Dictionary(
            bindings.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var drafts: [MultiServiceLifecycleNodeDraft] = []
        for service in desired.services.sorted(by: {
            $0.identity.displayName < $1.identity.displayName
        }) {
            guard let current = observedByIdentity[service.identity],
                  current.lifecycleState != .missing else {
                throw LifecycleCommandRunnerError.missingManagedResource(
                    service.identity.displayName
                )
            }
            guard let binding = bindingByIdentity[service.identity],
                  binding.resourceIdentifier == current.resourceIdentifier else {
                throw LifecycleCommandRunnerError.ambiguousOwnership(
                    current.resourceIdentifier
                )
            }
            let ownershipCondition = LifecyclePlanCondition(
                kind: "resource-owned",
                subject: service.identity.managedResourceIdentifier,
                expectedValue: "true"
            )
            var startDependencies: [String] = []
            switch current.lifecycleState {
            case .running:
                if service.hooks.preStop != nil {
                    let preStopKey =
                        "prestop-\(service.identity.managedResourceIdentifier)"
                    drafts.append(
                        MultiServiceLifecycleNodeDraft(
                            key: preStopKey,
                            action: .runHook,
                            identity: service.identity,
                            resourceIdentifier: current.resourceIdentifier,
                            desiredService: service,
                            preconditions: [ownershipCondition],
                            postconditions: [
                                LifecyclePlanCondition(
                                    kind: "hook-completed",
                                    subject: service.identity.managedResourceIdentifier,
                                    expectedValue: "preStop"
                                )
                            ]
                        )
                    )
                    startDependencies = [preStopKey]
                }
                let stopKey =
                    "stop-\(service.identity.managedResourceIdentifier)"
                drafts.append(
                    MultiServiceLifecycleNodeDraft(
                        key: stopKey,
                        action: .stop,
                        identity: service.identity,
                        resourceIdentifier: current.resourceIdentifier,
                        desiredService: service,
                        dependencies: startDependencies,
                        preconditions: [ownershipCondition],
                        postconditions: [
                            LifecyclePlanCondition(
                                kind: "lifecycle",
                                subject:
                                    service.identity.managedResourceIdentifier,
                                expectedValue:
                                    RuntimeLifecycleState.stopped.rawValue
                            )
                        ]
                    )
                )
                startDependencies = [stopKey]
            case .created, .stopped, .exited:
                break
            case .failed, .unknown, .missing:
                throw LifecycleCommandRunnerError.invalidInput(
                    "Restart refused unsafe state \(current.lifecycleState.rawValue) for \(service.identity.displayName)."
                )
            }
            let startKey =
                "start-\(service.identity.managedResourceIdentifier)"
            drafts.append(
                MultiServiceLifecycleNodeDraft(
                    key: startKey,
                    action: .start,
                    identity: service.identity,
                    resourceIdentifier: current.resourceIdentifier,
                    desiredService: service,
                    dependencies: startDependencies,
                    preconditions: [ownershipCondition],
                    postconditions: [
                        LifecyclePlanCondition(
                            kind: "lifecycle",
                            subject: service.identity.managedResourceIdentifier,
                            expectedValue: RuntimeLifecycleState.running.rawValue
                        )
                    ]
                )
            )
            var probeDependency = startKey
            if service.hooks.postStart != nil {
                let postStartKey =
                    "poststart-\(service.identity.managedResourceIdentifier)"
                drafts.append(
                    MultiServiceLifecycleNodeDraft(
                        key: postStartKey,
                        action: .runHook,
                        identity: service.identity,
                        resourceIdentifier: current.resourceIdentifier,
                        desiredService: service,
                        dependencies: [probeDependency],
                        preconditions: [ownershipCondition],
                        postconditions: [
                            LifecyclePlanCondition(
                                kind: "hook-completed",
                                subject: service.identity.managedResourceIdentifier,
                                expectedValue: "postStart"
                            )
                        ]
                    )
                )
                probeDependency = postStartKey
            }
            let configuredProbes: [
                (kind: RuntimeProbeKind, key: String, expectedValue: String)
            ] = [
                (.startup, "verify-startup", "succeeded"),
                (.readiness, "verify-ready", "ready"),
                (.liveness, "verify-liveness", "healthy")
            ]
            for probe in configuredProbes where service.probes[probe.kind] != nil {
                let probeKey =
                    "\(probe.key)-\(service.identity.managedResourceIdentifier)"
                drafts.append(
                    MultiServiceLifecycleNodeDraft(
                        key: probeKey,
                        action: .verify,
                        identity: service.identity,
                        resourceIdentifier: current.resourceIdentifier,
                        desiredService: service,
                        dependencies: [probeDependency],
                        preconditions: [ownershipCondition],
                        postconditions: [
                            LifecyclePlanCondition(
                                kind: "probe-\(probe.kind.rawValue)",
                                subject: service.identity.managedResourceIdentifier,
                                expectedValue: probe.expectedValue
                            )
                        ]
                    )
                )
                probeDependency = probeKey
            }
        }
        return drafts
    }

    private func runDrafts(
        desired: DesiredRuntimeState,
        preparation: LifecycleCommandPreparation
    ) throws -> [MultiServiceLifecycleNodeDraft] {
        let logicalServiceNames = Set(desired.services.map(\.logicalServiceName))
        guard logicalServiceNames.count == 1,
              let template = desired.services.min(by: {
                  ($0.replicaIndex, $0.identity.displayName) <
                      ($1.replicaIndex, $1.identity.displayName)
              }) else {
            throw LifecycleCommandRunnerError.invalidInput(
                "Run requires exactly one selected logical service."
            )
        }
        let suffix = preparation.planFencingToken
            .replacingOccurrences(of: "-", with: "")
            .prefix(12)
        let identity = RuntimeServiceIdentity(
            projectName: template.identity.projectName,
            serviceName: template.identity.serviceName,
            instanceName: "run-\(suffix)"
        )
        guard !preparation.observedState.services.contains(where: {
            $0.identity == identity || $0.resourceIdentifier == identity.managedResourceIdentifier
        }) else {
            throw LifecycleCommandRunnerError.invalidInput(
                "Ephemeral run identity collides with an existing runtime resource."
            )
        }
        let service = copy(
            template,
            identity: identity,
            dependencies: [],
            mounts: template.mounts
        )
        let createKey = "create-\(identity.managedResourceIdentifier)"
        let startKey = "start-\(identity.managedResourceIdentifier)"
        return [
            MultiServiceLifecycleNodeDraft(
                key: createKey,
                action: .create,
                identity: identity,
                resourceIdentifier: identity.managedResourceIdentifier,
                desiredService: service,
                postconditions: [
                    LifecyclePlanCondition(
                        kind: "resource-present",
                        subject: identity.managedResourceIdentifier,
                        expectedValue: "true"
                    )
                ]
            ),
            MultiServiceLifecycleNodeDraft(
                key: startKey,
                action: .start,
                identity: identity,
                resourceIdentifier: identity.managedResourceIdentifier,
                desiredService: service,
                dependencies: [createKey],
                postconditions: [
                    LifecyclePlanCondition(
                        kind: "lifecycle",
                        subject: identity.managedResourceIdentifier,
                        expectedValue: RuntimeLifecycleState.exited.rawValue
                    )
                ]
            )
        ]
    }

    private func compileNodes(
        drafts: [MultiServiceLifecycleNodeDraft],
        options: LifecycleCLIOptions,
        preparation: LifecycleCommandPreparation
    ) throws -> (
        nodes: [LifecyclePlanNode],
        desiredByNode: [String: DesiredRuntimeService],
        imageRequirements: [LifecycleLocalImageRequirement]
    ) {
        let bindingByIdentity = Dictionary(
            preparation.resourceBindings.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let createIdentities = Set(
            drafts.filter { $0.action == .create }.map(\.identity)
        )
        var desiredByNode: [String: DesiredRuntimeService] = [:]
        var imageRequirements = Set<LifecycleImageRequirementKey>()
        var nodes: [LifecyclePlanNode] = []

        for draft in drafts {
            let existing = bindingByIdentity[draft.identity]
            let needsExistingOwnership = draft.action != .create &&
                !createIdentities.contains(draft.identity)
            if needsExistingOwnership {
                guard let existing,
                      existing.resourceIdentifier == draft.resourceIdentifier else {
                    throw LifecycleCommandRunnerError.ambiguousOwnership(
                        draft.resourceIdentifier
                    )
                }
            }

            let resourceUUID = existing?.resourceUUID ?? HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: "\(preparation.projectID):\(draft.identity.displayName)"
            )
            let resourceGeneration: Int
            if draft.action == .create, let existing {
                resourceGeneration = existing.resourceGeneration + 1
            } else {
                resourceGeneration = existing?.resourceGeneration ?? 1
            }
            let desiredJSON = try desiredSpecificationJSON(draft.desiredService)
            let compensation = compensation(
                for: draft.action,
                hasDesiredService: draft.desiredService != nil,
                timeoutSeconds: options.timeoutSeconds
            )
            let node = try LifecyclePlanNode(
                key: draft.key,
                action: draft.action,
                serviceName: draft.identity.displayName,
                resourceIdentifier: draft.resourceIdentifier,
                resourceUUID: resourceUUID,
                resourceGeneration: resourceGeneration,
                fencingToken: preparation.planFencingToken,
                dependencies: draft.dependencies,
                preconditions: draft.preconditions,
                postconditions: draft.postconditions,
                timeoutSeconds: options.timeoutSeconds,
                compensation: compensation,
                desiredSpecificationJSONRedacted: desiredJSON
            )
            nodes.append(node)
            if let desired = draft.desiredService {
                desiredByNode[draft.key] = desired
                if draft.action == .create {
                    imageRequirements.insert(
                        LifecycleImageRequirementKey(
                            reference: desired.image,
                            operatingSystem: desired.platformOperatingSystem,
                            architecture: desired.platformArchitecture
                        )
                    )
                }
            }
        }
        return (
            nodes,
            desiredByNode,
            imageRequirements.sorted().map {
                LifecycleLocalImageRequirement(
                    reference: $0.reference,
                    operatingSystem: $0.operatingSystem,
                    architecture: $0.architecture
                )
            }
        )
    }

    private func compensation(
        for action: LifecyclePlanAction,
        hasDesiredService: Bool,
        timeoutSeconds: Int
    ) -> LifecycleCompensation? {
        switch action {
        case .create:
            LifecycleCompensation(action: .delete, timeoutSeconds: timeoutSeconds)
        case .start:
            LifecycleCompensation(action: .stop, timeoutSeconds: timeoutSeconds)
        case .stop:
            LifecycleCompensation(action: .start, timeoutSeconds: timeoutSeconds)
        case .restart:
            LifecycleCompensation(action: .restart, timeoutSeconds: timeoutSeconds)
        case .delete:
            hasDesiredService
                ? LifecycleCompensation(action: .create, timeoutSeconds: timeoutSeconds)
                : nil
        default:
            nil
        }
    }

    private func lifecycleCommand(_ command: LifecycleCommandKind) -> LifecycleCommand {
        switch command {
        case .up: .up
        case .down: .down
        case .run: .run
        case .start: .start
        case .stop: .stop
        case .restart: .restart
        case .rm: .remove
        case .update: .update
        }
    }

    private func desiredSpecificationJSON(
        _ service: DesiredRuntimeService?
    ) throws -> String {
        guard let service else {
            return "{}"
        }
        return try LifecycleRevisionCodec.redactedDesiredJSON(for: service)
    }

    private func copy(
        _ service: DesiredRuntimeService,
        identity: RuntimeServiceIdentity,
        dependencies: [RuntimeServiceDependency]? = nil,
        mounts: [RuntimeMountReference]
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity,
            logicalServiceName: service.logicalServiceName,
            replicaIndex: service.replicaIndex,
            image: service.image,
            platformOperatingSystem: service.platformOperatingSystem,
            platformArchitecture: service.platformArchitecture,
            cpuCount: service.cpuCount,
            memoryBytes: service.memoryBytes,
            userID: service.userID,
            groupID: service.groupID,
            workingDirectory: service.workingDirectory,
            entrypoint: service.entrypoint,
            command: service.command,
            initProcess: service.initProcess,
            dependencies: dependencies ?? service.dependencies,
            environment: service.environment,
            labels: service.labels,
            ports: service.ports,
            mounts: mounts,
            healthCheck: service.healthCheck,
            probes: service.probes,
            restartPolicy: service.restartPolicy,
            updatePolicy: service.updatePolicy,
            hooks: service.hooks,
            rosetta: service.rosetta,
            virtualization: service.virtualization,
            readOnlyRootFilesystem: service.readOnlyRootFilesystem,
            sharedMemoryBytes: service.sharedMemoryBytes
        )
    }
}

private struct LifecycleImageRequirementKey: Hashable, Comparable {
    let reference: String
    let operatingSystem: String
    let architecture: String

    static func < (
        lhs: LifecycleImageRequirementKey,
        rhs: LifecycleImageRequirementKey
    ) -> Bool {
        (lhs.reference, lhs.operatingSystem, lhs.architecture) <
            (rhs.reference, rhs.operatingSystem, rhs.architecture)
    }
}
