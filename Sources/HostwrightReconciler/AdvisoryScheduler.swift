import HostwrightHealth
import HostwrightPolicy
import HostwrightRuntime

public struct AdvisoryScheduler: Equatable, Sendable {
    public init() {}

    public func evaluate(_ input: AdvisorySchedulingInput) -> AdvisorySchedulingReport {
        let policyDecisions = input.configuration.localPolicyEvaluator.evaluate(
            desiredState: input.desiredState,
            observedState: input.observedState
        )
        let decisionsByIdentity = Dictionary(grouping: policyDecisions.compactMap { decision -> (RuntimeServiceIdentity, PolicyDecision)? in
            guard let identity = decision.identity else {
                return nil
            }
            return (identity, decision)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        let advisoryBudget = advisoryMemoryBudget(
            physicalMemoryBytes: input.resourceReport.hardware.physicalMemoryBytes,
            percent: input.configuration.advisoryMemoryBudgetPercent
        )
        let totalDeclaredMemory = input.desiredState.services.reduce(0) { total, service in
            guard let memoryBytes = input.resourceRequests[service.identity]?.memoryBytes,
                  memoryBytes > 0 else {
                return total
            }
            return saturatingAdd(total, memoryBytes)
        }
        let classCounts = workloadClassCounts(input)

        let recommendations = input.desiredState.services.map { service in
            recommendation(
                for: service,
                request: input.resourceRequests[service.identity] ?? AdvisoryResourceRequest(),
                input: input,
                policyDecisions: decisionsByIdentity[service.identity] ?? [],
                advisoryBudget: advisoryBudget,
                totalDeclaredMemory: totalDeclaredMemory,
                classCount: classCounts[input.resourceRequests[service.identity]?.workloadClass ?? .unknown] ?? 0
            )
        }

        return AdvisorySchedulingReport(
            hostIdentifier: input.configuration.localHostIdentifier,
            advisoryMemoryBudgetBytes: advisoryBudget,
            totalDeclaredMemoryBytes: totalDeclaredMemory,
            recommendations: recommendations
        )
    }

    private func recommendation(
        for service: DesiredRuntimeService,
        request: AdvisoryResourceRequest,
        input: AdvisorySchedulingInput,
        policyDecisions: [PolicyDecision],
        advisoryBudget: Int?,
        totalDeclaredMemory: Int,
        classCount: Int
    ) -> AdvisorySchedulingRecommendation {
        var reasons: [AdvisorySchedulingReason] = [
            AdvisorySchedulingReason(
                category: .placement,
                reasonCode: .localHostCandidate,
                severity: .allow,
                message: "Local host \(input.configuration.localHostIdentifier) is the only advisory placement target.",
                remediation: "Review this recommendation manually; no runtime placement or reservation is performed.",
                stableDetailKey: input.configuration.localHostIdentifier
            )
        ]

        reasons.append(contentsOf: policyReasons(policyDecisions))
        reasons.append(contentsOf: memoryReasons(
            request: request,
            report: input.resourceReport,
            advisoryBudget: advisoryBudget,
            totalDeclaredMemory: totalDeclaredMemory
        ))
        reasons.append(contentsOf: workloadClassReasons(
            request: request,
            classCount: classCount,
            threshold: input.configuration.fairnessWarningThresholdPerClass
        ))
        reasons.append(contentsOf: acceleratorReasons(request))
        reasons.append(contentsOf: remotePlacementReasons(request))
        reasons.append(contentsOf: thermalReasons(input.resourceReport))

        let status: AdvisorySchedulingRecommendationStatus = reasons.contains { $0.severity == .blocker } ? .blocked : .recommended
        let score = status == .blocked ? 0 : clampedScore(reasons.reduce(100) { $0 + $1.scoreImpact })

        return AdvisorySchedulingRecommendation(
            identity: service.identity,
            hostIdentifier: input.configuration.localHostIdentifier,
            workloadClass: request.workloadClass,
            requestedMemoryBytes: request.memoryBytes,
            status: status,
            score: score,
            reasons: reasons
        )
    }

    private func policyReasons(_ decisions: [PolicyDecision]) -> [AdvisorySchedulingReason] {
        decisions.compactMap { decision in
            switch decision.severity {
            case .blocker:
                return AdvisorySchedulingReason(
                    category: .policy,
                    reasonCode: .policyBlocker,
                    severity: .blocker,
                    message: decision.message,
                    remediation: decision.remediation,
                    stableDetailKey: decision.stableDetailKey,
                    scoreImpact: -100,
                    policyReasonCode: decision.reasonCode
                )
            case .warning:
                return AdvisorySchedulingReason(
                    category: .policy,
                    reasonCode: .policyWarning,
                    severity: .warning,
                    message: decision.message,
                    remediation: decision.remediation,
                    stableDetailKey: decision.stableDetailKey,
                    scoreImpact: -10,
                    policyReasonCode: decision.reasonCode
                )
            case .allow:
                return nil
            }
        }
    }

    private func memoryReasons(
        request: AdvisoryResourceRequest,
        report: ResourceIntelligenceReport,
        advisoryBudget: Int?,
        totalDeclaredMemory: Int
    ) -> [AdvisorySchedulingReason] {
        guard let requestedMemory = request.memoryBytes else {
            return [
                AdvisorySchedulingReason(
                    category: .memory,
                    reasonCode: .memoryRequestMissing,
                    severity: .warning,
                    message: "No declared memory request is available for advisory scheduling.",
                    remediation: "Provide a declared memory request before relying on local placement advice.",
                    stableDetailKey: "memory:missing",
                    scoreImpact: -5
                )
            ]
        }

        guard requestedMemory > 0 else {
            return [
                AdvisorySchedulingReason(
                    category: .memory,
                    reasonCode: .memoryRequestInvalid,
                    severity: .blocker,
                    message: "Declared memory request must be greater than zero bytes.",
                    remediation: "Provide a positive declared memory request before relying on local placement advice.",
                    stableDetailKey: "memory:invalid",
                    scoreImpact: -100
                )
            ]
        }

        guard let hostMemory = report.hardware.physicalMemoryBytes,
              let advisoryBudget else {
            return [
                AdvisorySchedulingReason(
                    category: .memory,
                    reasonCode: .memoryBudgetUnavailable,
                    severity: .blocker,
                    message: "Local host memory facts are unavailable; scheduler advice cannot infer capacity.",
                    remediation: "Use a resource report with explicit host memory evidence.",
                    stableDetailKey: "memory:unavailable",
                    scoreImpact: -100
                )
            ]
        }

        if requestedMemory > hostMemory {
            return [
                AdvisorySchedulingReason(
                    category: .memory,
                    reasonCode: .memoryRequestExceedsHostMemory,
                    severity: .blocker,
                    message: "Declared memory request exceeds local physical memory.",
                    remediation: "Lower the declared memory request or use a different manually reviewed environment.",
                    stableDetailKey: "memory:request-exceeds-host",
                    scoreImpact: -100
                )
            ]
        }

        if totalDeclaredMemory > advisoryBudget {
            return [
                AdvisorySchedulingReason(
                    category: .memory,
                    reasonCode: .memoryOvercommit,
                    severity: .blocker,
                    message: "Total declared memory requests exceed the advisory local memory budget.",
                    remediation: "Reduce declared memory requests or split work before manual placement.",
                    stableDetailKey: "memory:overcommit",
                    scoreImpact: -100
                )
            ]
        }

        return [
            AdvisorySchedulingReason(
                category: .memory,
                reasonCode: .memoryWithinAdvisoryBudget,
                severity: .allow,
                message: "Declared memory request fits within the advisory local memory budget.",
                remediation: "This is not a reservation or production capacity guarantee.",
                stableDetailKey: "memory:within-budget",
                scoreImpact: 5
            )
        ]
    }

    private func workloadClassReasons(
        request: AdvisoryResourceRequest,
        classCount: Int,
        threshold: Int
    ) -> [AdvisorySchedulingReason] {
        var reasons = [
            AdvisorySchedulingReason(
                category: .workloadClass,
                reasonCode: .workloadClassConsidered,
                severity: .allow,
                message: "Workload class \(request.workloadClass.rawValue) was considered for local advisory scheduling.",
                remediation: "Workload class affects explanation and score only; it does not enforce operating-system QoS.",
                stableDetailKey: "class:\(request.workloadClass.rawValue)"
            )
        ]

        if classCount > threshold {
            reasons.append(
                AdvisorySchedulingReason(
                    category: .fairness,
                    reasonCode: .workloadClassFairnessPenalty,
                    severity: .warning,
                    message: "Workload class \(request.workloadClass.rawValue) has \(classCount) declared services, above the advisory fairness threshold \(threshold).",
                    remediation: "Review class mix manually; Hostwright does not preempt or enforce fair share.",
                    stableDetailKey: "class:\(request.workloadClass.rawValue):count:\(classCount)",
                    scoreImpact: -min(20, (classCount - threshold) * 5)
                )
            )
        }

        return reasons
    }

    private func acceleratorReasons(_ request: AdvisoryResourceRequest) -> [AdvisorySchedulingReason] {
        let requirements = request.acceleratorRequirements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        guard !requirements.isEmpty else {
            return []
        }

        return [
            AdvisorySchedulingReason(
                category: .accelerator,
                reasonCode: .acceleratorUnsupported,
                severity: .blocker,
                message: "Accelerator scheduling is unsupported for \(requirements.joined(separator: ", ")).",
                remediation: "Remove accelerator requirements or defer until a separate proof path, threat model, policy gate, and maintainer approval exist.",
                stableDetailKey: "accelerator:\(requirements.joined(separator: ","))",
                scoreImpact: -100
            )
        ]
    }

    private func remotePlacementReasons(_ request: AdvisoryResourceRequest) -> [AdvisorySchedulingReason] {
        guard request.requiresRemotePlacement else {
            return []
        }

        return [
            AdvisorySchedulingReason(
                category: .placement,
                reasonCode: .remotePlacementUnsupported,
                severity: .blocker,
                message: "Remote placement is unsupported in the local advisory scheduler.",
                remediation: "Keep placement local or defer to a separately approved multi-host design.",
                stableDetailKey: "placement:remote",
                scoreImpact: -100
            )
        ]
    }

    private func thermalReasons(_ report: ResourceIntelligenceReport) -> [AdvisorySchedulingReason] {
        guard report.thermal.value == ResourcePressureLevel.serious.rawValue ||
            report.thermal.value == ResourcePressureLevel.critical.rawValue else {
            return []
        }

        return [
            AdvisorySchedulingReason(
                category: .thermal,
                reasonCode: .thermalPressureWarning,
                severity: .warning,
                message: "Current host thermal state is \(report.thermal.value ?? "unknown").",
                remediation: "Review host conditions manually before placing more local work.",
                stableDetailKey: "thermal:\(report.thermal.value ?? "unknown")",
                scoreImpact: -15
            )
        ]
    }

    private func workloadClassCounts(_ input: AdvisorySchedulingInput) -> [AdvisoryWorkloadClass: Int] {
        input.desiredState.services.reduce(into: [:]) { counts, service in
            let workloadClass = input.resourceRequests[service.identity]?.workloadClass ?? .unknown
            counts[workloadClass, default: 0] += 1
        }
    }

    private func advisoryMemoryBudget(physicalMemoryBytes: Int?, percent: Int) -> Int? {
        guard let physicalMemoryBytes else {
            return nil
        }
        return (physicalMemoryBytes / 100) * percent
    }

    private func clampedScore(_ score: Int) -> Int {
        min(100, max(0, score))
    }
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? Int.max : result.partialValue
}
