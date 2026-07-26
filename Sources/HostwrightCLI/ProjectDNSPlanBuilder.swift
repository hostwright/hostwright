import HostwrightNetworking
import HostwrightRuntime

enum ProjectDNSPlanBuilder {
    static func build(
        projectUUID: String,
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState,
        options: ProjectDNSOptions = ProjectDNSOptions()
    ) throws -> ProjectDNSPlan {
        let observedByIdentity = Dictionary(
            uniqueKeysWithValues: observedState.services.map {
                ($0.identity, $0)
            }
        )
        let grouped = Dictionary(
            grouping: desiredState.services,
            by: \.logicalServiceName
        )
        let services = grouped.keys.sorted().map {
            serviceName in
            let replicas = grouped[serviceName]!.sorted {
                if $0.replicaIndex != $1.replicaIndex {
                    return $0.replicaIndex < $1.replicaIndex
                }
                return $0.identity.displayName <
                    $1.identity.displayName
            }
            let aliases = Array(
                Set(replicas.flatMap {
                    $0.networks.flatMap(\.aliases)
                })
            ).sorted()
            return ProjectDNSService(
                name: serviceName,
                aliases: aliases,
                replicas: replicas.map {
                    replica(
                        desired: $0,
                        observed: observedByIdentity[$0.identity]
                    )
                }
            )
        }
        return try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: services,
            options: options
        )
    }

    private static func replica(
        desired: DesiredRuntimeService,
        observed: ObservedRuntimeService?
    ) -> ProjectDNSReplica {
        guard let observed else {
            return ProjectDNSReplica(
                name: replicaName(desired),
                isReady: false
            )
        }
        let ready = observed.healthState == .healthy ||
            (
                desired.probes.readiness == nil &&
                    observed.lifecycleState == .running &&
                    (
                        observed.healthState == .notConfigured ||
                            observed.healthState == .unknown
                    )
            )
        let desiredNetworkNames = Set(
            desired.networks.map(\.networkRuntimeIdentifier)
        )
        let attachments = observed.networks.filter {
            desiredNetworkNames.contains($0.name)
        }
        let ipv4 = attachments.compactMap(\.ipv4Address)
            .map(dnsHostAddress) +
            attachments.compactMap {
                guard let address = $0.address,
                      !address.contains(":") else {
                    return nil
                }
                return dnsHostAddress(address)
            }
        let ipv6 = attachments.compactMap(\.ipv6Address)
            .map(dnsHostAddress) +
            attachments.compactMap {
                guard let address = $0.address,
                      address.contains(":") else {
                    return nil
                }
                return dnsHostAddress(address)
            }
        return ProjectDNSReplica(
            name: replicaName(desired),
            isReady: ready,
            ipv4Addresses: Array(Set(ipv4)).sorted(),
            ipv6Addresses: Array(Set(ipv6)).sorted()
        )
    }

    private static func dnsHostAddress(_ address: String) -> String {
        let parts = address.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              !parts[0].isEmpty,
              let prefix = Int(parts[1]) else {
            return address
        }
        let host = String(parts[0])
        let validPrefix = host.contains(":")
            ? (0...128).contains(prefix)
            : (0...32).contains(prefix)
        return validPrefix ? host : address
    }

    private static func replicaName(
        _ desired: DesiredRuntimeService
    ) -> String {
        desired.identity.instanceName ??
            "\(desired.logicalServiceName)-\(desired.replicaIndex)"
    }
}
