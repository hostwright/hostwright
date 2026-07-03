public enum PlanRenderMode: Equatable, Sendable {
    case cli
    case compact
}

public enum PlanRenderer {
    public static func render(_ plan: ReconciliationPlan, mode: PlanRenderMode = .cli) -> String {
        switch mode {
        case .cli:
            return renderCLI(plan)
        case .compact:
            return renderCompact(plan)
        }
    }

    private static func renderCLI(_ plan: ReconciliationPlan) -> String {
        var lines: [String] = [
            "Hostwright plan (non-mutating)",
            "Project: \(plan.projectName)",
            "Plan hash: \(plan.planHash)",
            "Runtime observation: \(plan.observationConnected ? "connected from supplied observed state" : "not connected for CLI plan; no Apple container state was inspected")",
            "Execution: unavailable unless a createMissingService action is explicitly confirmed",
            ""
        ]

        lines.append("Issues:")
        if plan.issues.isEmpty {
            lines.append("- none")
        } else {
            lines += plan.issues.map { issue in
                "- [\(issue.severity.rawValue)] \(issue.kind.rawValue): \(issue.identity?.displayName ?? "project") - \(issue.message)"
            }
        }

        lines.append("")
        lines.append("Planned actions:")
        if plan.actions.isEmpty {
            lines.append("- none")
        } else {
            lines += plan.actions.map { action in
                "- \(action.kind.rawValue): \(action.identity.displayName) - \(action.reason) (\(action.executionAvailability.rawValue))"
            }
        }

        lines.append("")
        lines.append("No runtime actions were executed.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func renderCompact(_ plan: ReconciliationPlan) -> String {
        "plan=\(plan.planHash) issues=\(plan.issues.count) drift=\(plan.drift.count) actions=\(plan.actions.count)"
    }
}
