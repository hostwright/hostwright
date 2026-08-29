import Foundation
import HostwrightNetworking

public enum ManifestCanonicalEncoder {
    public static func encode(_ manifest: HostwrightManifest) throws -> String {
        let issues = ManifestValidator.validate(manifest)
        guard issues.isEmpty else {
            throw ManifestParseError.failed(issues)
        }

        var lines = [
            "version: \(HostwrightManifest.currentVersion)",
            "project: \(quote(manifest.project ?? ""))"
        ]
        if let restartBudget = manifest.restartBudget {
            lines.append("restartBudget:")
            lines.append("  maxAttempts: \(restartBudget.maxAttempts)")
            lines.append("  window: \(quote("\(restartBudget.window)s"))")
        }
        if let maintenance = manifest.maintenance {
            lines.append("maintenance:")
            lines.append("  timezone: \(quote(maintenance.timezone))")
            lines.append("  maximumDeferral: \(quote("\(maintenance.maximumDeferral)s"))")
            lines.append("  windows:")
            for window in maintenance.windows.sorted(by: { $0.id < $1.id }) {
                lines.append("    - id: \(quote(window.id))")
                lines.append("      actions:")
                for action in window.actions.sorted(by: { $0.rawValue < $1.rawValue }) {
                    lines.append("        - \(quote(action.rawValue))")
                }
                switch window.schedule {
                case .recurring(let recurring):
                    lines.append("      recurring:")
                    lines.append("        weekdays:")
                    for weekday in recurring.weekdays.sorted(by: { $0.rawValue < $1.rawValue }) {
                        lines.append("          - \(quote(weekday.rawValue))")
                    }
                    lines.append("        start: \(quote(recurring.start))")
                    lines.append("        duration: \(quote("\(recurring.duration)s"))")
                case .oneShot(let oneShot):
                    lines.append("      oneShot:")
                    lines.append("        startsAt: \(quote(oneShot.startsAt))")
                    lines.append("        duration: \(quote("\(oneShot.duration)s"))")
                }
            }
        }
        if let retention = manifest.retention {
            lines.append("retention:")
            lines.append("  recoveryHorizon: \(quote("\(retention.recoveryHorizon)s"))")
            lines.append("  maximumDatabaseBytes: \(retention.maximumDatabaseBytes)")
            lines.append("  targetDatabaseBytes: \(retention.targetDatabaseBytes)")
            lines.append("  classes:")
            for retentionClass in HostwrightRetentionClass.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let policy = retention.classes[retentionClass] else { continue }
                lines.append("    \(retentionClass.rawValue):")
                lines.append("      maxAge: \(quote("\(policy.maxAge)s"))")
                lines.append("      maxRecords: \(policy.maxRecords)")
                lines.append("      minimumRecords: \(policy.minimumRecords)")
            }
            if !retention.holds.isEmpty {
                lines.append("  holds:")
                for hold in retention.holds.sorted(by: { $0.id < $1.id }) {
                    lines.append("    - id: \(quote(hold.id))")
                    lines.append("      class: \(quote(hold.retentionClass.rawValue))")
                    lines.append("      selector: \(quote(hold.selector))")
                    lines.append("      reason: \(quote(hold.reason))")
                    if let expiresAt = hold.expiresAt {
                        lines.append("      expiresAt: \(quote(expiresAt))")
                    }
                }
            }
        }
        if let imagePolicy = manifest.imagePolicy {
            lines.append("imagePolicy: \(quote(imagePolicy.rawValue))")
        }
        if let imageTrust = manifest.imageTrust {
            lines.append("imageTrust:")
            lines.append("  version: \(imageTrust.version)")
            lines.append("  threshold: \(imageTrust.threshold)")
            if let trustedRoot = imageTrust.trustedRoot {
                lines.append("  trustedRoot: \(quote(trustedRoot))")
            }
            lines.append("  authorities:")
            for authority in imageTrust.authorities.sorted(by: { $0.id < $1.id }) {
                lines.append("    - id: \(quote(authority.id))")
                lines.append("      type: \(quote(authority.type.rawValue))")
                switch authority.type {
                case .keyed:
                    if let publicKey = authority.publicKey {
                        lines.append("      publicKey: \(quote(publicKey))")
                    }
                case .keyless:
                    if let issuer = authority.issuer {
                        lines.append("      issuer: \(quote(issuer))")
                    }
                    if let identity = authority.identity {
                        lines.append("      identity: \(quote(identity))")
                    }
                }
                if let notBefore = authority.notBefore {
                    lines.append("      notBefore: \(quote(notBefore))")
                }
                if let notAfter = authority.notAfter {
                    lines.append("      notAfter: \(quote(notAfter))")
                }
                if let revokedAt = authority.revokedAt {
                    lines.append("      revokedAt: \(quote(revokedAt))")
                }
            }
        }
        if let imageSBOM = manifest.imageSBOM {
            lines.append("imageSBOM:")
            lines.append("  version: \(imageSBOM.version)")
            lines.append("  requirement: \(quote(imageSBOM.requirement.rawValue))")
            lines.append("  formats:")
            for format in imageSBOM.formats.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("    - \(quote(format.rawValue))")
            }
        }
        if let imageVulnerability = manifest.imageVulnerability {
            lines.append("imageVulnerability:")
            lines.append("  version: \(imageVulnerability.version)")
            lines.append("  severityThreshold: \(quote(imageVulnerability.severityThreshold.rawValue))")
            lines.append("  minimumVulnerabilityAgeSeconds: \(imageVulnerability.minimumVulnerabilityAgeSeconds)")
            lines.append("  exploitability: \(quote(imageVulnerability.exploitability.rawValue))")
            lines.append("  fixAvailability: \(quote(imageVulnerability.fixAvailability.rawValue))")
            lines.append("  maximumDatabaseAgeSeconds: \(imageVulnerability.maximumDatabaseAgeSeconds)")
            lines.append("  staleAction: \(quote(imageVulnerability.staleAction.rawValue))")
            lines.append("  unavailableAction: \(quote(imageVulnerability.unavailableAction.rawValue))")
            lines.append("  exceptionApproval: \(quote(imageVulnerability.exceptionApproval.rawValue))")
            if !imageVulnerability.allowlist.isEmpty {
                lines.append("  allowlist:")
                let entries = imageVulnerability.allowlist.sorted { lhs, rhs in
                    if lhs.vulnerabilityID != rhs.vulnerabilityID {
                        return lhs.vulnerabilityID < rhs.vulnerabilityID
                    }
                    if lhs.packagePURL != rhs.packagePURL {
                        return (lhs.packagePURL ?? "") < (rhs.packagePURL ?? "")
                    }
                    if lhs.expiresAt != rhs.expiresAt {
                        return lhs.expiresAt < rhs.expiresAt
                    }
                    return lhs.reason < rhs.reason
                }
                for entry in entries {
                    lines.append("    - vulnerabilityID: \(quote(entry.vulnerabilityID))")
                    if let packagePURL = entry.packagePURL {
                        lines.append("      packagePURL: \(quote(packagePURL))")
                    }
                    lines.append("      reason: \(quote(entry.reason))")
                    lines.append("      expiresAt: \(quote(entry.expiresAt))")
                }
            }
        }
        if let imageProvenance = manifest.imageProvenance {
            lines.append("imageProvenance:")
            lines.append("  version: \(imageProvenance.version)")
            lines.append("  requirement: \(quote(imageProvenance.requirement.rawValue))")
            lines.append("  builderIDs:")
            for builderID in imageProvenance.builderIDs.sorted() {
                lines.append("    - \(quote(builderID))")
            }
            lines.append("  buildTypes:")
            for buildType in imageProvenance.buildTypes.sorted() {
                lines.append("    - \(quote(buildType))")
            }
            lines.append("  signers:")
            for signer in imageProvenance.signers.sorted(by: { $0.id < $1.id }) {
                lines.append("    - id: \(quote(signer.id))")
                lines.append("      publicKey: \(quote(signer.publicKey))")
                if let notBefore = signer.notBefore {
                    lines.append("      notBefore: \(quote(notBefore))")
                }
                if let notAfter = signer.notAfter {
                    lines.append("      notAfter: \(quote(notAfter))")
                }
                if let revokedAt = signer.revokedAt {
                    lines.append("      revokedAt: \(quote(revokedAt))")
                }
            }
            lines.append("  maximumAgeSeconds: \(imageProvenance.maximumAgeSeconds)")
            lines.append("  requireReproducible: \(imageProvenance.requireReproducible)")
        }
        appendVolumeDeclarations(manifest.volumes, to: &lines)
        appendNetworkDefinitions(manifest.networks, to: &lines)
        appendCertificateDeclarations(manifest.certificates, to: &lines)
        appendIngress(manifest.ingress, to: &lines)
        appendTunnels(manifest.tunnels, to: &lines)
        lines.append("services:")

        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            lines.append("  \(quote(service.name)):")
            if let image = service.image {
                lines.append("    image: \(quote(image))")
            }
            if service.replicas != 1 {
                lines.append("    replicas: \(service.replicas)")
            }
            if service.platform != HostwrightPlatform() {
                lines.append("    platform:")
                lines.append("      os: \(quote(service.platform.os.rawValue))")
                lines.append("      architecture: \(quote(service.platform.architecture.rawValue))")
            }
            if let resources = service.resources {
                if resources.requests.isEmpty && resources.limits == nil {
                    lines.append("    resources: {}")
                } else {
                    lines.append("    resources:")
                    appendResourceSet(resources.requests, key: "requests", indent: 6, to: &lines)
                    if let limits = resources.limits {
                        appendResourceSet(limits, key: "limits", indent: 6, to: &lines)
                    }
                }
            }
            if let scheduling = service.scheduling {
                appendScheduling(scheduling, to: &lines)
            }
            if let user = service.user {
                lines.append("    user: \(user)")
            }
            if let group = service.group {
                lines.append("    group: \(group)")
            }
            if let workdir = service.workdir {
                lines.append("    workdir: \(quote(workdir))")
            }
            appendArray(service.entrypoint, key: "entrypoint", indent: 4, to: &lines)
            appendArray(service.command, key: "command", indent: 4, to: &lines)
            if service.initProcess {
                lines.append("    init: true")
            }
            appendEnumMap(service.dependsOn, key: "dependsOn", to: &lines)
            appendStringMap(service.env, key: "env", to: &lines)
            appendStringMap(
                service.secretEnv.mapValues { $0.rawValue },
                key: "secretEnv",
                to: &lines
            )
            appendStringMap(service.labels, key: "labels", to: &lines)
            appendPublishedEndpoints(
                ports: service.publishedPorts,
                sockets: service.publishedSockets,
                to: &lines
            )
            appendHostAccess(service.hostAccess, to: &lines)
            appendServiceNetworks(service.networks, to: &lines)
            appendNetworkPolicy(service.networkPolicy, to: &lines)
            appendMounts(service.mounts, to: &lines)

            let probes = canonicalProbes(for: service)
            if probes.startup != nil || probes.readiness != nil || probes.liveness != nil {
                lines.append("    probes:")
                appendProbe(probes.startup, name: "startup", to: &lines)
                appendProbe(probes.readiness, name: "readiness", to: &lines)
                appendProbe(probes.liveness, name: "liveness", to: &lines)
            }
            if let restart = service.restart {
                lines.append("    restart:")
                lines.append("      policy: \(quote(restart.policy))")
                if restart.maxAttempts != 3 {
                    lines.append("      maxAttempts: \(restart.maxAttempts)")
                }
                if restart.window != 300 {
                    lines.append("      window: \(quote("\(restart.window)s"))")
                }
                if restart.backoff != 60 {
                    lines.append("      backoff: \(quote("\(restart.backoff)s"))")
                }
                if restart.maxBackoff != 300 {
                    lines.append("      maxBackoff: \(quote("\(restart.maxBackoff)s"))")
                }
                if restart.jitter != 0 {
                    lines.append("      jitter: \(quote("\(restart.jitter)s"))")
                }
                if restart.stableRun != 60 {
                    lines.append("      stableRun: \(quote("\(restart.stableRun)s"))")
                }
                if restart.priority != 0 {
                    lines.append("      priority: \(restart.priority)")
                }
            }
            if service.update != HostwrightUpdatePolicy() {
                lines.append("    update:")
                lines.append("      strategy: \(quote(service.update.strategy.rawValue))")
                lines.append("      maxSurge: \(service.update.maxSurge)")
                lines.append("      maxUnavailable: \(service.update.maxUnavailable)")
                lines.append("      progressDeadline: \(quote("\(service.update.progressDeadline)s"))")
                if service.update.stableObservation != 0 {
                    lines.append("      stableObservation: \(quote("\(service.update.stableObservation)s"))")
                }
            }
            if service.hooks.postStart != nil || service.hooks.preStop != nil {
                lines.append("    hooks:")
                appendHook(service.hooks.postStart, name: "postStart", to: &lines)
                appendHook(service.hooks.preStop, name: "preStop", to: &lines)
            }
            if service.rosetta {
                lines.append("    rosetta: true")
            }
            if service.virtualization {
                lines.append("    virtualization: true")
            }
            if service.readOnlyRootFilesystem {
                lines.append("    readOnlyRootFilesystem: true")
            }
            if let shmSize = service.shmSize {
                lines.append("    shmSize: \(quote(shmSize))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendVolumeDeclarations(
        _ volumes: [String: HostwrightVolumeDeclaration],
        to lines: inout [String]
    ) {
        guard !volumes.isEmpty else { return }
        lines.append("volumes:")
        for (name, volume) in volumes.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(quote(name)):")
            if volume.provider != HostwrightVolumeDeclaration.defaultProvider {
                lines.append("    provider: \(quote(volume.provider))")
            }
            lines.append("    capacity: \(quote(volume.capacity))")
            if volume.accessMode != .readWriteOnce {
                lines.append("    accessMode: \(quote(volume.accessMode.rawValue))")
            }
            if volume.reclaimPolicy != .retain {
                lines.append("    reclaimPolicy: \(quote(volume.reclaimPolicy.rawValue))")
            }
            appendStringMap(volume.labels, key: "labels", indent: 4, to: &lines)
        }
    }

    private static func appendResourceSet(
        _ values: HostwrightResourceSet,
        key: String,
        indent: Int,
        to lines: inout [String]
    ) {
        let prefix = String(repeating: " ", count: indent)
        if values.isEmpty {
            lines.append("\(prefix)\(key): {}")
            return
        }
        lines.append("\(prefix)\(key):")
        let valuePrefix = String(repeating: " ", count: indent + 2)
        if let cpus = values.cpus {
            lines.append("\(valuePrefix)cpus: \(cpus)")
        }
        if let memory = values.memory {
            lines.append("\(valuePrefix)memory: \(quote(memory))")
        }
        if let disk = values.disk {
            lines.append("\(valuePrefix)disk: \(quote(disk))")
        }
        if let io = values.io {
            lines.append("\(valuePrefix)io: \(quote(io))")
        }
        if let network = values.network {
            lines.append("\(valuePrefix)network: \(quote(network))")
        }
        if let process = values.process {
            lines.append("\(valuePrefix)process: \(process)")
        }
    }

    private static func appendScheduling(
        _ scheduling: HostwrightSchedulingPolicy,
        to lines: inout [String]
    ) {
        if scheduling.isEmpty {
            lines.append("    scheduling: {}")
            return
        }
        lines.append("    scheduling:")
        if scheduling.priority != 0 {
            lines.append("      priority: \(scheduling.priority)")
        }
        appendSelectors(scheduling.requiredAffinity, key: "requiredAffinity", to: &lines)
        appendPreferences(scheduling.preferredAffinity, key: "preferredAffinity", to: &lines)
        appendSelectors(scheduling.requiredAntiAffinity, key: "requiredAntiAffinity", to: &lines)
        appendPreferences(scheduling.preferredAntiAffinity, key: "preferredAntiAffinity", to: &lines)
        if !scheduling.topologySpread.isEmpty {
            lines.append("      topologySpread:")
            for spread in scheduling.topologySpread.sorted(by: {
                if $0.topologyKey != $1.topologyKey { return $0.topologyKey < $1.topologyKey }
                return $0.maxSkew < $1.maxSkew
            }) {
                lines.append("        - topologyKey: \(quote(spread.topologyKey))")
                if spread.maxSkew != 1 {
                    lines.append("          maxSkew: \(spread.maxSkew)")
                }
                if spread.whenUnsatisfiable != .doNotSchedule {
                    lines.append("          whenUnsatisfiable: \(quote(spread.whenUnsatisfiable.rawValue))")
                }
            }
        }
        if !scheduling.tolerations.isEmpty {
            lines.append("      tolerations:")
            for toleration in scheduling.tolerations.sorted(by: { tolerationKey($0) < tolerationKey($1) }) {
                lines.append("        - operator: \(quote(toleration.operator.rawValue))")
                if let key = toleration.key {
                    lines.append("          key: \(quote(key))")
                }
                if let value = toleration.value {
                    lines.append("          value: \(quote(value))")
                }
                if let effect = toleration.effect {
                    lines.append("          effect: \(quote(effect.rawValue))")
                }
            }
        }
        if let disruption = scheduling.disruption {
            lines.append("      disruption:")
            if let maxUnavailable = disruption.maxUnavailable {
                lines.append("        maxUnavailable: \(maxUnavailable)")
            }
            if let minAvailable = disruption.minAvailable {
                lines.append("        minAvailable: \(minAvailable)")
            }
        }
        if scheduling.preemption != .disabled {
            lines.append("      preemption: \(quote(scheduling.preemption.rawValue))")
        }
        if let provider = scheduling.provider {
            lines.append("      provider: \(quote(provider))")
        }
        if !scheduling.acceleratorClaims.isEmpty {
            lines.append("      acceleratorClaims:")
            for claim in scheduling.acceleratorClaims.sorted(by: {
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.count < $1.count
            }) {
                lines.append("        - name: \(quote(claim.name))")
                if claim.count != 1 {
                    lines.append("          count: \(claim.count)")
                }
            }
        }
    }

    private static func appendSelectors(
        _ selectors: [HostwrightSchedulingSelector],
        key: String,
        to lines: inout [String]
    ) {
        guard !selectors.isEmpty else { return }
        lines.append("      \(key):")
        for selector in selectors.sorted(by: selectorPrecedes) {
            lines.append("        - key: \(quote(selector.key))")
            lines.append("          operator: \(quote(selector.operator.rawValue))")
            if !selector.values.isEmpty {
                lines.append("          values:")
                for value in selector.values.sorted() {
                    lines.append("            - \(quote(value))")
                }
            }
        }
    }

    private static func appendPreferences(
        _ preferences: [HostwrightSchedulingPreference],
        key: String,
        to lines: inout [String]
    ) {
        guard !preferences.isEmpty else { return }
        lines.append("      \(key):")
        for preference in preferences.sorted(by: {
            if $0.weight != $1.weight { return $0.weight < $1.weight }
            return selectorKey($0.match) < selectorKey($1.match)
        }) {
            lines.append("        - weight: \(preference.weight)")
            lines.append("          key: \(quote(preference.match.key))")
            lines.append("          operator: \(quote(preference.match.operator.rawValue))")
            if !preference.match.values.isEmpty {
                lines.append("          values:")
                for value in preference.match.values.sorted() {
                    lines.append("            - \(quote(value))")
                }
            }
        }
    }

    private static func selectorPrecedes(
        _ lhs: HostwrightSchedulingSelector,
        _ rhs: HostwrightSchedulingSelector
    ) -> Bool {
        selectorKey(lhs) < selectorKey(rhs)
    }

    private static func selectorKey(_ selector: HostwrightSchedulingSelector) -> String {
        [selector.key, selector.operator.rawValue, selector.values.sorted().joined(separator: "\u{1f}")]
            .joined(separator: "\u{1e}")
    }

    private static func tolerationKey(_ toleration: HostwrightSchedulingToleration) -> String {
        [
            toleration.key ?? "",
            toleration.value ?? "",
            toleration.effect?.rawValue ?? "",
            toleration.operator.rawValue
        ].joined(separator: "\u{1e}")
    }

    private static func appendNetworkDefinitions(
        _ networks: [String: HostwrightNetworkDefinition],
        to lines: inout [String]
    ) {
        guard !networks.isEmpty else { return }
        lines.append("networks:")
        for (name, network) in networks.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(quote(name)):")
            let usesDefaults =
                network.driver == .nat &&
                network.ipv4 == .auto &&
                network.ipv6 == .auto
            if usesDefaults {
                lines.append("    {}")
                continue
            }
            if network.driver != .nat {
                lines.append("    driver: \(quote(network.driver.rawValue))")
            }
            if network.ipv4 != .auto {
                lines.append(
                    "    ipv4: \(quote(canonicalNetworkAddress(network.ipv4, ipv6: false)))"
                )
            }
            if network.ipv6 != .auto {
                lines.append(
                    "    ipv6: \(quote(canonicalNetworkAddress(network.ipv6, ipv6: true)))"
                )
            }
        }
    }

    private static func appendIngress(
        _ ingress: [String: HostwrightIngressListener],
        to lines: inout [String]
    ) {
        guard !ingress.isEmpty else { return }
        lines.append("ingress:")
        for (name, listener) in ingress.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(quote(name)):")
            if listener.bindAddress !=
                NetworkBindAddressPolicy.localhostBindAddress {
                lines.append(
                    "    bind: \(quote(listener.bindAddress))"
                )
            }
            if !listener.exposure.isDefaultLocalhost {
                lines.append("    exposure:")
                lines.append(
                    "      scope: \(quote(listener.exposure.scope.rawValue))"
                )
                lines.append(
                    "      interfaces: \(array(listener.exposure.interfaces))"
                )
                lines.append(
                    "      networkClasses: \(array(listener.exposure.networkClasses.map(\.rawValue)))"
                )
                lines.append(
                    "      allowedCIDRs: \(array(listener.exposure.allowedCIDRs))"
                )
                lines.append(
                    "      authentication: \(quote(listener.exposure.authentication.rawValue))"
                )
            }
            if let certificate = listener.certificate {
                lines.append("    certificate: \(quote(certificate))")
            }
            if !listener.peers.isEmpty {
                lines.append("    peers:")
                for peer in listener.peers.sorted(by: { ($0.service, $0.role.rawValue) < ($1.service, $1.role.rawValue) }) {
                    lines.append("      - service: \(quote(peer.service))")
                    lines.append("        role: \(quote(peer.role.rawValue))")
                }
            }
            lines.append("    port: \(listener.port)")
            lines.append("    routes:")
            for route in listener.routes.sorted(
                by: HostwrightIngressRoute.canonicalPrecedes
            ) {
                lines.append(
                    "      - hostname: \(quote(route.hostname))"
                )
                lines.append(
                    "        pathPrefix: \(quote(route.pathPrefix))"
                )
                lines.append(
                    "        methods: \(array(route.methods.sorted()))"
                )
                lines.append(
                    "        protocol: \(quote(route.protocolName.rawValue))"
                )
                lines.append(
                    "        targetService: \(quote(route.targetService))"
                )
                lines.append("        targetPort: \(route.targetPort)")
            }
        }
    }

    private static func appendTunnels(
        _ tunnels: [String: HostwrightTunnelDeclaration],
        to lines: inout [String]
    ) {
        guard !tunnels.isEmpty else { return }
        lines.append("tunnels:")
        for (name, tunnel) in tunnels.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(quote(name)):")
            lines.append("    targetService: \(quote(tunnel.targetService))")
            lines.append("    targetPort: \(tunnel.targetPort)")
            lines.append("    peerUUID: \(quote(tunnel.peerUUID))")
            if tunnel.role != .localLoopback {
                lines.append("    role: \(quote(tunnel.role.rawValue))")
            }
            if let trust = tunnel.trust {
                lines.append("    trust:")
                lines.append(
                    "      wireRouteUUID: \(quote(trust.wireRouteUUID))"
                )
                lines.append(
                    "      wireGeneration: \(trust.wireGeneration)"
                )
                lines.append(
                    "      localIdentitySHA256: \(quote(trust.localIdentitySHA256))"
                )
                lines.append(
                    "      peerTrustAnchorSHA256: \(quote(trust.peerTrustAnchorSHA256))"
                )
                lines.append(
                    "      peerCertificateSHA256: \(quote(trust.peerCertificateSHA256))"
                )
                if let peerDNSName = trust.peerDNSName {
                    lines.append(
                        "      peerDNSName: \(quote(peerDNSName))"
                    )
                }
                if let peerIdentityURI = trust.peerIdentityURI {
                    lines.append(
                        "      peerIdentityURI: \(quote(peerIdentityURI))"
                    )
                }
            }
            if let bind = tunnel.bindEndpoint {
                lines.append("    bindEndpoint:")
                lines.append("      host: \(quote(bind.host))")
                lines.append("      port: \(bind.port)")
            }
            if !tunnel.authenticatedEndpoints.isEmpty {
                lines.append("    authenticatedEndpoints:")
                for endpoint in tunnel.authenticatedEndpoints {
                    lines.append("      - scheme: \(quote(endpoint.scheme.rawValue))")
                    lines.append("        host: \(quote(endpoint.host))")
                    lines.append("        port: \(endpoint.port)")
                }
            }
            if let relay = tunnel.relayEndpoint {
                lines.append("    relayEndpoint:")
                lines.append("      scheme: \(quote(relay.scheme.rawValue))")
                lines.append("      host: \(quote(relay.host))")
                lines.append("      port: \(relay.port)")
            }
            if !tunnel.bonjourDiscovery {
                lines.append("    bonjourDiscovery: false")
            }
        }
    }

    private static func appendCertificateDeclarations(_ certificates: [String: HostwrightCertificateDeclaration], to lines: inout [String]) {
        guard !certificates.isEmpty else { return }
        lines.append("certificates:")
        for (name, certificate) in certificates.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(quote(name)):")
            lines.append("    source: \(quote(certificate.source.rawValue))")
            if let identitySHA256 = certificate.identitySHA256 { lines.append("    identitySHA256: \(quote(identitySHA256))") }
            if let issuer = certificate.issuer { lines.append("    issuer: \(quote(issuer))") }
            lines.append("    renewBeforeSeconds: \(certificate.renewBeforeSeconds)")
            lines.append("    validitySeconds: \(certificate.validitySeconds)")
            lines.append("    statusPolicy: \(quote(certificate.statusPolicy.rawValue))")
        }
    }

    private static func canonicalNetworkAddress(
        _ request: HostwrightNetworkAddressRequest,
        ipv6: Bool
    ) -> String {
        guard case .cidr(let rawValue) = request else {
            return request.manifestValue
        }
        return ManifestValidator.normalizedNetworkCIDR(rawValue, ipv6: ipv6) ?? rawValue
    }

    private static func appendServiceNetworks(
        _ networks: [HostwrightServiceNetworkAttachment],
        to lines: inout [String]
    ) {
        guard !networks.isEmpty else { return }
        lines.append("    networks:")
        for attachment in networks.sorted(by: {
            if $0.network != $1.network {
                return $0.network < $1.network
            }
            return $0.aliases.lexicographicallyPrecedes($1.aliases)
        }) {
            lines.append("      - network: \(quote(attachment.network))")
            let aliases = attachment.aliases.sorted()
            guard !aliases.isEmpty else { continue }
            lines.append("        aliases:")
            for alias in aliases {
                lines.append("          - \(quote(alias))")
            }
        }
    }

    private static func canonicalProbes(for service: HostwrightService) -> HostwrightProbes {
        guard service.probes.liveness == nil, let health = service.health else {
            return service.probes
        }
        let rawInterval = health.interval ?? "10s"
        let interval = Int(rawInterval.dropLast()) ?? 10
        return HostwrightProbes(
            startup: service.probes.startup,
            readiness: service.probes.readiness,
            liveness: HostwrightProbe(action: .exec(health.command), interval: interval)
        )
    }

    private static func appendProbe(_ probe: HostwrightProbe?, name: String, to lines: inout [String]) {
        guard let probe else { return }
        lines.append("      \(name):")
        switch probe.action {
        case .exec(let command):
            lines.append("        exec: \(array(command))")
        case .http(let port, let path):
            lines.append("        http:")
            lines.append("          port: \(port)")
            lines.append("          path: \(quote(path))")
        case .tcp(let port):
            lines.append("        tcp:")
            lines.append("          port: \(port)")
        }
        if probe.startPeriod != 0 {
            lines.append("        startPeriod: \(quote("\(probe.startPeriod)s"))")
        }
        if probe.interval != 10 {
            lines.append("        interval: \(quote("\(probe.interval)s"))")
        }
        if probe.timeout != 3 {
            lines.append("        timeout: \(quote("\(probe.timeout)s"))")
        }
        if probe.successThreshold != 1 {
            lines.append("        successThreshold: \(probe.successThreshold)")
        }
        if probe.failureThreshold != 3 {
            lines.append("        failureThreshold: \(probe.failureThreshold)")
        }
    }

    private static func appendHook(_ hook: [String]?, name: String, to lines: inout [String]) {
        guard let hook else { return }
        lines.append("      \(name):")
        lines.append("        exec: \(array(hook))")
    }

    private static func appendEnumMap(
        _ values: [String: HostwrightDependencyCondition],
        key: String,
        to lines: inout [String]
    ) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for (mapKey, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("      \(quote(mapKey)): \(quote(value.rawValue))")
        }
    }

    private static func appendStringMap(
        _ values: [String: String],
        key: String,
        indent: Int = 4,
        to lines: inout [String]
    ) {
        guard !values.isEmpty else { return }
        let spaces = String(repeating: " ", count: indent)
        lines.append("\(spaces)\(key):")
        for (mapKey, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("\(spaces)  \(quote(mapKey)): \(quote(value))")
        }
    }

    private static func appendHostAccess(
        _ endpoints: [HostwrightHostAccessEndpoint],
        to lines: inout [String]
    ) {
        guard !endpoints.isEmpty else { return }
        lines.append("    hostAccess:")
        for endpoint in endpoints.sorted(
            by: HostwrightHostAccessPolicy.canonicalPrecedes
        ) {
            lines.append(
                "      - hostname: \(quote(endpoint.hostname))"
            )
            lines.append(
                "        protocol: \(quote(endpoint.protocolName.rawValue))"
            )
            lines.append(
                "        addressClass: \(quote(endpoint.addressClass.rawValue))"
            )
            lines.append("        port: \(endpoint.port)")
        }
    }

    private static func appendNetworkPolicy(
        _ policy: HostwrightServiceNetworkPolicy?,
        to lines: inout [String]
    ) {
        guard let policy else { return }
        lines.append("    networkPolicy:")
        appendNetworkPolicyRules(policy.ingress, direction: "ingress", to: &lines)
        appendNetworkPolicyRules(policy.egress, direction: "egress", to: &lines)
    }

    private static func appendNetworkPolicyRules(
        _ rules: [HostwrightNetworkPolicyRule],
        direction: String,
        to lines: inout [String]
    ) {
        guard !rules.isEmpty else {
            lines.append("      \(direction): []")
            return
        }
        lines.append("      \(direction):")
        for rule in rules.sorted(by: { $0.canonicalKey < $1.canonicalKey }) {
            var fields: [(String, String)] = []
            if let project = rule.project { fields.append(("project", quote(project))) }
            if let service = rule.service { fields.append(("service", quote(service))) }
            if let identity = rule.identity { fields.append(("identity", quote(identity))) }
            if let protocolName = rule.protocolName { fields.append(("protocol", quote(protocolName.rawValue))) }
            if let address = rule.address { fields.append(("address", quote(address))) }
            if let port = rule.port { fields.append(("port", "\(port)")) }
            if let dns = rule.dns { fields.append(("dns", quote(dns))) }
            guard let first = fields.first else { continue }
            lines.append("        - \(first.0): \(first.1)")
            for field in fields.dropFirst() {
                lines.append("          \(field.0): \(field.1)")
            }
        }
    }

    private static func appendBlockArray(_ values: [String], key: String, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for value in values {
            lines.append("      - \(quote(value))")
        }
    }

    private static func appendPublishedEndpoints(
        ports: [HostwrightPublishedPort],
        sockets: [HostwrightPublishedSocket],
        to lines: inout [String]
    ) {
        guard !ports.isEmpty || !sockets.isEmpty else { return }
        lines.append("    ports:")
        for value in ports {
            lines.append("      - bind: \(quote(value.effectiveBindAddress))")
            if let host = value.host {
                lines.append("        host: \(canonicalPortSpan(host))")
            }
            lines.append("        target: \(canonicalPortSpan(value.target))")
            lines.append("        protocol: \(quote(value.protocolName.rawValue))")
            if let exposure = value.exposure, !exposure.isDefaultLocalhost {
                lines.append("        exposure:")
                lines.append("          scope: \(quote(exposure.scope.rawValue))")
                lines.append("          interfaces: \(array(exposure.interfaces))")
                lines.append("          networkClasses: \(array(exposure.networkClasses.map(\.rawValue)))")
                lines.append("          allowedCIDRs: \(array(exposure.allowedCIDRs))")
                lines.append("          authentication: \(quote(exposure.authentication.rawValue))")
            }
        }
        for value in sockets {
            if let hostName = value.hostName {
                lines.append("      - host: \(quote(hostName))")
                lines.append("        target: \(quote(value.containerPath))")
            } else {
                lines.append("      - target: \(quote(value.containerPath))")
            }
            lines.append("        protocol: \"unix\"")
            lines.append("        mode: \(quote(value.mode.rawValue))")
        }
    }

    private static func canonicalPortSpan(_ value: HostwrightPortSpan) -> String {
        if value.isSingle {
            return String(value.start)
        }
        return quote(value.canonicalString)
    }

    private static func appendMounts(_ mounts: [HostwrightMountSpec], to lines: inout [String]) {
        guard !mounts.isEmpty else { return }
        lines.append("    volumes:")
        for mount in mounts {
            if let legacy = mount.legacyLiteral {
                lines.append("      - \(quote(legacy))")
                continue
            }

            lines.append("      - type: \(quote(mount.kind.rawValue))")
            if let source = mount.source {
                lines.append("        source: \(quote(source))")
            }
            lines.append("        target: \(quote(mount.target))")
            if mount.readOnly {
                lines.append("        readOnly: true")
            }
            if let mode = mount.mode {
                lines.append("        mode: \(quote(mode))")
            }
            if let size = mount.size {
                lines.append("        size: \(quote(size))")
            }
        }
    }

    private static func appendArray(_ values: [String], key: String, indent: Int, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(String(repeating: " ", count: indent))\(key): \(array(values))")
    }

    private static func array(_ values: [String]) -> String {
        "[" + values.map(quote).joined(separator: ", ") + "]"
    }

    private static func quote(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
