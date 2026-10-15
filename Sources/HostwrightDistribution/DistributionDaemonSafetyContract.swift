enum DistributionDaemonSafetyContract {
    static func validate(
        _ output: String,
        packageVersion: String,
        sourceCommit: String
    ) throws {
        let observationalReleases = [
            "0.0.2-dev.11": "7d97d6c9ff878ec567c88e6993d4543ab8f0ad95",
            "0.0.2-dev.12": "71414005104933d8ee3591e8c91bc831bce2e2a2"
        ]
        let hasForeground = output.contains(
            "hostwrightd --foreground --config <hostwright.yaml>"
        )
        let valid: Bool
        if observationalReleases[packageVersion] == sourceCommit {
            valid = hasForeground
                && output.contains("This phase observes, plans, and records daemon loop attempts only.")
                && output.contains("It does not install a launch agent and does not perform unattended runtime mutation.")
                && !output.contains("hostwrightd --service")
        } else {
            valid = hasForeground
                && output.contains("hostwrightd --service --config <absolute-hostwright.yaml>")
                && output.contains(
                    "Mutations require exact provider capability, ownership, plan confirmation, and durable fencing."
                )
        }
        guard valid else {
            throw DistributionError.lifecycleFailed(
                "installed hostwrightd help did not preserve its safety boundary"
            )
        }
    }
}
