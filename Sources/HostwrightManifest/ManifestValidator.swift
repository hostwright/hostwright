import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightSecrets

public enum ManifestValidator {
    public static func validate(_ manifest: HostwrightManifest) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        validateVersion(manifest.version, issues: &issues)

        if let project = manifest.project, !project.isEmpty {
            validateName(project, field: "project", issues: &issues)
        } else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define a non-empty project."))
        }
        guard !manifest.services.isEmpty else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define at least one service."))
            return issues
        }

        validateImageTrust(manifest, issues: &issues)
        validateImageSBOM(manifest, issues: &issues)
        validateImageVulnerability(manifest, issues: &issues)
        validateImageProvenance(manifest, issues: &issues)
        validateProjectRestartBudget(manifest.restartBudget, issues: &issues)
        validateMaintenance(manifest.maintenance, issues: &issues)
        validateVolumeDeclarations(manifest.volumes, issues: &issues)
        validateNetworkDefinitions(manifest.networks, issues: &issues)
        validateCertificateDeclarations(manifest.certificates, issues: &issues)

        let declaredNames = Set(manifest.services.map(\.name))
        validateIngress(
            manifest.ingress,
            certificates: manifest.certificates,
            services: manifest.services,
            declaredNames: declaredNames,
            issues: &issues
        )
        validateTunnelDeclarations(
            manifest.tunnels,
            services: manifest.services,
            declaredNames: declaredNames,
            issues: &issues
        )
        let referencedCertificates = Set(
            manifest.ingress.values.compactMap(\.certificate)
        )
        for name in manifest.certificates.keys.sorted()
        where !referencedCertificates.contains(name) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Certificate '\(name)' must be referenced by at least one ingress listener.",
                    path: "$.certificates.\(name)"
                )
            )
        }
        let declaredVolumes = Set(manifest.volumes.keys)
        let declaredNetworks = Set(manifest.networks.keys)
        var serviceNames = Set<String>()
        for service in manifest.services {
            validateService(
                service,
                imagePolicy: manifest.effectiveImagePolicy,
                declaredNames: declaredNames,
                declaredVolumes: declaredVolumes,
                declaredNetworks: declaredNetworks,
                networkDefinitions: manifest.networks,
                issues: &issues
            )
            if !serviceNames.insert(service.name).inserted {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Duplicate service name: \(service.name)."))
            }
        }
        validatePublishedPortCollisions(manifest.services, issues: &issues)
        validatePublishedSocketCollisions(
            manifest.services,
            issues: &issues
        )
        return issues
    }

    private static func validateCertificateDeclarations(
        _ certificates: [String: HostwrightCertificateDeclaration],
        issues: inout [ManifestIssue]
    ) {
        guard certificates.count <= HostwrightCertificateDeclaration.maximumCertificates else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Certificates accepts at most \(HostwrightCertificateDeclaration.maximumCertificates) declarations.", path: "$.certificates"))
            return
        }
        for (name, certificate) in certificates.sorted(by: { $0.key < $1.key }) {
            let path = "$.certificates.\(name)"
            validateName(name, field: "certificate name", issues: &issues)
            if !(3_600...2_592_000).contains(certificate.renewBeforeSeconds) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Certificate renewBeforeSeconds must be between 3600 and 2592000.", path: "\(path).renewBeforeSeconds"))
            }
            if !(86_400...31_536_000).contains(certificate.validitySeconds) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Certificate validitySeconds must be between 86400 and 31536000.", path: "\(path).validitySeconds"))
            }
            if certificate.renewBeforeSeconds >= certificate.validitySeconds {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Certificate renewBeforeSeconds must be less than validitySeconds.", path: path))
            }
            switch certificate.source {
            case .imported:
                if certificate.identitySHA256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Imported certificate requires a lowercase 64-hex identitySHA256.", path: "\(path).identitySHA256"))
                }
                if certificate.issuer != nil { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Imported certificate must not declare issuer.", path: "\(path).issuer")) }
            case .localCA:
                if certificate.identitySHA256 != nil || certificate.issuer != nil { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "localCA certificate must not declare identitySHA256 or issuer.", path: path)) }
            case .provider:
                if certificate.identitySHA256 != nil { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Provider certificate must not declare identitySHA256.", path: "\(path).identitySHA256")) }
                if let issuer = certificate.issuer, HostwrightNetworkIdentity.isValidManifestName(issuer) {} else { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Provider certificate requires a valid exact issuer ID.", path: "\(path).issuer")) }
            }
        }
    }

    public static func validated(_ text: String) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    public static func validated(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text, cancellationCheck: cancellationCheck)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    static func normalizedNetworkCIDR(_ rawValue: String, ipv6: Bool) -> String? {
        NetworkCIDR(rawValue, family: ipv6 ? .ipv6 : .ipv4)?.canonicalValue
    }

    private static func validateService(
        _ service: HostwrightService,
        imagePolicy: HostwrightImagePolicy,
        declaredNames: Set<String>,
        declaredVolumes: Set<String>,
        declaredNetworks: Set<String>,
        networkDefinitions: [String: HostwrightNetworkDefinition],
        issues: inout [ManifestIssue]
    ) {
        validateName(service.name, field: "service name", issues: &issues)
        if !(1...256).contains(service.replicas) {
            issues.append(issue(service, "replicas must be between 1 and 256."))
        }

        if let image = service.image, !image.trimmingCharacters(in: .whitespaces).isEmpty {
            validateImage(image, serviceName: service.name, imagePolicy: imagePolicy, issues: &issues)
        } else {
            issues.append(issue(service, "must define a non-empty image."))
        }

        if let cpus = service.resources?.cpus, cpus <= 0 {
            issues.append(issue(service, "resources.cpus must be a positive integer."))
        }
        if let memory = service.resources?.memory {
            validateSize(memory, field: "resources.memory", service: service, issues: &issues)
        }
        if let shmSize = service.shmSize {
            validateSize(shmSize, field: "shmSize", service: service, issues: &issues)
        }

        if let workdir = service.workdir, !isNormalizedAbsoluteContainerPath(workdir) {
            issues.append(issue(service, "workdir must be a normalized absolute container path."))
        }
        validateCommand(service.entrypoint, field: "entrypoint", service: service, issues: &issues)
        validateCommand(service.command, field: "command", service: service, issues: &issues)

        for (dependency, _) in service.dependsOn.sorted(by: { $0.key < $1.key }) {
            validateName(dependency, field: "dependency name", issues: &issues)
            if dependency == service.name {
                issues.append(issue(service, "dependsOn must not reference the service itself."))
            } else if !declaredNames.contains(dependency) {
                issues.append(issue(service, "dependsOn references missing service '\(dependency)'."))
            }
        }

        for port in service.publishedPorts {
            validatePublishedPort(port, serviceName: service.name, issues: &issues)
        }
        if Set(service.publishedPorts.map(stablePublishedPortKey)).count != service.publishedPorts.count {
            issues.append(issue(service, "ports must not contain duplicates."))
        }
        for socket in service.publishedSockets {
            validatePublishedSocket(
                socket,
                serviceName: service.name,
                issues: &issues
            )
        }
        if Set(service.publishedSockets.map(stablePublishedSocketKey)).count !=
            service.publishedSockets.count {
            issues.append(
                issue(service, "Unix socket publications must not contain duplicates.")
            )
        }
        if Set(service.publishedSockets.map(publishedSocketHostKey)).count !=
            service.publishedSockets.count {
            issues.append(
                issue(
                    service,
                    "Unix socket publications must not resolve to the same host path."
                )
            )
        }
        if Set(service.publishedSockets.map(\.containerPath)).count !=
            service.publishedSockets.count {
            issues.append(
                issue(
                    service,
                    "Unix socket publications must not share a container target."
                )
            )
        }
        validateHostAccess(service.hostAccess, service: service, issues: &issues)
        validateNetworkPolicy(service.networkPolicy, service: service, issues: &issues)
        validateServiceNetworks(
            service.networks,
            service: service,
            declaredNetworks: declaredNetworks,
            issues: &issues
        )
        if !service.hostAccess.isEmpty,
           service.networks.count != 1 {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Service '\(service.name)' hostAccess requires exactly one declared project-network attachment so its guarded gateway is unambiguous.",
                    path:
                        "$.services.\(service.name).networks"
                )
            )
        } else if !service.hostAccess.isEmpty,
                  let networkName = service.networks.first?.network,
                  let network = networkDefinitions[networkName],
                  network.ipv4 == .disabled {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Service '\(service.name)' hostAccess requires an IPv4-enabled project network because Apple's guarded host gateway is IPv4-only.",
                    path:
                        "$.services.\(service.name).networks[0]"
                )
            )
        }
        for volume in service.volumes {
            validateVolume(volume, serviceName: service.name, issues: &issues)
        }
        for mount in service.mounts {
            validateMount(mount, serviceName: service.name, issues: &issues)
            if mount.kind == .volume,
               let source = mount.source,
               !declaredVolumes.contains(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(service.name)' volume mount source '\(source)' must reference a declared top-level volume."
                    )
                )
            }
        }

        for (key, value) in service.env.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateLiteralEnvironmentValue(key: key, value: value, serviceName: service.name, issues: &issues)
            validateBounded(value, maximum: 16_384, field: "env.\(key)", service: service, issues: &issues)
        }
        for (key, reference) in service.secretEnv.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateSecretEnvironmentReference(key: key, reference: reference, serviceName: service.name, issues: &issues)
            if service.env.keys.contains(key) {
                issues.append(issue(service, "environment key '\(key)' must not appear in both env and secretEnv."))
            }
        }
        validateLabels(service.labels, service: service, issues: &issues)

        if let health = service.health {
            validateHealth(health, serviceName: service.name, issues: &issues)
        }
        validateProbe(service.probes.startup, name: "startup", service: service, issues: &issues)
        validateProbe(service.probes.readiness, name: "readiness", service: service, issues: &issues)
        validateProbe(service.probes.liveness, name: "liveness", service: service, issues: &issues)

        if let restart = service.restart {
            validateRestart(restart, serviceName: service.name, issues: &issues)
        }
        validateUpdate(service.update, replicas: service.replicas, service: service, issues: &issues)
        validateHook(service.hooks.postStart, name: "postStart", service: service, issues: &issues)
        validateHook(service.hooks.preStop, name: "preStop", service: service, issues: &issues)

        if service.rosetta && service.platform.architecture != .amd64 {
            issues.append(issue(service, "rosetta requires platform.architecture amd64."))
        }
        if service.rosetta && !service.virtualization {
            issues.append(issue(service, "rosetta requires virtualization."))
        }
    }

    private static func validateHostAccess(
        _ endpoints: [HostwrightHostAccessEndpoint],
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let path = "$.services.\(service.name).hostAccess"
        if endpoints.count > HostwrightHostAccessEndpoint.maximumEndpointsPerService {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Service '\(service.name)' hostAccess must declare at most \(HostwrightHostAccessEndpoint.maximumEndpointsPerService) endpoints.",
                    path: path
                )
            )
        }

        var identities = Set<String>()
        for (index, endpoint) in endpoints.enumerated() {
            let endpointPath = "\(path)[\(index)]"
            guard HostwrightHostAccessPolicy.isValidHostname(endpoint.hostname) else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Service '\(service.name)' hostAccess hostname '\(endpoint.hostname)' must be a lowercase DNS hostname and must not be a wildcard, IP literal, or reserved metadata name.",
                        path: "\(endpointPath).hostname"
                    )
                )
                continue
            }
            if !(1...65_535).contains(endpoint.port) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Service '\(service.name)' hostAccess port must be between 1 and 65535.",
                        path: "\(endpointPath).port"
                    )
                )
            }

            let identity = HostwrightHostAccessPolicy.endpointIdentity(endpoint)
            if !identities.insert(identity).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Service '\(service.name)' hostAccess endpoints must not contain duplicate '\(identity)'.",
                        path: endpointPath
                    )
                )
            }
        }
    }

    private static func validateNetworkPolicy(
        _ policy: HostwrightServiceNetworkPolicy?,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let policy else { return }
        let path = "$.services.\(service.name).networkPolicy"
        validateNetworkPolicyRules(policy.ingress, direction: "ingress", service: service, path: path, issues: &issues)
        validateNetworkPolicyRules(policy.egress, direction: "egress", service: service, path: path, issues: &issues)
    }

    private static func validateNetworkPolicyRules(
        _ rules: [HostwrightNetworkPolicyRule],
        direction: String,
        service: HostwrightService,
        path: String,
        issues: inout [ManifestIssue]
    ) {
        let directionPath = "\(path).\(direction)"
        if rules.count > HostwrightNetworkPolicyRule.maximumRulesPerDirection {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(service.name)' networkPolicy \(direction) accepts at most \(HostwrightNetworkPolicyRule.maximumRulesPerDirection) rules.",
                    path: directionPath
                )
            )
        }
        var uniqueRules = Set<String>()
        for (index, rule) in rules.enumerated() {
            let rulePath = "\(directionPath)[\(index)]"
            if rule.project == nil && rule.service == nil && rule.identity == nil &&
                rule.protocolName == nil && rule.address == nil && rule.port == nil && rule.dns == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(service.name)' networkPolicy \(direction) rules must contain at least one exact selector.",
                        path: rulePath
                    )
                )
            }
            if let project = rule.project {
                validateName(project, field: "networkPolicy project", issues: &issues)
            }
            if let peerService = rule.service {
                validateName(peerService, field: "networkPolicy service", issues: &issues)
            }
            if let identity = rule.identity, !isBoundedPolicyText(identity, maximum: 512) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(service.name)' networkPolicy identity must be bounded non-empty text.",
                        path: "\(rulePath).identity"
                    )
                )
            }
            if let address = rule.address {
                let ipv4 = NetworkCIDR(address, family: .ipv4)
                let ipv6 = NetworkCIDR(address, family: .ipv6)
                if let ipv4,
                   ipv4.canonicalValue != address || !ipv4.isNetworkAddress {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy address must be canonical IPv4 CIDR \(ipv4.canonicalNetworkValue).", path: "\(rulePath).address"))
                } else if let ipv6,
                          ipv6.canonicalValue != address || !ipv6.isNetworkAddress {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy address must be canonical IPv6 CIDR \(ipv6.canonicalNetworkValue).", path: "\(rulePath).address"))
                } else if ipv4 == nil && ipv6 == nil {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy address must be an exact canonical IPv4 or IPv6 CIDR.", path: "\(rulePath).address"))
                }
            }
            if let port = rule.port, !(1...65_535).contains(port) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy port must be between 1 and 65535.", path: "\(rulePath).port"))
            }
            if rule.port != nil && rule.protocolName == nil {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy port requires an exact protocol.", path: "\(rulePath).protocol"))
            }
            if let dns = rule.dns, !HostwrightHostAccessPolicy.isValidHostname(dns) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy dns must be a lowercase exact DNS hostname.", path: "\(rulePath).dns"))
            }
            if !uniqueRules.insert(rule.canonicalKey).inserted {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' networkPolicy \(direction) must not contain duplicate rules.", path: rulePath))
            }
        }
    }

    private static func validateVolumeDeclarations(
        _ volumes: [String: HostwrightVolumeDeclaration],
        issues: inout [ManifestIssue]
    ) {
        for (name, declaration) in volumes.sorted(by: { $0.key < $1.key }) {
            validateName(name, field: "volume name", issues: &issues)
            validateVolumeProvider(declaration.provider, volumeName: name, issues: &issues)
            validateVolumeCapacity(declaration.capacity, volumeName: name, issues: &issues)
            validateVolumeLabels(declaration.labels, volumeName: name, issues: &issues)
        }
    }

    private static func validateNetworkDefinitions(
        _ networks: [String: HostwrightNetworkDefinition],
        issues: inout [ManifestIssue]
    ) {
        for (name, definition) in networks.sorted(by: { $0.key < $1.key }) {
            guard HostwrightNetworkIdentity.isValidManifestName(name) else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Network name '\(name)' must be lowercase DNS-like text: letters, numbers, hyphens, no leading or trailing hyphen.",
                        path: "$.networks.\(name)"
                    )
                )
                continue
            }
            if definition.name != name {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Network declaration key '\(name)' must match its network identity '\(definition.name)'.",
                        path: "$.networks.\(name)"
                    )
                )
            }
            if definition.ipv4 == .disabled, definition.ipv6 == .disabled {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Network '\(name)' must enable at least one address family.",
                        path: "$.networks.\(name)"
                    )
                )
            }
            validateNetworkAddressRequest(
                definition.ipv4,
                family: .ipv4,
                networkName: name,
                issues: &issues
            )
            validateNetworkAddressRequest(
                definition.ipv6,
                family: .ipv6,
                networkName: name,
                issues: &issues
            )
        }
        validateNetworkCIDROverlaps(networks, family: .ipv4, issues: &issues)
        validateNetworkCIDROverlaps(networks, family: .ipv6, issues: &issues)
    }

    private static func validateIngress(
        _ ingress: [String: HostwrightIngressListener],
        certificates: [String: HostwrightCertificateDeclaration],
        services: [HostwrightService],
        declaredNames: Set<String>,
        issues: inout [ManifestIssue]
    ) {
        guard ingress.count <= HostwrightIngressListener.maximumListeners else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Ingress accepts at most \(HostwrightIngressListener.maximumListeners) listeners.",
                    path: "$.ingress"
                )
            )
            return
        }
        let servicesByName = Dictionary(
            services.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var listenerEndpoints = Set<String>()
        for (name, listener) in ingress.sorted(by: { $0.key < $1.key }) {
            let path = "$.ingress.\(name)"
            validateName(name, field: "ingress listener name", issues: &issues)
            if let certificate = listener.certificate {
                validateName(certificate, field: "ingress certificate name", issues: &issues)
                if certificates[certificate] == nil { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' references missing certificate '\(certificate)'.", path: "\(path).certificate")) }
            }
            if listener.exposure.scope == .lan || listener.exposure.authentication == .tls || listener.exposure.authentication == .mutualTLS {
                if listener.certificate == nil { issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' requires a certificate for LAN or TLS/mTLS exposure.", path: "\(path).certificate")) }
            }
            if listener.peers.count > HostwrightIngressListener.maximumPeers || Set(listener.peers).count != listener.peers.count {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' peers must be unique and contain at most \(HostwrightIngressListener.maximumPeers) entries.", path: "\(path).peers"))
            }
            for (index, peer) in listener.peers.enumerated() {
                if servicesByName[peer.service] == nil {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' peer references missing service '\(peer.service)'.", path: "\(path).peers[\(index)].service"))
                }
            }
            if listener.exposure.authentication == .mutualTLS {
                if listener.peers.isEmpty {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' mTLS requires at least one peer.", path: "\(path).peers"))
                }
                if listener.certificate == nil {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' mTLS requires a certificate.", path: "\(path).certificate"))
                }
            } else if !listener.peers.isEmpty {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Ingress listener '\(name)' peers are permitted only with mTLS authentication.", path: "\(path).peers"))
            }
            guard isValidBindAddress(listener.bindAddress),
                  isValidPort(listener.port) else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Ingress listener '\(name)' requires an exact IPv4 or IPv6 bind address and a port within 1...65535.",
                        path: path
                    )
                )
                continue
            }
            if !NetworkExposurePolicyValidation.isSemanticallyValid(
                listener.exposure,
                bindAddress: listener.bindAddress
            ) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Ingress listener '\(name)' exposure does not match its exact bind address and security policy.",
                        path: "\(path).exposure"
                    )
                )
            }
            let endpoint =
                "\(listener.bindAddress):\(listener.port)"
            if !listenerEndpoints.insert(endpoint).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Ingress listener endpoint '\(endpoint)' is declared more than once.",
                        path: path
                    )
                )
            }
            guard !listener.routes.isEmpty,
                  listener.routes.count <=
                    HostwrightIngressListener.maximumRoutes else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Ingress listener '\(name)' requires 1...\(HostwrightIngressListener.maximumRoutes) routes.",
                        path: "\(path).routes"
                    )
                )
                continue
            }

            var routeKeys = Set<String>()
            for (index, route) in listener.routes.enumerated() {
                let routePath = "\(path).routes[\(index)]"
                if !HostwrightHostAccessPolicy.isValidHostname(
                    route.hostname
                ) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route hostname '\(route.hostname)' must be exact lowercase DNS-like text without wildcards.",
                            path: "\(routePath).hostname"
                        )
                    )
                }
                if !isSafeIngressPathPrefix(route.pathPrefix) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route pathPrefix must be a normalized absolute path of at most 1,024 UTF-8 bytes without encoded or literal traversal.",
                            path: "\(routePath).pathPrefix"
                        )
                    )
                }
                let allowedMethods: Set<String> = [
                    "DELETE", "GET", "HEAD", "OPTIONS",
                    "PATCH", "POST", "PUT"
                ]
                if route.methods.isEmpty ||
                    route.methods.count >
                        HostwrightIngressRoute.maximumMethods ||
                    Set(route.methods).count != route.methods.count ||
                    !Set(route.methods).isSubset(of: allowedMethods) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route methods must be unique canonical HTTP methods from DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT.",
                            path: "\(routePath).methods"
                        )
                    )
                }
                if route.protocolName == .websocket &&
                    route.methods != ["GET"] {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "WebSocket ingress routes require exactly the GET method.",
                            path: "\(routePath).methods"
                        )
                    )
                }
                guard declaredNames.contains(route.targetService),
                      let target = servicesByName[route.targetService] else {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route references missing service '\(route.targetService)'.",
                            path: "\(routePath).targetService"
                        )
                    )
                    continue
                }
                if target.networks.isEmpty {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route target service '\(route.targetService)' must attach to a declared Hostwright project network.",
                            path: "\(routePath).targetService"
                        )
                    )
                }
                let declaredPorts = Set(
                    target.publishedPorts.flatMap {
                        Array($0.containerPortRange)
                    }
                )
                if !isValidPort(route.targetPort) ||
                    !declaredPorts.contains(route.targetPort) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Ingress route target port \(route.targetPort) must reference a declared container port on service '\(route.targetService)'.",
                            path: "\(routePath).targetPort"
                        )
                    )
                }
                for method in route.methods {
                    let key = [
                        route.hostname,
                        route.pathPrefix,
                        route.protocolName.rawValue,
                        method
                    ].joined(separator: "\u{1f}")
                    if !routeKeys.insert(key).inserted {
                        issues.append(
                            ManifestIssue(
                                code: .manifestValidationFailed,
                                message:
                                    "Ingress listener '\(name)' contains a conflicting route for hostname '\(route.hostname)', path '\(route.pathPrefix)', method '\(method)', and protocol '\(route.protocolName.rawValue)'.",
                                path: routePath
                            )
                        )
                    }
                }
            }
        }
    }

    private static func validateTunnelDeclarations(
        _ tunnels: [String: HostwrightTunnelDeclaration],
        services: [HostwrightService],
        declaredNames: Set<String>,
        issues: inout [ManifestIssue]
    ) {
        guard tunnels.count <= HostwrightTunnelDeclaration.maximumDeclarations else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Tunnels accepts at most \(HostwrightTunnelDeclaration.maximumDeclarations) declarations.",
                    path: "$.tunnels"
                )
            )
            return
        }
        let servicesByName = Dictionary(
            services.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (name, tunnel) in tunnels.sorted(by: { $0.key < $1.key }) {
            let path = "$.tunnels.\(name)"
            validateName(name, field: "tunnel name", issues: &issues)
            validateName(
                tunnel.targetService,
                field: "tunnel target service",
                issues: &issues
            )
            if !isValidPort(tunnel.targetPort) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' target port must be within 1...65535.",
                        path: "\(path).targetPort"
                    )
                )
            }
            if tunnel.role != .dialer {
                guard declaredNames.contains(tunnel.targetService),
                      let target = servicesByName[tunnel.targetService] else {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message: "Tunnel '\(name)' references missing service '\(tunnel.targetService)'.",
                            path: "\(path).targetService"
                        )
                    )
                    continue
                }
                let declaredPorts = Set(
                    target.publishedPorts.flatMap { Array($0.containerPortRange) }
                )
                let matchingPorts = target.publishedPorts.filter {
                    $0.containerPortRange.contains(tunnel.targetPort)
                }
                if !declaredPorts.contains(tunnel.targetPort) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message: "Tunnel '\(name)' target port \(tunnel.targetPort) must reference a declared container port on service '\(tunnel.targetService)'.",
                            path: "\(path).targetPort"
                        )
                    )
                } else if !matchingPorts.contains(where: {
                    $0.effectiveExposure.scope == .tunnel &&
                        $0.effectiveExposure.authentication ==
                            .authenticatedTunnel
                }) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Tunnel '\(name)' target port \(tunnel.targetPort) must use tunnel exposure with authenticated-tunnel identity.",
                            path: "\(path).targetPort"
                        )
                    )
                }
                if matchingPorts.count != 1 ||
                    matchingPorts.first?.protocolName != .tcp ||
                    matchingPorts.first?.target.singlePort != tunnel.targetPort ||
                    matchingPorts.first.map({
                        !isLoopbackBindAddress($0.effectiveBindAddress)
                    }) != false {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Tunnel '\(name)' target must resolve to one TCP loopback mapping.",
                            path: "\(path).targetPort"
                        )
                    )
                }
                if target.replicas != 1 {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message:
                                "Tunnel '\(name)' currently requires exactly one target service replica.",
                            path: "\(path).targetService"
                        )
                    )
                }
            }
            if !HostwrightResourceUUID.isValid(tunnel.peerUUID) ||
                tunnel.peerUUID != tunnel.peerUUID.lowercased() {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Tunnel '\(name)' peerUUID must be a canonical lowercase Hostwright UUID.",
                        path: "\(path).peerUUID"
                    )
                )
            }
            if tunnel.authenticatedEndpoints.count >
                HostwrightTunnelDeclaration.maximumAuthenticatedEndpoints ||
                Set(tunnel.authenticatedEndpoints).count !=
                    tunnel.authenticatedEndpoints.count {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Tunnel '\(name)' authenticatedEndpoints must be unique and contain at most \(HostwrightTunnelDeclaration.maximumAuthenticatedEndpoints) entries.",
                        path: "\(path).authenticatedEndpoints"
                    )
                )
            }
            validateTunnelRole(tunnel, name: name, path: path, issues: &issues)
            for (index, endpoint) in tunnel.authenticatedEndpoints.enumerated() {
                validateTunnelEndpoint(
                    endpoint,
                    tunnelName: name,
                    path: "\(path).authenticatedEndpoints[\(index)]",
                    issues: &issues
                )
            }
            if let relay = tunnel.relayEndpoint {
                validateTunnelEndpoint(
                    relay,
                    tunnelName: name,
                    path: "\(path).relayEndpoint",
                    issues: &issues
                )
            }
        }
    }

    private static func validateTunnelRole(
        _ tunnel: HostwrightTunnelDeclaration,
        name: String,
        path: String,
        issues: inout [ManifestIssue]
    ) {
        switch tunnel.role {
        case .localLoopback:
            if tunnel.trust != nil || tunnel.bindEndpoint != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' local-loopback role must not declare remote trust or a bindEndpoint.",
                        path: path
                    )
                )
            }
            if tunnel.authenticatedEndpoints.isEmpty &&
                !tunnel.bonjourDiscovery {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' requires an authenticated endpoint or Bonjour discovery.",
                        path: path
                    )
                )
            }
        case .listener:
            guard let trust = tunnel.trust else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' listener role requires explicit non-TOFU trust.",
                        path: "\(path).trust"
                    )
                )
                return
            }
            validateTunnelTrust(
                trust,
                role: tunnel.role,
                name: name,
                path: "\(path).trust",
                issues: &issues
            )
            guard let bind = tunnel.bindEndpoint else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' listener role requires an exact bindEndpoint.",
                        path: "\(path).bindEndpoint"
                    )
                )
                return
            }
            if !bind.isValid || !bind.isIPAddress || bind.isWildcard {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' listener bindEndpoint must use a canonical exact non-wildcard host and port within 1...65535.",
                        path: "\(path).bindEndpoint"
                    )
                )
            }
        case .dialer:
            guard let trust = tunnel.trust else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' dialer role requires explicit non-TOFU trust.",
                        path: "\(path).trust"
                    )
                )
                return
            }
            validateTunnelTrust(
                trust,
                role: tunnel.role,
                name: name,
                path: "\(path).trust",
                issues: &issues
            )
            guard let bind = tunnel.bindEndpoint else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' dialer role requires an exact loopback bindEndpoint.",
                        path: "\(path).bindEndpoint"
                    )
                )
                return
            }
            if !bind.isValid || !bind.isLoopback {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' dialer bindEndpoint must use an exact loopback host and port within 1...65535.",
                        path: "\(path).bindEndpoint"
                    )
                )
            }
            if tunnel.authenticatedEndpoints.isEmpty &&
                !tunnel.bonjourDiscovery {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' dialer requires an authenticated endpoint or Bonjour discovery.",
                        path: path
                    )
                )
            }
        }
    }

    private static func validateTunnelTrust(
        _ trust: HostwrightTunnelTrust,
        role: HostwrightTunnelRole,
        name: String,
        path: String,
        issues: inout [ManifestIssue]
    ) {
        if !trust.isValid {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Tunnel '\(name)' trust requires canonical lowercase SHA-256 identity references and canonical peer names.",
                    path: path
                )
            )
        }
        switch role {
        case .listener:
            if trust.peerIdentityURI == nil || trust.peerDNSName != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' listener trust requires peerIdentityURI and must not declare peerDNSName.",
                        path: path
                    )
                )
            }
        case .dialer:
            if trust.peerDNSName == nil || trust.peerIdentityURI != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Tunnel '\(name)' dialer trust requires peerDNSName and must not declare peerIdentityURI.",
                        path: path
                    )
                )
            }
        case .localLoopback:
            break
        }
    }

    private static func validateTunnelEndpoint(
        _ endpoint: HostwrightTunnelManifestEndpoint,
        tunnelName: String,
        path: String,
        issues: inout [ManifestIssue]
    ) {
        guard endpoint.scheme == .tls,
              HostwrightTunnelManifestEndpoint.isValidHost(endpoint.host),
              HostwrightTunnelManifestEndpoint.canonicalHost(endpoint.host) == endpoint.host,
              isValidPort(endpoint.port) else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Tunnel '\(tunnelName)' endpoint must use tls with a canonical host and port within 1...65535.",
                    path: path
                )
            )
            return
        }
    }

    private static func isSafeIngressPathPrefix(_ value: String) -> Bool {
        if value == "/" {
            return true
        }
        guard value.hasPrefix("/"),
              value.utf8.count <= 1_024,
              value.rangeOfCharacter(
                from: .controlCharacters
              ) == nil,
              !value.contains("%"),
              !value.contains("?"),
              !value.contains("#"),
              !value.contains("//") else {
            return false
        }
        return value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func validateNetworkAddressRequest(
        _ request: HostwrightNetworkAddressRequest,
        family: NetworkAddressFamily,
        networkName: String,
        issues: inout [ManifestIssue]
    ) {
        guard case .cidr(let rawValue) = request else { return }
        let path = "$.networks.\(networkName).\(family.field)"
        guard isValidCIDR(rawValue, family: family) else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Network '\(networkName)' \(family.field) must be auto, disabled, or a valid \(family.label) CIDR.",
                    path: path
                )
            )
            return
        }
        guard let cidr = NetworkCIDR(rawValue, family: family) else {
            return
        }
        guard cidr.isNetworkAddress else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Network '\(networkName)' \(family.field) must use the canonical network address \(cidr.canonicalNetworkValue).",
                    path: path
                )
            )
            return
        }
    }

    private static func validateNetworkCIDROverlaps(
        _ networks: [String: HostwrightNetworkDefinition],
        family: NetworkAddressFamily,
        issues: inout [ManifestIssue]
    ) {
        let explicit = networks.sorted(by: { $0.key < $1.key }).compactMap {
            name,
            definition -> (String, NetworkCIDR)? in
            let request = family == .ipv4 ? definition.ipv4 : definition.ipv6
            guard case .cidr(let rawValue) = request,
                  let cidr = NetworkCIDR(rawValue, family: family),
                  cidr.isNetworkAddress else {
                return nil
            }
            return (name, cidr)
        }

        for laterIndex in explicit.indices {
            guard laterIndex > explicit.startIndex else { continue }
            for earlierIndex in explicit.indices where earlierIndex < laterIndex {
                let earlier = explicit[earlierIndex]
                let later = explicit[laterIndex]
                guard earlier.1.overlaps(later.1) else { continue }
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message:
                            "Network '\(later.0)' \(family.field) CIDR \(later.1.canonicalValue) overlaps network '\(earlier.0)' \(family.label) CIDR \(earlier.1.canonicalValue).",
                        path: "$.networks.\(later.0).\(family.field)"
                    )
                )
            }
        }
    }

    private static func validateServiceNetworks(
        _ attachments: [HostwrightServiceNetworkAttachment],
        service: HostwrightService,
        declaredNetworks: Set<String>,
        issues: inout [ManifestIssue]
    ) {
        let path = "$.services.\(service.name).networks"
        func networkIssue(_ message: String) -> ManifestIssue {
            ManifestIssue(
                code: .manifestValidationFailed,
                message: "Service '\(service.name)' \(message)",
                path: path
            )
        }

        var attachedNetworks = Set<String>()
        for attachment in attachments {
            if !HostwrightNetworkIdentity.isValidManifestName(attachment.network) {
                issues.append(
                    networkIssue(
                        "network attachment '\(attachment.network)' must use a lowercase DNS-like network name."
                    )
                )
            } else if !declaredNetworks.contains(attachment.network) {
                issues.append(
                    networkIssue(
                        "network attachment '\(attachment.network)' must reference a declared top-level network."
                    )
                )
            }
            if !attachedNetworks.insert(attachment.network).inserted {
                issues.append(
                    networkIssue(
                        "must not attach network '\(attachment.network)' more than once."
                    )
                )
            }

            if attachment.aliases.count >
                HostwrightServiceNetworkAttachment.maximumAliases {
                issues.append(
                    networkIssue(
                        "network '\(attachment.network)' must declare at most \(HostwrightServiceNetworkAttachment.maximumAliases) aliases."
                    )
                )
            }
            var aliases = Set<String>()
            for alias in attachment.aliases {
                if !HostwrightNetworkIdentity.isValidManifestName(alias) {
                    issues.append(
                        networkIssue(
                            "network alias '\(alias)' must be lowercase DNS-like text."
                        )
                    )
                }
                if !aliases.insert(alias).inserted {
                    issues.append(
                        networkIssue(
                            "network '\(attachment.network)' aliases must not contain duplicate '\(alias)'."
                        )
                    )
                }
            }
        }
    }

    private static func validateVersion(_ version: Int?, issues: inout [ManifestIssue]) {
        guard let version else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest must declare version: \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' for legacy manifests."
                )
            )
            return
        }
        guard version != HostwrightManifest.currentVersion else { return }
        if version < HostwrightManifest.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is older than supported version \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' to inspect the required conversion."
                )
            )
        } else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is newer than supported version \(HostwrightManifest.currentVersion). Upgrade requires a newer Hostwright release."
                )
            )
        }
    }

    private static func validateImageTrust(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let imageTrust = manifest.imageTrust else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust requires imagePolicy require-digest."
                )
            )
        }
        if imageTrust.version != HostwrightImageTrustPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.version must be 1."
                )
            )
        }
        if !(1...8).contains(imageTrust.threshold) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.threshold must be between 1 and 8."
                )
            )
        }
        if !(1...8).contains(imageTrust.authorities.count) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.authorities must contain between 1 and 8 authorities."
                )
            )
        }
        if imageTrust.threshold > imageTrust.authorities.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.threshold must not exceed the authority count."
                )
            )
        }
        if let trustedRoot = imageTrust.trustedRoot,
           !isNormalizedAbsoluteHostPath(trustedRoot) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.trustedRoot must be a normalized absolute host path."
                )
            )
        }
        let keylessAuthorities = imageTrust.authorities.filter { $0.type == .keyless }
        if !keylessAuthorities.isEmpty, imageTrust.trustedRoot == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust.trustedRoot is required when any keyless authority is declared."
                )
            )
        }

        var authorityIDs = Set<String>()
        for authority in imageTrust.authorities {
            if !authorityIDs.insert(authority.id).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust authority ids must be unique; duplicate id '\(authority.id)'."
                    )
                )
            }
            validateImageTrustAuthority(authority, issues: &issues)
        }
    }

    private static func validateImageSBOM(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let imageSBOM = manifest.imageSBOM else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM requires imagePolicy require-digest."
                )
            )
        }
        if imageSBOM.version != HostwrightImageSBOMPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM.version must be 1."
                )
            )
        }
        if imageSBOM.formats.isEmpty ||
            imageSBOM.formats.count > 2 ||
            Set(imageSBOM.formats).count != imageSBOM.formats.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageSBOM.formats must contain between 1 and 2 unique formats."
                )
            )
        }
    }

    private static func validateImageVulnerability(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let policy = manifest.imageVulnerability else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability requires imagePolicy require-digest."
                )
            )
        }
        if manifest.imageTrust == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability requires imageTrust."
                )
            )
        }
        if policy.version != HostwrightImageVulnerabilityPolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.version must be 1."
                )
            )
        }
        if !(0...HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds)
            .contains(policy.minimumVulnerabilityAgeSeconds) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.minimumVulnerabilityAgeSeconds must be between 0 and \(HostwrightImageVulnerabilityPolicy.maximumMinimumVulnerabilityAgeSeconds)."
                )
            )
        }
        if policy.maximumDatabaseAgeSeconds <
            HostwrightImageVulnerabilityPolicy.minimumMaximumDatabaseAgeSeconds ||
            policy.maximumDatabaseAgeSeconds >
            HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.maximumDatabaseAgeSeconds must be between \(HostwrightImageVulnerabilityPolicy.minimumMaximumDatabaseAgeSeconds) and \(HostwrightImageVulnerabilityPolicy.maximumMaximumDatabaseAgeSeconds)."
                )
            )
        }
        if policy.allowlist.count > HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageVulnerability.allowlist must contain at most \(HostwrightImageVulnerabilityPolicy.maximumAllowlistEntries) entries."
                )
            )
        }

        var exactEntries = Set<String>()
        for entry in policy.allowlist {
            let exactKey = "\(entry.vulnerabilityID)\u{0}\(entry.packagePURL ?? "")"
            if !exactEntries.insert(exactKey).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability.allowlist entries must be unique by vulnerabilityID and packagePURL."
                    )
                )
            }
            if entry.vulnerabilityID.utf8.count > 128 ||
                entry.vulnerabilityID.range(
                    of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
                    options: .regularExpression
                ) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist vulnerabilityID '\(entry.vulnerabilityID)' must be a bounded exact identifier."
                    )
                )
            }
            if let packagePURL = entry.packagePURL,
               !isExactPackagePURL(packagePURL) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist packagePURL must be a bounded exact package URL."
                    )
                )
            }
            if !isBoundedPolicyText(entry.reason, maximum: 512) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist reason must be a bounded non-empty string."
                    )
                )
            }
            if parseRFC3339(entry.expiresAt) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageVulnerability allowlist expiresAt must be an RFC3339 timestamp."
                    )
                )
            }
        }
    }

    private static func validateImageTrustAuthority(
        _ authority: HostwrightImageTrustAuthority,
        issues: inout [ManifestIssue]
    ) {
        if authority.id.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority id '\(authority.id)' must be a bounded safe identifier."
                )
            )
        }
        switch authority.type {
        case .keyed:
            if authority.publicKey == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' requires publicKey."
                    )
                )
            } else if let publicKey = authority.publicKey,
                      !isNormalizedAbsoluteHostPath(publicKey) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' publicKey must be a normalized absolute host path."
                    )
                )
            }
            if authority.issuer != nil || authority.identity != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyed authority '\(authority.id)' accepts only publicKey."
                    )
                )
            }
        case .keyless:
            if authority.publicKey != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' must not declare publicKey."
                    )
                )
            }
            if authority.issuer == nil || authority.identity == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' requires issuer and identity."
                    )
                )
            }
            if let issuer = authority.issuer, !isExactHTTPSURL(issuer) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' issuer must be an exact HTTPS URL."
                    )
                )
            }
            if let identity = authority.identity,
               !isBoundedIdentity(identity) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageTrust keyless authority '\(authority.id)' identity must be a bounded non-empty string."
                    )
                )
            }
        }

        let notBefore = authority.notBefore.flatMap(parseRFC3339)
        let notAfter = authority.notAfter.flatMap(parseRFC3339)
        let revokedAt = authority.revokedAt.flatMap(parseRFC3339)
        if authority.notBefore != nil && notBefore == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must be an RFC3339 timestamp."
                )
            )
        }
        if authority.notAfter != nil && notAfter == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notAfter must be an RFC3339 timestamp."
                )
            )
        }
        if authority.revokedAt != nil && revokedAt == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' revokedAt must be an RFC3339 timestamp."
                )
            )
        }
        if let notBefore, let notAfter, notBefore > notAfter {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must not be after notAfter."
                )
            )
        }
        if let notAfter, let revokedAt, notAfter > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notAfter must not be after revokedAt."
                )
            )
        }
        if let notBefore, let revokedAt, notBefore > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageTrust authority '\(authority.id)' notBefore must not be after revokedAt."
                )
            )
        }
    }

    private static func validateImageProvenance(
        _ manifest: HostwrightManifest,
        issues: inout [ManifestIssue]
    ) {
        guard let policy = manifest.imageProvenance else {
            return
        }
        guard manifest.version == HostwrightManifest.currentVersion else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance is supported only in manifest version 2."
                )
            )
            return
        }
        if manifest.effectiveImagePolicy != .requireDigest {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance requires imagePolicy require-digest."
                )
            )
        }
        if policy.version != HostwrightImageProvenancePolicy.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.version must be 1."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumBuilderIDs)
            .contains(policy.builderIDs.count) ||
            Set(policy.builderIDs).count != policy.builderIDs.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.builderIDs must contain between 1 and \(HostwrightImageProvenancePolicy.maximumBuilderIDs) unique values."
                )
            )
        }
        for builderID in policy.builderIDs where !isBoundedProvenanceURI(builderID) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance builderID '\(builderID)' must be a bounded https:// or urn: URI."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumBuildTypes)
            .contains(policy.buildTypes.count) ||
            Set(policy.buildTypes).count != policy.buildTypes.count {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.buildTypes must contain between 1 and \(HostwrightImageProvenancePolicy.maximumBuildTypes) unique values."
                )
            )
        }
        for buildType in policy.buildTypes where !isBoundedProvenanceURI(buildType) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance buildType '\(buildType)' must be a bounded https:// or urn: URI."
                )
            )
        }
        if !(1...HostwrightImageProvenancePolicy.maximumSigners).contains(policy.signers.count) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.signers must contain between 1 and \(HostwrightImageProvenancePolicy.maximumSigners) signers."
                )
            )
        }
        var signerIDs = Set<String>()
        for signer in policy.signers {
            if !signerIDs.insert(signer.id).inserted {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "imageProvenance signer ids must be unique; duplicate id '\(signer.id)'."
                    )
                )
            }
            validateImageProvenanceSigner(signer, issues: &issues)
        }
        if policy.maximumAgeSeconds <
            HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds ||
            policy.maximumAgeSeconds >
            HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance.maximumAgeSeconds must be between \(HostwrightImageProvenancePolicy.minimumMaximumAgeSeconds) and \(HostwrightImageProvenancePolicy.maximumMaximumAgeSeconds)."
                )
            )
        }
    }

    private static func validateImageProvenanceSigner(
        _ signer: HostwrightImageProvenanceSigner,
        issues: inout [ManifestIssue]
    ) {
        if signer.id.utf8.count > HostwrightImageProvenancePolicy.maximumSignerIDUTF8Bytes ||
            signer.id.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer id '\(signer.id)' must be a bounded safe identifier."
                )
            )
        }
        if signer.publicKey.utf8.count > HostwrightImageProvenancePolicy.maximumPublicKeyUTF8Bytes ||
            signer.publicKey.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) ||
            !isNormalizedAbsoluteHostPath(signer.publicKey) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' publicKey must be a bounded normalized absolute host path."
                )
            )
        }

        let notBefore = signer.notBefore.flatMap(parseRFC3339)
        let notAfter = signer.notAfter.flatMap(parseRFC3339)
        let revokedAt = signer.revokedAt.flatMap(parseRFC3339)
        if signer.notBefore != nil && notBefore == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must be an RFC3339 timestamp."
                )
            )
        }
        if signer.notAfter != nil && notAfter == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notAfter must be an RFC3339 timestamp."
                )
            )
        }
        if signer.revokedAt != nil && revokedAt == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' revokedAt must be an RFC3339 timestamp."
                )
            )
        }
        if let notBefore, let notAfter, notBefore > notAfter {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must not be after notAfter."
                )
            )
        }
        if let notAfter, let revokedAt, notAfter > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notAfter must not be after revokedAt."
                )
            )
        }
        if let notBefore, let revokedAt, notBefore > revokedAt {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "imageProvenance signer '\(signer.id)' notBefore must not be after revokedAt."
                )
            )
        }
    }

    private static func validateName(_ value: String, field: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
        if value.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "\(field) '\(value)' must be lowercase DNS-like text: letters, numbers, hyphens, no leading or trailing hyphen."
                )
            )
        }
    }

    private static func validateImage(
        _ image: String,
        serviceName: String,
        imagePolicy: HostwrightImagePolicy,
        issues: inout [ManifestIssue]
    ) {
        if image.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not contain whitespace."))
        }
        if image.hasPrefix("-") {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not begin with '-'."))
        }
        issues.append(contentsOf: ImageReferencePolicy.validate(image, serviceName: serviceName, policy: imagePolicy))
    }

    private static func validateCommand(
        _ command: [String],
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard command.count <= 1_024 else {
            issues.append(issue(service, "\(field) exceeds 1,024 arguments."))
            return
        }
        for token in command {
            if token.isEmpty {
                issues.append(issue(service, "\(field) tokens must not be empty."))
            } else {
                validateBounded(token, maximum: 16_384, field: field, service: service, issues: &issues)
            }
        }
    }

    private static func validatePublishedPort(
        _ port: HostwrightPublishedPort,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        guard isValidBindAddress(port.effectiveBindAddress) else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' bind address '\(port.effectiveBindAddress)' must be a valid IPv4 or IPv6 address."
                )
            )
            return
        }

        validatePortExposure(port.effectiveExposure, bindAddress: port.effectiveBindAddress, serviceName: serviceName, issues: &issues)

        validatePortSpan(port.target, label: "target", serviceName: serviceName, issues: &issues)
        if let host = port.host {
            validatePortSpan(host, label: "host", serviceName: serviceName, issues: &issues)
            if host.count != port.target.count {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' structured port ranges must have equal host and target lengths."
                    )
                )
            }
            if host.closedRange.contains(where: { $0 < 1_024 }) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' fixed published ports must be 1024 or higher."
                    )
                )
            }
        }
    }

    private static func validatePortExposure(
        _ exposure: HostwrightPortExposurePolicy,
        bindAddress: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let loopback = isLoopbackBindAddress(bindAddress)
        let exactNonLoopback = !loopback && bindAddress != "0.0.0.0" && bindAddress != "::"
        let interfacesValid = exposure.interfaces.allSatisfy(NetworkExposurePolicyValidation.isValidInterfaceSelector)
        let cidrsValid = exposure.allowedCIDRs.allSatisfy { NetworkExposurePolicyValidation.canonicalCIDR($0) == $0 }
        let path = "$.services.\(serviceName)"
        if !interfacesValid ||
            exposure.interfaces.count >
                HostwrightPortExposurePolicy.maximumInterfaceSelectors ||
            exposure.allowedCIDRs.count >
                HostwrightPortExposurePolicy.maximumAllowedCIDRs ||
            Set(exposure.interfaces).count != exposure.interfaces.count ||
            Set(exposure.networkClasses).count !=
                exposure.networkClasses.count ||
            Set(exposure.allowedCIDRs).count !=
                exposure.allowedCIDRs.count ||
            !cidrsValid {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' exposure selectors and CIDRs must be valid, canonical, and unique.", path: path))
        }
        switch exposure.scope {
        case .localhost:
            if !loopback || !exposure.interfaces.isEmpty || !exposure.networkClasses.isEmpty || !exposure.allowedCIDRs.isEmpty || exposure.authentication != .none {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' localhost exposure requires a loopback bind, empty selectors, and authentication none.", path: path))
            }
        case .lan:
            if !exactNonLoopback || !(1...HostwrightPortExposurePolicy.maximumInterfaceSelectors).contains(exposure.interfaces.count) || exposure.networkClasses.isEmpty || !Set(exposure.networkClasses).isSubset(of: [.privateLAN, .vpn]) || !(1...HostwrightPortExposurePolicy.maximumAllowedCIDRs).contains(exposure.allowedCIDRs.count) || exposure.authentication != .tls {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' lan exposure requires an exact non-loopback bind, 1-8 interfaces, private or vpn classes, 1-32 CIDRs, and TLS.", path: path))
            }
        case .tunnel:
            if !loopback || !exposure.interfaces.isEmpty || !exposure.networkClasses.isEmpty || exposure.authentication != .authenticatedTunnel {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' tunnel exposure requires a loopback bind, empty interface and network-class selectors, and authenticated-tunnel authentication.", path: path))
            }
        case .public:
            if !exactNonLoopback || exposure.interfaces.isEmpty || exposure.interfaces.count > HostwrightPortExposurePolicy.maximumInterfaceSelectors || !exposure.networkClasses.contains(.publicInternet) || exposure.allowedCIDRs.isEmpty || exposure.allowedCIDRs.count > HostwrightPortExposurePolicy.maximumAllowedCIDRs || !(exposure.authentication == .mutualTLS || exposure.authentication == .authenticatedTunnel) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' public exposure requires an exact non-loopback bind, interfaces, public network class, CIDRs, and mTLS or authenticated-tunnel authentication.", path: path))
            }
        case .project:
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' exposure scope project is not supported for published ports.", path: path))
        }
    }

    private static func validatePortSpan(
        _ span: HostwrightPortSpan,
        label: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        guard isValidPort(span.start), isValidPort(span.end), span.start <= span.end else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' \(label) port span '\(span.canonicalString)' must stay within 1...65535."
                )
            )
            return
        }
        if span.count > 256 {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' \(label) port ranges must not exceed 256 ports."
                )
            )
        }
    }

    private static func validatePublishedPortCollisions(
        _ services: [HostwrightService],
        issues: inout [ManifestIssue]
    ) {
        var ownersByEndpoint: [String: Set<String>] = [:]

        for service in services.sorted(by: { $0.name < $1.name }) {
            let publishedPorts = expandedPublishedEndpoints(service.publishedPorts)
            let uniquePorts = Set(publishedPorts.map(\.key))

            if service.replicas > 1, !uniquePorts.isEmpty {
                let endpoints = uniquePorts.sorted()
                if endpoints.allSatisfy(isLegacyLocalhostEndpointKey) {
                    let ports = endpoints.compactMap(legacyLocalhostPort).map(String.init).joined(separator: ", ")
                    issues.append(issue(service, "replicas cannot share fixed localhost ports: \(ports)."))
                } else {
                    issues.append(
                        issue(
                            service,
                            "replicas cannot share fixed published endpoints: \(endpoints.joined(separator: ", "))."
                        )
                    )
                }
            }

            for port in uniquePorts {
                ownersByEndpoint[port, default: []].insert(service.name)
            }

            let counts = Dictionary(
                grouping: publishedPorts,
                by: \.key
            ).mapValues(\.count)
            for port in counts.keys.sorted() where counts[port, default: 0] > 1 {
                let message = if isLegacyLocalhostEndpointKey(port), let localhostPort = legacyLocalhostPort(port) {
                    "publishes fixed localhost port \(localhostPort) more than once."
                } else {
                    "publishes fixed port \(port) more than once."
                }
                issues.append(issue(service, message))
            }
        }

        for port in ownersByEndpoint.keys.sorted() {
            let owners = ownersByEndpoint[port, default: []].sorted()
            guard owners.count > 1 else { continue }
            let message = if isLegacyLocalhostEndpointKey(port), let localhostPort = legacyLocalhostPort(port) {
                "Fixed localhost port \(localhostPort) is published by multiple services: \(owners.joined(separator: ", "))."
            } else {
                "Fixed port \(port) is published by multiple services: \(owners.joined(separator: ", "))."
            }
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: message
                )
            )
        }
    }

    private static func validatePublishedSocket(
        _ socket: HostwrightPublishedSocket,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if !isNormalizedAbsoluteContainerPath(socket.containerPath) ||
            socket.containerPath.contains(":") ||
            socket.containerPath.utf8.count > 107 {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Service '\(serviceName)' Unix socket target must be a normalized absolute container path of at most 107 UTF-8 bytes without ':'."
                )
            )
        }
        guard let hostName = socket.hostName else {
            return
        }
        let allowed = hostName.unicodeScalars.allSatisfy {
            CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            ).contains($0)
        }
        if hostName.isEmpty ||
            hostName == "." ||
            hostName == ".." ||
            hostName.utf8.count > Int(NAME_MAX) ||
            !allowed {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Service '\(serviceName)' Unix socket host name must be one safe filename using letters, digits, '.', '_', or '-'."
                )
            )
        }
    }

    private static func validatePublishedSocketCollisions(
        _ services: [HostwrightService],
        issues: inout [ManifestIssue]
    ) {
        var ownersByHostName: [String: Set<String>] = [:]
        for service in services.sorted(by: { $0.name < $1.name }) {
            let hostNames = service.publishedSockets.compactMap(\.hostName)
            if service.replicas > 1, let hostName = hostNames.sorted().first {
                issues.append(
                    issue(
                        service,
                        "replicas cannot share fixed Unix socket host name '\(hostName)'."
                    )
                )
            }
            for hostName in hostNames {
                ownersByHostName[hostName, default: []].insert(service.name)
            }
        }
        for hostName in ownersByHostName.keys.sorted() {
            let owners = ownersByHostName[hostName, default: []].sorted()
            guard owners.count > 1 else { continue }
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message:
                        "Unix socket host name '\(hostName)' is published by multiple services: \(owners.joined(separator: ", "))."
                )
            )
        }
    }

    private static func stablePublishedPortKey(_ port: HostwrightPublishedPort) -> String {
        [
            port.effectiveBindAddress,
            port.protocolName.rawValue,
            port.host?.canonicalString ?? "dynamic",
            port.target.canonicalString
        ].joined(separator: "|")
    }

    private static func stablePublishedSocketKey(
        _ socket: HostwrightPublishedSocket
    ) -> String {
        [
            socket.hostName ?? "automatic",
            socket.containerPath,
            socket.mode.rawValue
        ].joined(separator: "|")
    }

    private static func publishedSocketHostKey(
        _ socket: HostwrightPublishedSocket
    ) -> String {
        socket.hostName ?? "automatic:\(socket.containerPath)"
    }

    private static func expandedPublishedEndpoints(_ ports: [HostwrightPublishedPort]) -> [(key: String, summary: String)] {
        ports.flatMap { port in
            guard let hostRange = port.hostPortRange else {
                return [(key: String, summary: String)]()
            }
            return hostRange.map { hostPort in
                (
                    key: "\(port.protocolName.rawValue)://\(port.effectiveBindAddress):\(hostPort)",
                    summary: publishedPortSummary(port, preferLegacy: false)
                )
            }
        }
    }

    private static func publishedPortSummary(_ port: HostwrightPublishedPort, preferLegacy: Bool) -> String {
        if preferLegacy, let legacy = port.canonicalLegacyLiteral {
            return legacy.split(separator: ":").first.map(String.init) ?? legacy
        }
        let host = port.host?.canonicalString ?? "dynamic"
        return "\(port.protocolName.rawValue)://\(port.effectiveBindAddress):\(host)->\(port.target.canonicalString)"
    }

    private static func isLegacyLocalhostEndpointKey(_ key: String) -> Bool {
        key.hasPrefix("tcp://\(HostwrightPublishedPort.localhostBindAddress):")
    }

    private static func legacyLocalhostPort(_ key: String) -> Int? {
        guard isLegacyLocalhostEndpointKey(key) else { return nil }
        return Int(key.split(separator: ":").last ?? "")
    }

    private static func isValidBindAddress(_ value: String) -> Bool {
        if isValidIPv4Address(value) || isValidIPv6Address(value) {
            return true
        }
        return false
    }

    private static func isLoopbackBindAddress(_ value: String) -> Bool {
        value == "::1" || value == "127.0.0.1"
    }

    private static func isValidIPv4Address(_ value: String) -> Bool {
        var storage = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &storage) } == 1
    }

    private static func isValidIPv6Address(_ value: String) -> Bool {
        var storage = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &storage) } == 1
    }

    private static func validateVolume(_ volume: String, serviceName: String, issues: inout [ManifestIssue]) {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].hasPrefix("/")
        else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' volume '\(volume)' must use source:/absolute/container/path[:ro|rw]."
                )
            )
            return
        }
        if parts.count == 3 && parts[2] != "ro" && parts[2] != "rw" {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' mode must be ro or rw."))
        }
        let source = String(parts[0])
        if HostwrightPathPolicy.isHostRootMountSource(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' must not mount the host root."))
        }
        if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' source must not contain parent-directory traversal."))
        }
        if !isNormalizedAbsoluteContainerPath(String(parts[1])) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' container path must be normalized."))
        }
    }

    private static func validateMount(
        _ mount: HostwrightMountSpec,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let source = mount.source
        guard isNormalizedAbsoluteContainerPath(mount.target) else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' mount target '\(mount.target)' must be a normalized absolute container path."
                )
            )
            return
        }

        switch mount.kind {
        case .bind:
            guard let source, !source.isEmpty else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount requires source."
                    )
                )
                return
            }
            if HostwrightPathPolicy.isHostRootMountSource(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount source '\(source)' must not mount the host root."
                    )
                )
            }
            if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mount source '\(source)' must not contain parent-directory traversal."
                    )
                )
            }
            if mount.mode != nil || mount.size != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' bind mounts accept only source, target, and readOnly."
                    )
                )
            }
        case .volume:
            guard let source, !source.isEmpty else {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mount requires source."
                    )
                )
                return
            }
            if source.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: String.CompareOptions.regularExpression) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mount source '\(source)' must be a bounded safe name."
                    )
                )
            }
            if mount.mode != nil || mount.size != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' volume mounts accept only source, target, and readOnly."
                    )
                )
            }
        case .tmpfs:
            if mount.source != nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' tmpfs mounts must not declare source."
                    )
                )
            }
            if let size = mount.size {
                validateSize(size, field: "mount.size", service: HostwrightService(name: serviceName, image: nil), issues: &issues)
            }
            if let mode = mount.mode,
               mode.range(of: #"^[0-7]{3,4}$"#, options: .regularExpression) == nil {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Service '\(serviceName)' tmpfs mount mode must be a three- or four-digit octal string."
                    )
                )
            }
        }
    }

    private static func validateEnvironmentKey(_ key: String, serviceName: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        if key.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' must use shell-safe letters, numbers, and underscores, and must not start with a number."
                )
            )
        }
    }

    private static func validateLiteralEnvironmentValue(
        key: String,
        value: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if HostwrightSecretProviderKind.allCases.contains(where: {
            value.hasPrefix("\($0.rawValue)://")
        }) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' uses a secret reference in env; move it to secretEnv."
                )
            )
        }
        if SecretNamePolicy.requiresSecretReferenceEnvironmentKey(key) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' looks sensitive; plaintext sensitive values must use secretEnv."
                )
            )
        }
    }

    private static func validateSecretEnvironmentReference(
        key: String,
        reference: HostwrightSecretReference,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        do {
            _ = try HostwrightSecretReference.parse(reference.rawValue)
        } catch {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' secretEnv key '\(key)' must use one of: keychain://<service>/<account>, env-file:///absolute/path#KEY, local-file:///absolute/path, external://<provider>/<item>, or plugin://<provider>/<item>."
                )
            )
        }
    }

    private static func validateLabels(
        _ labels: [String: String],
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if labels.count > 256 {
            issues.append(issue(service, "labels exceed the limit of 256 entries."))
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("dev.hostwright.") {
                issues.append(issue(service, "label '\(key)' uses the reserved Hostwright ownership prefix."))
            }
            validateBounded(key, maximum: 128, field: "label key", service: service, issues: &issues)
            validateBounded(value, maximum: 4_096, field: "label '\(key)'", service: service, issues: &issues)
        }
    }

    private static func validateVolumeLabels(
        _ labels: [String: String],
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        if labels.count > 256 {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' labels exceed the limit of 256 entries."
                )
            )
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("dev.hostwright.") {
                issues.append(
                    ManifestIssue(
                        code: .manifestValidationFailed,
                        message: "Volume '\(volumeName)' label '\(key)' uses the reserved Hostwright ownership prefix."
                    )
                )
            }
            validateVolumeBounded(key, maximum: 128, field: "label key", volumeName: volumeName, issues: &issues)
            validateVolumeBounded(value, maximum: 4_096, field: "label '\(key)'", volumeName: volumeName, issues: &issues)
        }
    }

    private static func validateVolumeProvider(
        _ provider: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        validateVolumeBounded(provider, maximum: 128, field: "provider", volumeName: volumeName, issues: &issues)
        if provider.range(
            of: #"^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$"#,
            options: .regularExpression
        ) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' provider '\(provider)' must be a bounded stable provider ID."
                )
            )
        }
    }

    private static func validateVolumeCapacity(
        _ capacity: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        let pattern = #"^[1-9][0-9]*(B|KiB|MiB|GiB|TiB)$"#
        guard capacity.range(of: pattern, options: .regularExpression) != nil else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' capacity must be a normalized positive size such as 512MiB."
                )
            )
            return
        }
        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: { capacity.hasSuffix($0.0) }),
              let count = UInt64(capacity.dropLast(suffix.count)),
              !count.multipliedReportingOverflow(by: multiplier).overflow else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' capacity exceeds UInt64 byte capacity."
                )
            )
            return
        }
    }

    private static func validateHealth(
        _ health: HostwrightHealthCheck,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if health.command.isEmpty {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' health command must not be empty when health is present."))
        }
        if let interval = health.interval {
            validatePositiveDuration(interval, field: "health interval", serviceName: serviceName, issues: &issues)
        }
    }

    private static func validateProbe(
        _ probe: HostwrightProbe?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let probe else { return }
        switch probe.action {
        case .exec(let command):
            if command.isEmpty {
                issues.append(issue(service, "probes.\(name).exec must not be empty."))
            }
            validateCommand(command, field: "probes.\(name).exec", service: service, issues: &issues)
        case .http(let port, let path):
            validateProbePort(port, name: name, service: service, issues: &issues)
            if !isNormalizedAbsoluteContainerPath(path) {
                issues.append(issue(service, "probes.\(name).http.path must be a normalized absolute loopback path."))
            }
        case .tcp(let port):
            validateProbePort(port, name: name, service: service, issues: &issues)
        }
        if probe.startPeriod < 0 || probe.interval <= 0 || probe.timeout <= 0
            || probe.successThreshold <= 0 || probe.failureThreshold <= 0 {
            issues.append(issue(service, "probes.\(name) timing and thresholds must be positive; startPeriod may be zero."))
        }
    }

    private static func validateProbePort(
        _ port: Int,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let declaredTargets = Set(service.publishedPorts.flatMap { Array($0.containerPortRange) })
        if !isValidPort(port) || !declaredTargets.contains(port) {
            issues.append(issue(service, "probes.\(name) port \(port) must reference a declared service container port."))
        }
    }

    private static func validateRestart(
        _ restart: HostwrightRestart,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let allowed = ["no", "on-failure", "unless-stopped"]
        if !allowed.contains(restart.policy) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart policy must be one of: \(allowed.joined(separator: ", "))."))
        }
        if !(1...100).contains(restart.maxAttempts) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart.maxAttempts must be between 1 and 100."))
        }
        if !(1...86_400).contains(restart.window) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart.window must be between 1s and 24h."))
        }
        if !(1...3_600).contains(restart.backoff) ||
            !(restart.backoff...86_400).contains(restart.maxBackoff) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart backoff must be 1s...1h and maxBackoff must be between backoff and 24h."))
        }
        if !(0...restart.backoff).contains(restart.jitter) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart.jitter must be between zero and backoff."))
        }
        if !(1...86_400).contains(restart.stableRun) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart.stableRun must be between 1s and 24h."))
        }
        if !(-100...100).contains(restart.priority) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart.priority must be between -100 and 100."))
        }
    }

    private static func validateProjectRestartBudget(
        _ budget: HostwrightProjectRestartBudget?,
        issues: inout [ManifestIssue]
    ) {
        guard let budget else { return }
        if !(1...1_000).contains(budget.maxAttempts) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "restartBudget.maxAttempts must be between 1 and 1000.", path: "$.restartBudget.maxAttempts"))
        }
        if !(1...86_400).contains(budget.window) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "restartBudget.window must be between 1s and 24h.", path: "$.restartBudget.window"))
        }
    }

    private static func validateMaintenance(
        _ policy: HostwrightMaintenancePolicy?,
        issues: inout [ManifestIssue]
    ) {
        guard let policy else { return }
        guard TimeZone(identifier: policy.timezone) != nil else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "maintenance.timezone must name an installed IANA timezone.", path: "$.maintenance.timezone"))
            return
        }
        if !(60...2_592_000).contains(policy.maximumDeferral) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "maintenance.maximumDeferral must be between 60s and 30 days.", path: "$.maintenance.maximumDeferral"))
        }
        if policy.windows.isEmpty || policy.windows.count > HostwrightMaintenanceWindow.maximumWindows {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "maintenance.windows must contain 1 through 64 windows.", path: "$.maintenance.windows"))
        }
        let ids = policy.windows.map(\.id)
        if Set(ids).count != ids.count {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "maintenance window ids must be unique.", path: "$.maintenance.windows"))
        }
        let formatter = ISO8601DateFormatter()
        for (index, window) in policy.windows.enumerated() {
            let path = "$.maintenance.windows[\(index)]"
            if window.id.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) == nil {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Maintenance window ids must use bounded lowercase names.", path: "\(path).id"))
            }
            if window.actions.isEmpty || Set(window.actions).count != window.actions.count || window.actions.contains(where: { !$0.isElective }) {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Maintenance window actions must be a non-empty unique elective set.", path: "\(path).actions"))
            }
            switch window.schedule {
            case .recurring(let recurring):
                if recurring.weekdays.isEmpty || Set(recurring.weekdays).count != recurring.weekdays.count {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Recurring maintenance weekdays must be non-empty and unique.", path: "\(path).recurring.weekdays"))
                }
                if recurring.start.range(of: "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) == nil {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Recurring maintenance start must be canonical 24-hour HH:mm.", path: "\(path).recurring.start"))
                }
                if !(60...86_400).contains(recurring.duration) {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Recurring maintenance duration must be between 60s and 24h.", path: "\(path).recurring.duration"))
                }
            case .oneShot(let oneShot):
                if formatter.date(from: oneShot.startsAt) == nil || formatter.string(from: formatter.date(from: oneShot.startsAt) ?? Date()) != oneShot.startsAt {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "One-shot maintenance startsAt must be canonical RFC3339 UTC.", path: "\(path).oneShot.startsAt"))
                }
                if !(60...86_400).contains(oneShot.duration) {
                    issues.append(ManifestIssue(code: .manifestValidationFailed, message: "One-shot maintenance duration must be between 60s and 24h.", path: "\(path).oneShot.duration"))
                }
            }
        }
    }

    private static func validateUpdate(
        _ update: HostwrightUpdatePolicy,
        replicas: Int,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if update.maxSurge < 0 || update.maxUnavailable < 0 {
            issues.append(issue(service, "update maxSurge and maxUnavailable must be non-negative."))
        }
        if update.strategy == .rolling && update.maxSurge == 0 && update.maxUnavailable == 0 {
            issues.append(issue(service, "rolling update requires maxSurge or maxUnavailable to be positive."))
        }
        if update.maxUnavailable > replicas {
            issues.append(issue(service, "update.maxUnavailable must not exceed replicas."))
        }
        if update.progressDeadline <= 0 {
            issues.append(issue(service, "update.progressDeadline must be positive."))
        }
    }

    private static func validateHook(
        _ hook: [String]?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let hook else { return }
        if hook.isEmpty {
            issues.append(issue(service, "hooks.\(name).exec must not be empty."))
        }
        validateCommand(hook, field: "hooks.\(name).exec", service: service, issues: &issues)
    }

    private static func validateSize(
        _ value: String,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let pattern = #"^[1-9][0-9]*(B|KiB|MiB|GiB|TiB)$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            issues.append(issue(service, "\(field) must be a normalized positive size such as 512MiB."))
            return
        }

        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: {
            value.hasSuffix($0.0)
        }),
            let count = UInt64(value.dropLast(suffix.count)),
            !count.multipliedReportingOverflow(by: multiplier).overflow else {
            issues.append(issue(service, "\(field) exceeds UInt64 byte capacity."))
            return
        }
    }

    private static func validateBounded(
        _ value: String,
        maximum: Int,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if value.utf8.count > maximum {
            issues.append(issue(service, "\(field) exceeds \(maximum) UTF-8 bytes."))
        }
    }

    private static func validateVolumeBounded(
        _ value: String,
        maximum: Int,
        field: String,
        volumeName: String,
        issues: inout [ManifestIssue]
    ) {
        if value.utf8.count > maximum {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Volume '\(volumeName)' \(field) exceeds \(maximum) UTF-8 bytes."
                )
            )
        }
    }

    private static func validatePositiveDuration(
        _ duration: String,
        field: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        guard duration.hasSuffix("s"),
              let seconds = Int(duration.dropLast()),
              seconds > 0,
              String(seconds) == duration.dropLast()
        else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' \(field) must be a positive seconds value like 10s."))
            return
        }
    }

    private static func isNormalizedAbsoluteContainerPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("//") else {
            return value == "/"
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isNormalizedAbsoluteHostPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value != "/",
              !value.contains("//"),
              !value.contains("/./"),
              !value.hasSuffix("/."),
              !value.contains("/../"),
              !value.hasSuffix("/..") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isExactHTTPSURL(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        return components.url?.absoluteString == value
    }

    private static func isBoundedProvenanceURI(_ value: String) -> Bool {
        let hasAllowedScheme =
            (value.hasPrefix("https://") && value.utf8.count > "https://".utf8.count) ||
            (value.hasPrefix("urn:") && value.utf8.count > "urn:".utf8.count)
        return hasAllowedScheme &&
            value.utf8.count <= HostwrightImageProvenancePolicy.maximumURIUTF8Bytes &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !value.contains("@") &&
            !value.contains("..") &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.utf8.count <= 512 &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isExactPackagePURL(_ value: String) -> Bool {
        value.hasPrefix("pkg:") &&
            value.utf8.count <= 1_024 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.dropFirst(4).contains("/") &&
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isBoundedPolicyText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximum &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private enum NetworkAddressFamily: Equatable {
        case ipv4
        case ipv6

        var field: String {
            switch self {
            case .ipv4: return "ipv4"
            case .ipv6: return "ipv6"
            }
        }

        var label: String {
            switch self {
            case .ipv4: return "IPv4"
            case .ipv6: return "IPv6"
            }
        }

        var byteCount: Int {
            switch self {
            case .ipv4: return 4
            case .ipv6: return 16
            }
        }

        var addressFamily: Int32 {
            switch self {
            case .ipv4: return AF_INET
            case .ipv6: return AF_INET6
            }
        }
    }

    private struct NetworkCIDR {
        let family: NetworkAddressFamily
        let prefixLength: Int
        let addressBytes: [UInt8]
        let canonicalAddress: String

        init?(_ rawValue: String, family: NetworkAddressFamily) {
            guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
                  rawValue.utf8.count <= 128 else {
                return nil
            }
            let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  let prefixLength = Int(parts[1]),
                  String(prefixLength) == String(parts[1]),
                  (0...(family.byteCount * 8)).contains(prefixLength) else {
                return nil
            }

            var addressBytes = [UInt8](repeating: 0, count: family.byteCount)
            let parsed = String(parts[0]).withCString { address in
                addressBytes.withUnsafeMutableBytes { storage in
                    inet_pton(family.addressFamily, address, storage.baseAddress)
                }
            }
            guard parsed == 1,
                  let canonicalAddress = Self.render(addressBytes, family: family) else {
                return nil
            }
            self.family = family
            self.prefixLength = prefixLength
            self.addressBytes = addressBytes
            self.canonicalAddress = canonicalAddress
        }

        var canonicalValue: String {
            "\(canonicalAddress)/\(prefixLength)"
        }

        var networkBytes: [UInt8] {
            Self.mask(addressBytes, prefixLength: prefixLength)
        }

        var canonicalNetworkValue: String {
            let address = Self.render(networkBytes, family: family) ?? canonicalAddress
            return "\(address)/\(prefixLength)"
        }

        var isNetworkAddress: Bool {
            addressBytes == networkBytes
        }

        func overlaps(_ other: NetworkCIDR) -> Bool {
            guard family == other.family else { return false }
            let sharedPrefixLength = min(prefixLength, other.prefixLength)
            return Self.mask(addressBytes, prefixLength: sharedPrefixLength) ==
                Self.mask(other.addressBytes, prefixLength: sharedPrefixLength)
        }

        private static func mask(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
            var result = bytes
            let completeBytes = prefixLength / 8
            let remainingBits = prefixLength % 8
            for index in result.indices {
                if index < completeBytes {
                    continue
                }
                if index == completeBytes, remainingBits > 0 {
                    result[index] &= UInt8.max << UInt8(8 - remainingBits)
                } else {
                    result[index] = 0
                }
            }
            return result
        }

        private static func render(
            _ bytes: [UInt8],
            family: NetworkAddressFamily
        ) -> String? {
            var buffer = [CChar](
                repeating: 0,
                count: family == .ipv4 ? Int(INET_ADDRSTRLEN) : Int(INET6_ADDRSTRLEN)
            )
            let rendered = bytes.withUnsafeBytes { source in
                buffer.withUnsafeMutableBufferPointer { destination in
                    inet_ntop(
                        family.addressFamily,
                        source.baseAddress,
                        destination.baseAddress,
                        socklen_t(destination.count)
                    )
                }
            }
            guard rendered != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func isValidCIDR(
        _ rawValue: String,
        family: NetworkAddressFamily
    ) -> Bool {
        NetworkCIDR(rawValue, family: family) != nil
    }

    private static func issue(_ service: HostwrightService, _ message: String) -> ManifestIssue {
        ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' \(message)")
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }
}
