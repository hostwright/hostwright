import Darwin
import Foundation

public enum ProjectDNSRecordType: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case aaaa = "AAAA"

    fileprivate var sortOrder: Int {
        switch self {
        case .a: return 0
        case .aaaa: return 1
        }
    }
}

public struct ProjectDNSRecord: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let type: ProjectDNSRecordType
    public let address: String
    public let ttlSeconds: Int

    public init(
        name: String,
        type: ProjectDNSRecordType,
        address: String,
        ttlSeconds: Int
    ) {
        self.name = name
        self.type = type
        self.address = address
        self.ttlSeconds = ttlSeconds
    }
}

public struct ProjectDNSReplica: Codable, Equatable, Sendable {
    public let name: String
    public let isReady: Bool
    public let ipv4Addresses: [String]
    public let ipv6Addresses: [String]

    public init(
        name: String,
        isReady: Bool,
        ipv4Addresses: [String] = [],
        ipv6Addresses: [String] = []
    ) {
        self.name = name
        self.isReady = isReady
        self.ipv4Addresses = ipv4Addresses
        self.ipv6Addresses = ipv6Addresses
    }
}

public struct ProjectDNSService: Codable, Equatable, Sendable {
    public let name: String
    public let aliases: [String]
    public let replicas: [ProjectDNSReplica]

    public init(
        name: String,
        aliases: [String] = [],
        replicas: [ProjectDNSReplica]
    ) {
        self.name = name
        self.aliases = aliases
        self.replicas = replicas
    }
}

public struct ProjectDNSHostAccessBinding:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let hostname: String
    public let protocolName: HostwrightHostAccessProtocol
    public let addressClass: HostwrightHostAccessAddressClass
    public let listenAddress: String
    public let clientCIDR: String
    public let targetAddress: String
    public let port: Int

    public init(
        hostname: String,
        protocolName: HostwrightHostAccessProtocol,
        addressClass: HostwrightHostAccessAddressClass,
        listenAddress: String,
        clientCIDR: String,
        targetAddress: String,
        port: Int
    ) {
        self.hostname = hostname
        self.protocolName = protocolName
        self.addressClass = addressClass
        self.listenAddress = listenAddress
        self.clientCIDR = clientCIDR
        self.targetAddress = targetAddress
        self.port = port
    }

    public static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        let lhsFields = [
            lhs.hostname,
            lhs.protocolName.rawValue,
            String(format: "%05d", lhs.port),
            lhs.addressClass.rawValue,
            lhs.listenAddress,
            lhs.clientCIDR,
            lhs.targetAddress
        ]
        let rhsFields = [
            rhs.hostname,
            rhs.protocolName.rawValue,
            String(format: "%05d", rhs.port),
            rhs.addressClass.rawValue,
            rhs.listenAddress,
            rhs.clientCIDR,
            rhs.targetAddress
        ]
        return lhsFields.lexicographicallyPrecedes(rhsFields)
    }
}

public struct ProjectIngressBackend:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let serviceUUID: String
    public let address: String
    public let port: Int

    public init(
        serviceUUID: String,
        address: String,
        port: Int
    ) {
        self.serviceUUID = serviceUUID
        self.address = address
        self.port = port
    }

    public static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        (lhs.serviceUUID, lhs.address, lhs.port) <
            (rhs.serviceUUID, rhs.address, rhs.port)
    }
}

public struct ProjectIngressRouteBinding:
    Codable,
    Equatable,
    Sendable
{
    public let hostname: String
    public let pathPrefix: String
    public let methods: [String]
    public let protocolName: HostwrightIngressRouteProtocol
    public let targetServiceUUIDs: [String]
    public let targetPort: Int
    public let backends: [ProjectIngressBackend]

    public init(
        hostname: String,
        pathPrefix: String,
        methods: [String],
        protocolName: HostwrightIngressRouteProtocol,
        targetServiceUUIDs: [String],
        targetPort: Int,
        backends: [ProjectIngressBackend]
    ) {
        self.hostname = hostname
        self.pathPrefix = pathPrefix
        self.methods = methods.sorted()
        self.protocolName = protocolName
        self.targetServiceUUIDs = targetServiceUUIDs.sorted()
        self.targetPort = targetPort
        self.backends = backends.sorted(
            by: ProjectIngressBackend.canonicalPrecedes
        )
    }

    public static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        let lhsFields = [
            lhs.hostname,
            lhs.pathPrefix,
            lhs.protocolName.rawValue,
            lhs.methods.joined(separator: ","),
            lhs.targetServiceUUIDs.joined(separator: ","),
            String(format: "%05d", lhs.targetPort)
        ]
        let rhsFields = [
            rhs.hostname,
            rhs.pathPrefix,
            rhs.protocolName.rawValue,
            rhs.methods.joined(separator: ","),
            rhs.targetServiceUUIDs.joined(separator: ","),
            String(format: "%05d", rhs.targetPort)
        ]
        return lhsFields.lexicographicallyPrecedes(rhsFields)
    }
}

public struct ProjectIngressListenerBinding:
    Codable,
    Equatable,
    Sendable
{
    public let name: String
    public let bindAddress: String
    public let port: Int
    public let exposure: HostwrightPortExposurePolicy
    public let routes: [ProjectIngressRouteBinding]

    public init(
        name: String,
        bindAddress: String,
        port: Int,
        exposure: HostwrightPortExposurePolicy,
        routes: [ProjectIngressRouteBinding]
    ) {
        self.name = name
        self.bindAddress = bindAddress
        self.port = port
        self.exposure = exposure
        self.routes = routes.sorted(
            by: ProjectIngressRouteBinding.canonicalPrecedes
        )
    }

    public static func canonicalPrecedes(
        _ lhs: Self,
        _ rhs: Self
    ) -> Bool {
        (lhs.bindAddress, lhs.port, lhs.name) <
            (rhs.bindAddress, rhs.port, rhs.name)
    }
}

public struct ProjectDNSOptions: Codable, Equatable, Sendable {
    public let ttlSeconds: Int
    public let negativeTTLSeconds: Int
    public let upstreams: [String]
    public let searchDomains: [String]

    public init(
        ttlSeconds: Int = 30,
        negativeTTLSeconds: Int = 5,
        upstreams: [String] = [],
        searchDomains: [String] = []
    ) {
        self.ttlSeconds = ttlSeconds
        self.negativeTTLSeconds = negativeTTLSeconds
        self.upstreams = upstreams
        self.searchDomains = searchDomains
    }
}

public struct ProjectDNSPlan: Codable, Equatable, Sendable {
    public let projectUUID: String
    public let zone: String
    public let records: [ProjectDNSRecord]
    public let hostAccessBindings: [ProjectDNSHostAccessBinding]
    public let ingressBindings: [ProjectIngressListenerBinding]
    public let ttlSeconds: Int
    public let negativeTTLSeconds: Int
    public let upstreams: [String]
    public let searchDomains: [String]
    public let corefile: String
    public let searchDirective: String

    public init(
        projectUUID: String,
        zone: String,
        records: [ProjectDNSRecord],
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        ingressBindings: [ProjectIngressListenerBinding] = [],
        ttlSeconds: Int,
        negativeTTLSeconds: Int,
        upstreams: [String],
        searchDomains: [String],
        corefile: String,
        searchDirective: String
    ) {
        self.projectUUID = projectUUID
        self.zone = zone
        self.records = records
        self.hostAccessBindings = hostAccessBindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
        self.ingressBindings = ingressBindings.sorted(
            by: ProjectIngressListenerBinding.canonicalPrecedes
        )
        self.ttlSeconds = ttlSeconds
        self.negativeTTLSeconds = negativeTTLSeconds
        self.upstreams = upstreams
        self.searchDomains = searchDomains
        self.corefile = corefile
        self.searchDirective = searchDirective
    }

    private enum CodingKeys: String, CodingKey {
        case projectUUID
        case zone
        case records
        case hostAccessBindings
        case ingressBindings
        case ttlSeconds
        case negativeTTLSeconds
        case upstreams
        case searchDomains
        case corefile
        case searchDirective
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            projectUUID: try values.decode(
                String.self,
                forKey: .projectUUID
            ),
            zone: try values.decode(String.self, forKey: .zone),
            records: try values.decode(
                [ProjectDNSRecord].self,
                forKey: .records
            ),
            hostAccessBindings: try values.decodeIfPresent(
                [ProjectDNSHostAccessBinding].self,
                forKey: .hostAccessBindings
            ) ?? [],
            ingressBindings: try values.decodeIfPresent(
                [ProjectIngressListenerBinding].self,
                forKey: .ingressBindings
            ) ?? [],
            ttlSeconds: try values.decode(
                Int.self,
                forKey: .ttlSeconds
            ),
            negativeTTLSeconds: try values.decode(
                Int.self,
                forKey: .negativeTTLSeconds
            ),
            upstreams: try values.decode(
                [String].self,
                forKey: .upstreams
            ),
            searchDomains: try values.decode(
                [String].self,
                forKey: .searchDomains
            ),
            corefile: try values.decode(
                String.self,
                forKey: .corefile
            ),
            searchDirective: try values.decode(
                String.self,
                forKey: .searchDirective
            )
        )
    }
}

public enum ProjectDNSPlanningError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidProjectUUID(String)
    case invalidName(kind: String, value: String)
    case duplicateName(kind: String, value: String)
    case nameConflict(name: String, firstOwner: String, secondOwner: String)
    case invalidAddress(family: String, value: String)
    case invalidHostAccess(String)
    case invalidIngress(String)
    case invalidTTL(kind: String, value: Int, range: ClosedRange<Int>)
    case limitExceeded(kind: String, limit: Int)

    public var description: String {
        switch self {
        case .invalidProjectUUID(let value):
            return "Project DNS requires a canonical UUID; received '\(value)'."
        case .invalidName(let kind, let value):
            return "Invalid \(kind) DNS name '\(value)'."
        case .duplicateName(let kind, let value):
            return "Duplicate \(kind) DNS name '\(value)'."
        case .nameConflict(let name, let firstOwner, let secondOwner):
            return "DNS name '\(name)' is owned by both '\(firstOwner)' and '\(secondOwner)'."
        case .invalidAddress(let family, let value):
            return "Invalid \(family) address '\(value)'."
        case .invalidHostAccess(let message):
            return "Invalid host-access binding: \(message)."
        case .invalidIngress(let message):
            return "Invalid ingress binding: \(message)."
        case .invalidTTL(let kind, let value, let range):
            return "\(kind) TTL \(value) must be within \(range.lowerBound)...\(range.upperBound) seconds."
        case .limitExceeded(let kind, let limit):
            return "Project DNS \(kind) exceeds the limit of \(limit)."
        }
    }
}

public enum ProjectDNSPlanner {
    public static let zoneSuffix = "hostwright.internal"
    public static let ttlRange = 1...300
    public static let negativeTTLRange = 1...60
    public static let maximumServices = 1_000
    public static let maximumReplicas = 10_000
    public static let maximumRecords = 100_000
    public static let maximumUpstreams = 8
    public static let maximumAdditionalSearchDomains = 5

    public static func makePlan(
        projectUUID: String,
        services: [ProjectDNSService],
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        ingressBindings: [ProjectIngressListenerBinding] = [],
        options: ProjectDNSOptions = ProjectDNSOptions()
    ) throws -> ProjectDNSPlan {
        let canonicalProjectUUID = try canonicalProjectUUID(projectUUID)
        guard ttlRange.contains(options.ttlSeconds) else {
            throw ProjectDNSPlanningError.invalidTTL(
                kind: "positive",
                value: options.ttlSeconds,
                range: ttlRange
            )
        }
        guard negativeTTLRange.contains(options.negativeTTLSeconds) else {
            throw ProjectDNSPlanningError.invalidTTL(
                kind: "negative",
                value: options.negativeTTLSeconds,
                range: negativeTTLRange
            )
        }
        guard services.count <= maximumServices else {
            throw ProjectDNSPlanningError.limitExceeded(
                kind: "service count",
                limit: maximumServices
            )
        }

        let zone = "\(canonicalProjectUUID).\(zoneSuffix)"
        let canonicalUpstreams = try canonicalUpstreams(options.upstreams)
        let canonicalSearchDomains = try canonicalSearchDomains(
            projectZone: zone,
            additional: options.searchDomains
        )
        let records = try records(
            zone: zone,
            services: services,
            ttlSeconds: options.ttlSeconds
        )
        let canonicalHostAccess = try canonicalHostAccessBindings(
            hostAccessBindings
        )
        let canonicalIngress = ingressBindings.sorted(
            by: ProjectIngressListenerBinding.canonicalPrecedes
        )

        return ProjectDNSPlan(
            projectUUID: canonicalProjectUUID,
            zone: zone,
            records: records,
            hostAccessBindings: canonicalHostAccess,
            ingressBindings: canonicalIngress,
            ttlSeconds: options.ttlSeconds,
            negativeTTLSeconds: options.negativeTTLSeconds,
            upstreams: canonicalUpstreams,
            searchDomains: canonicalSearchDomains,
            corefile: renderCorefile(
                zone: zone,
                records: records,
                ttlSeconds: options.ttlSeconds,
                negativeTTLSeconds: options.negativeTTLSeconds,
                upstreams: canonicalUpstreams,
                hostAccessBindings: canonicalHostAccess
            ),
            searchDirective: "search \(canonicalSearchDomains.joined(separator: " "))"
        )
    }

    private static func canonicalProjectUUID(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = UUID(uuidString: value) else {
            throw ProjectDNSPlanningError.invalidProjectUUID(value)
        }
        let canonical = parsed.uuidString.lowercased()
        guard value.lowercased() == canonical else {
            throw ProjectDNSPlanningError.invalidProjectUUID(value)
        }
        return canonical
    }

    private static func records(
        zone: String,
        services: [ProjectDNSService],
        ttlSeconds: Int
    ) throws -> [ProjectDNSRecord] {
        var serviceNames = Set<String>()
        for service in services {
            try validateLabel(service.name, kind: "service")
            guard serviceNames.insert(service.name).inserted else {
                throw ProjectDNSPlanningError.duplicateName(
                    kind: "service",
                    value: service.name
                )
            }
        }

        var aliasOwners: [String: String] = [:]
        var replicaCount = 0
        var result = Set<ProjectDNSRecord>()

        for service in services.sorted(by: { $0.name < $1.name }) {
            var replicaNames = Set<String>()
            for alias in service.aliases {
                try validateLabel(alias, kind: "alias")
                if serviceNames.contains(alias) {
                    throw ProjectDNSPlanningError.nameConflict(
                        name: alias,
                        firstOwner: "service:\(alias)",
                        secondOwner: "alias:\(service.name)"
                    )
                }
                if let owner = aliasOwners[alias] {
                    throw ProjectDNSPlanningError.nameConflict(
                        name: alias,
                        firstOwner: "alias:\(owner)",
                        secondOwner: "alias:\(service.name)"
                    )
                }
                aliasOwners[alias] = service.name
            }

            replicaCount += service.replicas.count
            guard replicaCount <= maximumReplicas else {
                throw ProjectDNSPlanningError.limitExceeded(
                    kind: "replica count",
                    limit: maximumReplicas
                )
            }

            for replica in service.replicas.sorted(by: { $0.name < $1.name }) {
                try validateLabel(replica.name, kind: "replica")
                guard replicaNames.insert(replica.name).inserted else {
                    throw ProjectDNSPlanningError.duplicateName(
                        kind: "replica in service '\(service.name)'",
                        value: replica.name
                    )
                }

                let ipv4 = try canonicalAddresses(
                    replica.ipv4Addresses,
                    family: .a
                )
                let ipv6 = try canonicalAddresses(
                    replica.ipv6Addresses,
                    family: .aaaa
                )
                guard replica.isReady else {
                    continue
                }

                let names = [
                    "\(service.name).\(zone).",
                    "\(replica.name).\(service.name).\(zone)."
                ] + service.aliases.map { "\($0).\(zone)." }

                for name in names {
                    for address in ipv4 {
                        result.insert(
                            ProjectDNSRecord(
                                name: name,
                                type: .a,
                                address: address,
                                ttlSeconds: ttlSeconds
                            )
                        )
                    }
                    for address in ipv6 {
                        result.insert(
                            ProjectDNSRecord(
                                name: name,
                                type: .aaaa,
                                address: address,
                                ttlSeconds: ttlSeconds
                            )
                        )
                    }
                }

                guard result.count <= maximumRecords else {
                    throw ProjectDNSPlanningError.limitExceeded(
                        kind: "record count",
                        limit: maximumRecords
                    )
                }
            }
        }

        return result.sorted {
            if $0.name != $1.name {
                return $0.name < $1.name
            }
            if $0.type != $1.type {
                return $0.type.sortOrder < $1.type.sortOrder
            }
            return $0.address < $1.address
        }
    }

    private static func validateLabel(_ value: String, kind: String) throws {
        guard HostwrightNetworkIdentity.isValidManifestName(value) else {
            throw ProjectDNSPlanningError.invalidName(kind: kind, value: value)
        }
    }

    private static func canonicalAddresses(
        _ values: [String],
        family: ProjectDNSRecordType
    ) throws -> [String] {
        var result = Set<String>()
        for value in values {
            let canonical: String?
            switch family {
            case .a:
                canonical = canonicalIPv4(value)
            case .aaaa:
                canonical = canonicalIPv6(value)
            }
            guard let canonical else {
                throw ProjectDNSPlanningError.invalidAddress(
                    family: family.rawValue,
                    value: value
                )
            }
            result.insert(canonical)
        }
        return result.sorted()
    }

    private static func canonicalUpstreams(_ values: [String]) throws -> [String] {
        guard values.count <= maximumUpstreams else {
            throw ProjectDNSPlanningError.limitExceeded(
                kind: "upstream count",
                limit: maximumUpstreams
            )
        }
        var result = Set<String>()
        for value in values {
            guard let address = canonicalIPv4(value) ?? canonicalIPv6(value) else {
                throw ProjectDNSPlanningError.invalidAddress(
                    family: "upstream",
                    value: value
                )
            }
            result.insert(address)
        }
        return result.sorted()
    }

    private static func canonicalHostAccessBindings(
        _ values: [ProjectDNSHostAccessBinding]
    ) throws -> [ProjectDNSHostAccessBinding] {
        guard values.count <= maximumRecords else {
            throw ProjectDNSPlanningError.limitExceeded(
                kind: "host-access binding count",
                limit: maximumRecords
            )
        }
        var identities = Set<String>()
        var hostnameOwners: [String: ProjectDNSHostAccessBinding] = [:]
        var socketOwners: [String: ProjectDNSHostAccessBinding] = [:]
        for value in values {
            guard HostwrightHostAccessPolicy.isValidHostname(
                value.hostname
            ),
            let listen = canonicalIPv4(value.listenAddress),
            listen == value.listenAddress,
            canonicalIPv4CIDR(value.clientCIDR) ==
                value.clientCIDR,
            let target = canonicalIPv4(value.targetAddress),
            target == value.targetAddress,
            (1...65_535).contains(value.port) else {
                throw ProjectDNSPlanningError.invalidHostAccess(
                    "hostname, IPv4 address, or port is invalid"
                )
            }
            let identity = [
                value.hostname,
                value.protocolName.rawValue,
                String(value.port),
                value.addressClass.rawValue,
                value.listenAddress,
                value.clientCIDR,
                value.targetAddress
            ].joined(separator: "\u{1f}")
            guard identities.insert(identity).inserted else {
                throw ProjectDNSPlanningError.invalidHostAccess(
                    "duplicate endpoint '\(value.hostname)'"
                )
            }
            if let prior = hostnameOwners[value.hostname],
               (
                   prior.listenAddress != value.listenAddress ||
                       prior.clientCIDR != value.clientCIDR
               ) {
                throw ProjectDNSPlanningError.invalidHostAccess(
                    "hostname '\(value.hostname)' has conflicting broker addresses"
                )
            }
            hostnameOwners[value.hostname] = value
            let socket = [
                value.listenAddress,
                String(value.port),
                value.protocolName.rawValue
            ].joined(separator: "\u{1f}")
            if let prior = socketOwners[socket],
               prior.targetAddress != value.targetAddress ||
                prior.clientCIDR != value.clientCIDR ||
                prior.addressClass != value.addressClass {
                throw ProjectDNSPlanningError.invalidHostAccess(
                    "listener \(value.listenAddress):\(value.port)/\(value.protocolName.rawValue) has conflicting targets"
                )
            }
            socketOwners[socket] = value
        }
        return values.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
    }

    private static func canonicalSearchDomains(
        projectZone: String,
        additional: [String]
    ) throws -> [String] {
        guard additional.count <= maximumAdditionalSearchDomains else {
            throw ProjectDNSPlanningError.limitExceeded(
                kind: "additional search-domain count",
                limit: maximumAdditionalSearchDomains
            )
        }
        var domains = Set<String>()
        for domain in additional {
            guard validDomain(domain) else {
                throw ProjectDNSPlanningError.invalidName(
                    kind: "search-domain",
                    value: domain
                )
            }
            domains.insert(domain)
        }
        domains.remove(projectZone)
        return [projectZone] + domains.sorted()
    }

    private static func validDomain(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 253,
              value == value.lowercased(),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasSuffix(".") else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy {
                HostwrightNetworkIdentity.isValidManifestName(String($0))
            }
    }

    private static func canonicalIPv4(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        var address = in_addr()
        guard value.withCString({
            inet_pton(AF_INET, $0, &address)
        }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let canonical = string(from: buffer)
        return canonical == value ? canonical : nil
    }

    private static func canonicalIPv4CIDR(
        _ value: String
    ) -> String? {
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let address = canonicalIPv4(String(components[0])),
              let prefix = Int(components[1]),
              (0...32).contains(prefix) else {
            return nil
        }
        var raw = in_addr()
        guard address.withCString({
            inet_pton(AF_INET, $0, &raw)
        }) == 1 else {
            return nil
        }
        let hostOrder = UInt32(bigEndian: raw.s_addr)
        let mask = prefix == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefix)
        guard hostOrder & mask == hostOrder else { return nil }
        return "\(address)/\(prefix)"
    }

    private static func canonicalIPv6(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("%") else {
            return nil
        }
        var address = in6_addr()
        guard value.withCString({
            inet_pton(AF_INET6, $0, &address)
        }) == 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return string(from: buffer)
    }

    private static func string(from buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix(while: { $0 != 0 }).map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
    }

    private static func renderCorefile(
        zone: String,
        records: [ProjectDNSRecord],
        ttlSeconds: Int,
        negativeTTLSeconds: Int,
        upstreams: [String],
        hostAccessBindings: [ProjectDNSHostAccessBinding]
    ) -> String {
        var lines = [
            "\(zone):53 {",
            "    errors",
            "    reload 2s",
            "    hosts /dev/null \(zone) {"
        ]
        for record in records {
            lines.append("        \(record.address) \(record.name)")
        }
        lines.append(contentsOf: [
            "        ttl \(ttlSeconds)",
            "        no_reverse",
            "        reload 0s",
            "    }",
            "    cache {",
            "        success 1024 \(ttlSeconds) 0",
            "        denial 1024 \(negativeTTLSeconds) 0",
            "    }",
            "}"
        ])

        let forwardTargets = upstreams.isEmpty
            ? "/etc/resolv.conf"
            : upstreams.joined(separator: " ")
        lines.append(contentsOf: [".:53 {", "    errors"])
        if !hostAccessBindings.isEmpty {
            lines.append("    hosts /dev/null {")
            var renderedHosts = Set<String>()
            for binding in hostAccessBindings {
                let record =
                    "\(binding.listenAddress)\u{0}\(binding.hostname)"
                if renderedHosts.insert(record).inserted {
                    lines.append(
                        "        \(binding.listenAddress) \(binding.hostname)"
                    )
                }
            }
            lines.append(contentsOf: [
                "        ttl \(ttlSeconds)",
                "        no_reverse",
                "        reload 0s",
                "        fallthrough",
                "    }"
            ])
        }
        lines.append(contentsOf: [
            "    forward . \(forwardTargets)",
            "    cache {",
            "        success 1024 \(ttlSeconds) 0",
            "        denial 1024 \(negativeTTLSeconds) 0",
            "    }",
            "}"
        ])
        return lines.joined(separator: "\n") + "\n"
    }
}
