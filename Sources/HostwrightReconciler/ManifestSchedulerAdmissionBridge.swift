import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightPolicy
import HostwrightScheduler

public enum ManifestSchedulerAdmissionError:
    Error,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    case invalidManifest([String])
    case invalidProfile
    case profileViolation([String])
    case unsupportedRuntimeLimits([String])
    case unsupportedRuntimeClaims([String])
    case unsupportedScheduling([String])
    case invalidIdentity(String)
    case invalidQuantity(String)
    case schedulerContract(String)

    public var stableKey: String {
        switch self {
        case .invalidManifest(let details):
            "invalid-manifest:" + details.joined(separator: ",")
        case .invalidProfile:
            "invalid-profile"
        case .profileViolation(let fields):
            "profile-violation:" + fields.joined(separator: ",")
        case .unsupportedRuntimeLimits(let fields):
            "unsupported-runtime-limits:" + fields.joined(separator: ",")
        case .unsupportedRuntimeClaims(let fields):
            "unsupported-runtime-claims:" + fields.joined(separator: ",")
        case .unsupportedScheduling(let fields):
            "unsupported-scheduling:" + fields.joined(separator: ",")
        case .invalidIdentity(let field):
            "invalid-identity:" + field
        case .invalidQuantity(let field):
            "invalid-quantity:" + field
        case .schedulerContract(let detail):
            "scheduler-contract:" + detail
        }
    }

    public var description: String { stableKey }
}

public struct ManifestRuntimeHardLimits:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let cpuCount: Int?
    public let memoryBytes: Int64?

    public init(cpuCount: Int?, memoryBytes: Int64?) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
    }
}

public enum ManifestRuntimeAdmissionBlocker:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case providerClaimUnsupported = "scheduling.provider"
    case acceleratorClaimsUnsupported = "scheduling.acceleratorClaims"

    public var stableKey: String {
        "runtime-admission-blocker:\(rawValue)"
    }
}

public struct ManifestSchedulerAdmission:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let serviceName: String
    public let replicaIndex: Int
    public let workload: SchedulerWorkload
    public let runtimeHardLimits: ManifestRuntimeHardLimits
    public let runtimeAdmissionBlockers: [ManifestRuntimeAdmissionBlocker]
    public let disruptionBudget: SchedulerDisruptionBudget?

    public init(
        serviceName: String,
        replicaIndex: Int,
        workload: SchedulerWorkload,
        runtimeHardLimits: ManifestRuntimeHardLimits,
        runtimeAdmissionBlockers: [ManifestRuntimeAdmissionBlocker] = [],
        disruptionBudget: SchedulerDisruptionBudget? = nil
    ) {
        self.serviceName = serviceName
        self.replicaIndex = replicaIndex
        self.workload = workload
        self.runtimeHardLimits = runtimeHardLimits
        self.runtimeAdmissionBlockers = Array(Set(runtimeAdmissionBlockers)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.disruptionBudget = disruptionBudget
    }

    public var workloadID: UUID { workload.workloadID }

    public func requireRuntimeAdmission() throws {
        guard runtimeAdmissionBlockers.isEmpty else {
            throw ManifestSchedulerAdmissionError.unsupportedRuntimeClaims(
                runtimeAdmissionBlockers.map(\.rawValue).sorted()
            )
        }
    }
}

public enum ManifestSchedulerAdmissionBridge {
    public static func admit(
        manifest: HostwrightManifest,
        subjectID: String,
        profileResolution: WorkloadProfileResolution? = nil
    ) throws -> [ManifestSchedulerAdmission] {
        let admissions = try map(
            manifest: manifest,
            subjectID: subjectID,
            profileResolution: profileResolution
        )
        for admission in admissions {
            try admission.requireRuntimeAdmission()
        }
        return admissions
    }

    public static func map(
        manifest: HostwrightManifest,
        subjectID: String,
        profileResolution: WorkloadProfileResolution? = nil
    ) throws -> [ManifestSchedulerAdmission] {
        let manifestIssues = ManifestValidator.validate(manifest)
        guard manifestIssues.isEmpty else {
            let details = manifestIssues.map {
                "\($0.path ?? "$"):\($0.message)"
            }.sorted()
            throw ManifestSchedulerAdmissionError.invalidManifest(details)
        }

        guard let projectID = manifest.project, !projectID.isEmpty else {
            throw ManifestSchedulerAdmissionError.invalidIdentity("project")
        }
        guard !subjectID.isEmpty,
              subjectID == subjectID.trimmingCharacters(in: .whitespacesAndNewlines),
              !subjectID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ManifestSchedulerAdmissionError.invalidIdentity("subject")
        }

        return try manifest.services
            .sorted { $0.name < $1.name }
            .flatMap { service in
                try (0..<service.replicas).map { replicaIndex in
                    try map(
                        service: service,
                        projectID: projectID,
                        subjectID: subjectID,
                        replicaIndex: replicaIndex,
                        profileResolution: profileResolution
                    )
                }
            }
    }

    private static func map(
        service: HostwrightService,
        projectID: String,
        subjectID: String,
        replicaIndex: Int,
        profileResolution: WorkloadProfileResolution?
    ) throws -> ManifestSchedulerAdmission {
        let resourceMapping = try mapResources(service.resources)
        try validateProfile(
            request: resourceMapping.request,
            limit: resourceMapping.limit,
            scheduling: service.scheduling,
            resolution: profileResolution
        )

        let policy = service.scheduling ?? HostwrightSchedulingPolicy()
        let topologyMapping = try mapTopology(
            policy.topologySpread,
            projectID: projectID,
            serviceName: service.name,
            preferredAffinity: try mapPreferredSelectors(
                policy.preferredAffinity,
                field: "scheduling.preferredAffinity"
            ),
            preferredAntiAffinity: try mapPreferredSelectors(
                policy.preferredAntiAffinity,
                field: "scheduling.preferredAntiAffinity"
            )
        )
        let affinity = try mapAffinity(
            policy,
            topologySpreads: topologyMapping.hardSpreads
        )
        let tolerations = try mapTolerations(policy.tolerations)

        let disruptionBudget = try mapDisruptionBudget(
            policy.disruption,
            replicas: service.replicas,
            projectID: projectID,
            serviceName: service.name
        )

        let identity = "\(projectID)/\(service.name)" +
            (replicaIndex == 0 ? "" : "/replica-\(replicaIndex)")
        guard let workloadID = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "scheduler-workload",
                identifier: identity
            )
        ) else {
            throw ManifestSchedulerAdmissionError.invalidIdentity("workload")
        }

        let requirements: WorkloadPlacementRequirements
        do {
            requirements = try WorkloadPlacementRequirements(
                workloadID: workloadID,
                resources: WorkloadResourceSnapshot(
                    request: resourceMapping.request,
                    limit: resourceMapping.limit
                ),
                requiredArchitectures: [service.platform.architecture.rawValue],
                requiredProvider: policy.provider,
                affinity: affinity,
                tolerations: tolerations,
                acceleratorRequirements: try mapAcceleratorRequirements(
                    policy.acceleratorClaims
                )
            )
        } catch let error as ManifestSchedulerAdmissionError {
            throw error
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }

        let workload: SchedulerWorkload
        do {
            workload = try SchedulerWorkload(
                requirements: requirements,
                priority: Int64(policy.priority),
                subjectID: subjectID,
                projectID: projectID,
                topology: topologyMapping.preference,
                preemptionEligibility: policy.preemption == .lowerPriority
                    ? .eligible
                    : .nonPreempting
            )
        } catch let error as SchedulerEngineValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }

        return ManifestSchedulerAdmission(
            serviceName: service.name,
            replicaIndex: replicaIndex,
            workload: workload,
            runtimeHardLimits: ManifestRuntimeHardLimits(
                cpuCount: service.resources?.limits?.cpus,
                memoryBytes: resourceMapping.limit?["memory"]
            ),
            runtimeAdmissionBlockers: runtimeAdmissionBlockers(for: policy),
            disruptionBudget: disruptionBudget
        )
    }

    private static func validateProfile(
        request: ResourceVector,
        limit: ResourceVector?,
        scheduling: HostwrightSchedulingPolicy?,
        resolution: WorkloadProfileResolution?
    ) throws {
        guard let resolution else { return }
        do {
            try resolution.profile.validate()
        } catch {
            throw ManifestSchedulerAdmissionError.invalidProfile
        }

        let profile = resolution.profile
        var violations: [String] = []
        let claimedCPU = limit?["cpu"] ?? request["cpu"]
        if let ceiling = profile.resources?.cpu, claimedCPU > Int64(ceiling) {
            violations.append("resources.cpu")
        }
        if let ceiling = profile.resources?.memoryMiB {
            guard let ceilingValue = Int64(exactly: ceiling) else {
                throw ManifestSchedulerAdmissionError.invalidProfile
            }
            let (ceilingBytes, overflow) = ceilingValue.multipliedReportingOverflow(
                by: 1_048_576
            )
            guard !overflow else {
                throw ManifestSchedulerAdmissionError.invalidProfile
            }
            if (limit?["memory"] ?? request["memory"]) > ceilingBytes {
                violations.append("resources.memoryMiB")
            }
        }
        let claimedProcess = limit?["process"] ?? request["process"]
        if let ceiling = profile.resources?.processCount,
           claimedProcess > Int64(ceiling) {
            violations.append("resources.processCount")
        }

        if let provider = scheduling?.provider {
            let allowed = Set(profile.runtime.allowedProviders)
            if !allowed.isEmpty && !allowed.contains("default") && !allowed.contains(provider) {
                violations.append("runtime.allowedProviders")
            }
        }
        let allowedAccelerators = Set(profile.accelerators.allowed)
        if let claims = scheduling?.acceleratorClaims {
            for claim in claims where !allowedAccelerators.contains(claim.name) {
                violations.append("accelerators.allowed")
                break
            }
        }
        guard violations.isEmpty else {
            throw ManifestSchedulerAdmissionError.profileViolation(
                Array(Set(violations)).sorted()
            )
        }
    }

    private static func runtimeAdmissionBlockers(
        for policy: HostwrightSchedulingPolicy
    ) -> [ManifestRuntimeAdmissionBlocker] {
        var blockers: [ManifestRuntimeAdmissionBlocker] = []
        if policy.provider != nil {
            blockers.append(.providerClaimUnsupported)
        }
        if !policy.acceleratorClaims.isEmpty {
            blockers.append(.acceleratorClaimsUnsupported)
        }
        return blockers
    }

    private static func mapDisruptionBudget(
        _ disruption: HostwrightDisruptionPolicy?,
        replicas: Int,
        projectID: String,
        serviceName: String
    ) throws -> SchedulerDisruptionBudget? {
        guard let disruption, !disruption.isEmpty else { return nil }
        guard replicas > 0 else {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling(
                ["scheduling.disruption.replicas"]
            )
        }
        let remainingVictimCount: Int
        switch (disruption.maxUnavailable, disruption.minAvailable) {
        case let (maxUnavailable?, nil):
            guard (0...replicas).contains(maxUnavailable) else {
                throw ManifestSchedulerAdmissionError.unsupportedScheduling(
                    ["scheduling.disruption.maxUnavailable"]
                )
            }
            remainingVictimCount = maxUnavailable
        case let (nil, minAvailable?):
            guard (0...replicas).contains(minAvailable) else {
                throw ManifestSchedulerAdmissionError.unsupportedScheduling(
                    ["scheduling.disruption.minAvailable"]
                )
            }
            remainingVictimCount = replicas - minAvailable
        case (.none, .none):
            return nil
        case (.some, .some):
            throw ManifestSchedulerAdmissionError.unsupportedScheduling(
                ["scheduling.disruption.maxUnavailable", "scheduling.disruption.minAvailable"]
            )
        }

        let defaultCost = SchedulerDisruptionProfile.default.movementCostBasisPoints
        let (remainingCost, overflow) = Int64(remainingVictimCount)
            .multipliedReportingOverflow(by: defaultCost)
        guard !overflow else {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling(
                ["scheduling.disruption.cost"]
            )
        }
        do {
            return try SchedulerDisruptionBudget(
                budgetID: "\(projectID)/\(serviceName)",
                projectID: projectID,
                remainingVictimCount: remainingVictimCount,
                remainingDisruptionCostBasisPoints: remainingCost
            )
        } catch let error as SchedulerEngineValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }

    private static func mapResources(
        _ resources: HostwrightResources?
    ) throws -> (request: ResourceVector, limit: ResourceVector?) {
        guard let resources else {
            throw ManifestSchedulerAdmissionError.invalidQuantity("resources")
        }

        let request = try vector(resources.requests, fieldPrefix: "resources.requests")
        let limit = try resources.limits.map {
            try vector($0, fieldPrefix: "resources.limits")
        }
        if let limit {
            let unsupported = [
                ("disk", limit["disk"] > 0),
                ("io", limit["io"] > 0),
                ("network", limit["network"] > 0),
                ("process", limit["process"] > 0)
            ].compactMap { field, declared in
                declared ? "resources.limits.\(field)" : nil
            }
            guard unsupported.isEmpty else {
                throw ManifestSchedulerAdmissionError.unsupportedRuntimeLimits(
                    unsupported
                )
            }
        }

        return (request, limit)
    }

    private static func vector(
        _ values: HostwrightResourceSet,
        fieldPrefix: String
    ) throws -> ResourceVector {
        var mapped: [String: Int64] = [:]
        if let cpus = values.cpus {
            guard let value = Int64(exactly: cpus), value > 0 else {
                throw ManifestSchedulerAdmissionError.invalidQuantity(
                    "\(fieldPrefix).cpus"
                )
            }
            mapped["cpu"] = value
        }
        if let memory = values.memory {
            mapped["memory"] = try quantity(
                memory,
                field: "\(fieldPrefix).memory",
                suffixes: [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824),
                           ("MiB", 1_048_576), ("KiB", 1_024), ("B", 1)]
            )
        }
        if let disk = values.disk {
            mapped["disk"] = try quantity(
                disk,
                field: "\(fieldPrefix).disk",
                suffixes: [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824),
                           ("MiB", 1_048_576), ("KiB", 1_024), ("B", 1)]
            )
        }
        if let io = values.io {
            mapped["io"] = try quantity(
                io,
                field: "\(fieldPrefix).io",
                suffixes: [("GiBps", 1_073_741_824), ("MiBps", 1_048_576),
                           ("KiBps", 1_024), ("Bps", 1)]
            )
        }
        if let network = values.network {
            mapped["network"] = try quantity(
                network,
                field: "\(fieldPrefix).network",
                suffixes: [("Gbps", 1_000_000_000), ("Mbps", 1_000_000),
                           ("Kbps", 1_000), ("bps", 1)]
            )
        }
        if let process = values.process {
            guard let value = Int64(exactly: process), value > 0 else {
                throw ManifestSchedulerAdmissionError.invalidQuantity(
                    "\(fieldPrefix).process"
                )
            }
            mapped["process"] = value
        }
        do {
            return try ResourceVector(mapped)
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }

    private static func quantity(
        _ value: String,
        field: String,
        suffixes: [(String, UInt64)]
    ) throws -> Int64 {
        guard let (suffix, multiplier) = suffixes.first(where: { value.hasSuffix($0.0) }) else {
            throw ManifestSchedulerAdmissionError.invalidQuantity(field)
        }
        let digits = String(value.dropLast(suffix.count))
        guard let number = UInt64(digits), number > 0, String(number) == digits else {
            throw ManifestSchedulerAdmissionError.invalidQuantity(field)
        }
        let (product, overflow) = number.multipliedReportingOverflow(by: multiplier)
        guard !overflow, product <= UInt64(Int64.max) else {
            throw ManifestSchedulerAdmissionError.invalidQuantity(field)
        }
        return Int64(product)
    }

    private static func mapAffinity(
        _ policy: HostwrightSchedulingPolicy,
        topologySpreads: [SchedulerHardTopologySpread]
    ) throws -> NodeAffinity {
        do {
            return try NodeAffinity(
                requiredSelectors: try policy.requiredAffinity.map {
                    try mapSelector($0, field: "scheduling.requiredAffinity")
                },
                forbiddenSelectors: try policy.requiredAntiAffinity.map {
                    try mapSelector($0, field: "scheduling.requiredAntiAffinity")
                },
                topologySpreads: topologySpreads
            )
        } catch let error as ManifestSchedulerAdmissionError {
            throw error
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }

    private static func mapSelector(
        _ selector: HostwrightSchedulingSelector,
        field: String
    ) throws -> SchedulerLabelSelector {
        guard let schedulerOperator = SchedulerLabelSelectorOperator(
            rawValue: selector.operator.rawValue
        ) else {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling([
                "\(field).\(selector.key):\(selector.operator.rawValue)"
            ])
        }
        do {
            return try SchedulerLabelSelector(
                key: selector.key,
                operator: schedulerOperator,
                values: selector.values
            )
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling([
                "\(field).\(selector.key):\(selector.operator.rawValue):\(error.stableKey)"
            ])
        } catch {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling([
                "\(field).\(selector.key):\(selector.operator.rawValue)"
            ])
        }
    }

    private static func mapTolerations(
        _ values: [HostwrightSchedulingToleration]
    ) throws -> [PlacementToleration] {
        do {
            return try values.map { value in
                try PlacementToleration(
                    key: value.key,
                    value: value.value,
                    effect: value.effect.map {
                        $0 == .noSchedule ? .noSchedule : .noExecute
                    },
                    matching: value.operator == .equals ? .equals : .exists
                )
            }
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }

    private static func mapTopology(
        _ spreads: [HostwrightTopologySpread],
        projectID: String,
        serviceName: String,
        preferredAffinity: [SchedulerWeightedLabelSelectorPreference],
        preferredAntiAffinity: [SchedulerWeightedLabelSelectorPreference]
    ) throws -> (
        preference: SchedulerTopologyPreference,
        hardSpreads: [SchedulerHardTopologySpread]
    ) {
        let groupID = "\(projectID)/\(serviceName)"
        let mapped: [SchedulerHardTopologySpread]
        do {
            mapped = try spreads.map { spread in
                try SchedulerHardTopologySpread(
                    topologyKey: spread.topologyKey,
                    maxSkew: spread.maxSkew,
                    whenUnsatisfiable: spread.whenUnsatisfiable == .doNotSchedule
                        ? .doNotSchedule
                        : .scheduleAnyway,
                    groupID: groupID
                )
            }.sorted { $0.orderingKey < $1.orderingKey }
        } catch let error as SchedulerEngineValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }

        guard let spread = mapped.first else {
            do {
                return (
                    try SchedulerTopologyPreference(
                        preferredAffinity: preferredAffinity,
                        preferredAntiAffinity: preferredAntiAffinity
                    ),
                    mapped
                )
            } catch let error as SchedulerEngineValidationError {
                throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
            } catch {
                throw ManifestSchedulerAdmissionError.schedulerContract(
                    String(describing: error)
                )
            }
        }
        do {
            return (
                try SchedulerTopologyPreference(
                    groupID: groupID,
                    spreadKey: spread.topologyKey,
                    preferredAffinity: preferredAffinity,
                    preferredAntiAffinity: preferredAntiAffinity
                ),
                mapped
            )
        } catch let error as SchedulerEngineValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }

    private static func mapPreferredSelectors(
        _ preferences: [HostwrightSchedulingPreference],
        field: String
    ) throws -> [SchedulerWeightedLabelSelectorPreference] {
        do {
            return try preferences.map { preference in
                let selector = try mapSelector(preference.match, field: field)
                guard let weight = Int64(exactly: preference.weight) else {
                    throw ManifestSchedulerAdmissionError.unsupportedScheduling([
                        "\(field).weight"
                    ])
                }
                return try SchedulerWeightedLabelSelectorPreference(
                    weight: weight,
                    selector: selector
                )
            }
        } catch let error as ManifestSchedulerAdmissionError {
            throw error
        } catch let error as SchedulerEngineValidationError {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling([
                "\(field):\(error.stableKey)"
            ])
        } catch {
            throw ManifestSchedulerAdmissionError.unsupportedScheduling([field])
        }
    }

    private static func mapAcceleratorRequirements(
        _ claims: [HostwrightAcceleratorClaim]
    ) throws -> ResourceVector {
        do {
            return try ResourceVector(
                Dictionary(uniqueKeysWithValues: claims.map { ($0.name, Int64($0.count)) })
            )
        } catch let error as SchedulerValidationError {
            throw ManifestSchedulerAdmissionError.schedulerContract(error.stableKey)
        } catch {
            throw ManifestSchedulerAdmissionError.schedulerContract(
                String(describing: error)
            )
        }
    }
}
