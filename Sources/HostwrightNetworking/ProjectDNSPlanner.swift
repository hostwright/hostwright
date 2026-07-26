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
        self.ttlSeconds = ttlSeconds
        self.negativeTTLSeconds = negativeTTLSeconds
        self.upstreams = upstreams
        self.searchDomains = searchDomains
        self.corefile = corefile
        self.searchDirective = searchDirective
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

        return ProjectDNSPlan(
            projectUUID: canonicalProjectUUID,
            zone: zone,
            records: records,
            ttlSeconds: options.ttlSeconds,
            negativeTTLSeconds: options.negativeTTLSeconds,
            upstreams: canonicalUpstreams,
            searchDomains: canonicalSearchDomains,
            corefile: renderCorefile(
                zone: zone,
                records: records,
                ttlSeconds: options.ttlSeconds,
                negativeTTLSeconds: options.negativeTTLSeconds,
                upstreams: canonicalUpstreams
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
        upstreams: [String]
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
        lines.append(contentsOf: [
            ".:53 {",
            "    errors",
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
