import Foundation
import HostwrightRuntime

public struct PlanningPolicy: Equatable, Sendable {
    public let requireHealthyServices: Bool
    public let warnOnPrivilegedHostPorts: Bool
    public let privilegedHostPortThreshold: Int
    public let blockedBindAddresses: [String]
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        requireHealthyServices: Bool = true,
        warnOnPrivilegedHostPorts: Bool = true,
        privilegedHostPortThreshold: Int = 1_024,
        blockedBindAddresses: [String] = ["0.0.0.0", "::"],
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.requireHealthyServices = requireHealthyServices
        self.warnOnPrivilegedHostPorts = warnOnPrivilegedHostPorts
        self.privilegedHostPortThreshold = privilegedHostPortThreshold
        self.blockedBindAddresses = blockedBindAddresses
        self.redactionPolicy = redactionPolicy
    }

    public static let `default` = PlanningPolicy()

    public func evaluate(desiredState: DesiredRuntimeState) -> [PlanIssue] {
        var issues: [PlanIssue] = []

        issues.append(contentsOf: validateDesiredIdentities(desiredState))
        issues.append(contentsOf: validatePorts(desiredState))
        issues.append(contentsOf: validateMounts(desiredState))
        issues.append(contentsOf: validateEnvironment(desiredState))

        return issues.sorted { $0.orderingKey < $1.orderingKey }
    }

    private func validateDesiredIdentities(_ desiredState: DesiredRuntimeState) -> [PlanIssue] {
        desiredState.services.compactMap { service in
            if service.identity.projectName.isEmpty || service.identity.serviceName.isEmpty {
                return PlanIssue(
                    kind: .invalidDesiredIdentity,
                    severity: .blocker,
                    identity: service.identity,
                    message: "Desired service identity must include a project and service name."
                )
            }
            return nil
        }
    }

    private func validatePorts(_ desiredState: DesiredRuntimeState) -> [PlanIssue] {
        var issues: [PlanIssue] = []
        var hostPortOwners: [String: RuntimeServiceIdentity] = [:]

        for service in desiredState.services {
            for port in service.ports {
                guard let hostPort = port.hostPort else {
                    continue
                }

                let key = "\(port.bindAddress ?? "localhost"):\(hostPort)/\(port.protocolName.rawValue)"
                if let owner = hostPortOwners[key], owner != service.identity {
                    issues.append(
                        PlanIssue(
                            kind: .duplicateDesiredHostPort,
                            severity: .blocker,
                            identity: service.identity,
                            message: "Desired host port \(hostPort) conflicts with \(owner.displayName).",
                            stableDetailKey: key
                        )
                    )
                } else {
                    hostPortOwners[key] = service.identity
                }

                if warnOnPrivilegedHostPorts && hostPort < privilegedHostPortThreshold {
                    issues.append(
                        PlanIssue(
                            kind: .privilegedHostPort,
                            severity: .warning,
                            identity: service.identity,
                            message: "Desired host port \(hostPort) is privileged; confirmed create rejects privileged host ports.",
                            stableDetailKey: key
                        )
                    )
                }

                if let bindAddress = port.bindAddress, blockedBindAddresses.contains(bindAddress) {
                    issues.append(
                        PlanIssue(
                            kind: .unsafeExposure,
                            severity: .blocker,
                            identity: service.identity,
                            message: "Desired bind address is broader than the first-release policy allows.",
                            stableDetailKey: key
                        )
                    )
                }
            }
        }

        return issues
    }

    private func validateMounts(_ desiredState: DesiredRuntimeState) -> [PlanIssue] {
        var issues: [PlanIssue] = []

        for service in desiredState.services {
            for mount in service.mounts {
                if mount.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    mount.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(
                        PlanIssue(
                            kind: .ambiguousVolumeReference,
                            severity: .blocker,
                            identity: service.identity,
                            message: "Desired mount source and target must be explicit.",
                            stableDetailKey: mount.target
                        )
                    )
                }

                if mount.source == "/" {
                    issues.append(
                        PlanIssue(
                            kind: .unsafeVolumePath,
                            severity: .blocker,
                            identity: service.identity,
                            message: "Root host mount is blocked by planning policy.",
                            stableDetailKey: mount.target
                        )
                    )
                }
            }
        }

        return issues
    }

    private func validateEnvironment(_ desiredState: DesiredRuntimeState) -> [PlanIssue] {
        var issues: [PlanIssue] = []

        for service in desiredState.services {
            for value in service.environment where value.isSensitive || redactionPolicy.isSensitiveKey(value.name) {
                issues.append(
                    PlanIssue(
                        kind: .secretRedacted,
                        severity: .warning,
                        identity: service.identity,
                        message: "Desired environment value for \(value.name) is treated as sensitive and redacted from plans.",
                        stableDetailKey: value.name
                    )
                )
            }
        }

        return issues
    }
}
