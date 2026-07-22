public enum HostwrightCapabilityState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case stable
    case experimental
    case unavailable
    case blocked
}

public struct HostwrightCapability: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let state: HostwrightCapabilityState
    public let phase: Int
    public let issue: Int
    public let reason: String
    public let requiredEvidence: [HostwrightEvidenceClass]

    public init(
        identifier: String,
        title: String,
        state: HostwrightCapabilityState,
        phase: Int,
        issue: Int,
        reason: String,
        requiredEvidence: [HostwrightEvidenceClass]
    ) {
        self.identifier = identifier
        self.title = title
        self.state = state
        self.phase = phase
        self.issue = issue
        self.reason = reason
        self.requiredEvidence = requiredEvidence
    }
}

public struct HostwrightCapabilityReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let productVersion: String
    public let releaseTarget: String
    public let contracts: HostwrightContractSnapshot
    public let capabilities: [HostwrightCapability]

    public init(
        schemaVersion: Int = 1,
        productVersion: String = HostwrightIdentity.version,
        releaseTarget: String = HostwrightIdentity.releaseTarget,
        contracts: HostwrightContractSnapshot = HostwrightContractSnapshot(),
        capabilities: [HostwrightCapability]
    ) {
        self.schemaVersion = schemaVersion
        self.productVersion = productVersion
        self.releaseTarget = releaseTarget
        self.contracts = contracts
        self.capabilities = capabilities.sorted { $0.identifier < $1.identifier }
    }
}

public enum HostwrightCapabilityCatalog {
    public static let report = HostwrightCapabilityReport(capabilities: catalog)

    private static let catalog: [HostwrightCapability] = [
        capability("accelerators.guest-passthrough", "Direct guest GPU and ANE passthrough", .blocked, 10, 219, "No supported public Apple API currently exposes direct guest GPU or ANE passthrough; the v0.0.2 implementation target is an authenticated host-native service.", [.unitContract, .securityAssessment, .hardwareBenchmark]),
        capability("accelerators.host-native", "Metal, Core ML, and MLX host-native service", .unavailable, 10, 219, "The signed service, workload identity, quotas, cancellation, and data-transfer protocol are not implemented.", [.unitContract, .localIntegration, .securityAssessment, .hardwareBenchmark]),
        capability("api.control-v2", "Persistent local Control API v2", .experimental, 9, 206, "A bounded local request API exists, but persistent Unix-socket transport, watch recovery, authentication, RBAC, and full CLI parity remain incomplete.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("architecture.contracts", "Versioned v0.0.2 public contracts", .experimental, 1, 110, "Manifest v2, Control API v2, Runtime Provider API v2, plugin ABI v1, and state schema v7 are under active qualification.", [.unitContract, .migrationUpgrade]),
        capability("ci.distribution", "Signed distribution and physical-Mac CI", .unavailable, 15, 283, "Signing, notarization, clean-host install matrices, physical runtime conformance, and release promotion are not wired into CI.", [.distributionArtifact, .securityAssessment]),
        capability("cloud.control-plane", "Optional team cloud control plane", .unavailable, 14, 270, "Tenant state, OIDC, outbound agents, isolation, audit, consent, and offline-disconnection behavior are not implemented.", [.securityAssessment, .resilienceChaos, .uxAccessibility]),
        capability("daemon.reconciliation", "Autonomous level-triggered reconciliation", .unavailable, 8, 194, "The current daemon boundary does not yet provide unattended durable reconciliation, restart budgets, finalizers, retention, or checkpoint recovery.", [.localIntegration, .liveRuntime, .resilienceChaos]),
        capability("distribution.homebrew-core", "Unqualified brew install hostwright", .blocked, 2, 120, "Homebrew core publication depends on external formula acceptance; a maintained vendor tap is the required implemented fallback.", [.distributionArtifact]),
        capability("distribution.installed-lifecycle", "Verified install, upgrade, repair, rollback, and uninstall", .stable, 2, 118, "Verified artifacts use strict version transitions, deterministic cancellation and recovery, one verified prior-generation rollback, ownership-scoped repair/removal, confirmation-bound state deletion, and narrow stop/restore handling for an exact existing Homebrew launchd record; this lane creates no autonomous LaunchAgent and refuses unmanaged hostwrightd processes.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("distribution.release-evidence", "Release supply-chain evidence and independent verification", .experimental, 2, 119, "Exact-commit builds, per-artifact SPDX, signed checksums and provenance, structured verification, and explicit retention are implemented; credentialed Developer ID/notarization and published-byte evidence remain pending before this capability can be stable.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("distribution.vendor-tap", "Vendor Homebrew tap installation", .unavailable, 2, 120, "The tap, formula, signed archive, notarization, upgrade, rollback, and uninstall evidence are not yet shipped.", [.distributionArtifact, .migrationUpgrade, .securityAssessment]),
        capability("extensions.wasi-xpc", "Capability-limited WASI and signed XPC extensions", .unavailable, 9, 206, "The current reviewed-local executable boundary is not a WASI sandbox and does not provide signed XPC capability mediation.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("foundation.secure-subprocess", "Bounded secure subprocess foundation", .stable, 2, 116, "Direct argv execution, secret-safe environment transport, root-owned PATH resolution, descriptor-pinned working directories, bounded I/O and time, cancellation, fenced session process-group cleanup, and typed errors are executable and tested; native-code isolation remains owned by the WASI/XPC workstreams.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("foundation.secure-local-paths", "Secure macOS local paths and defaults", .stable, 2, 113, "State uses Application Support by default with explicit override precedence, private permissions, fail-closed path validation, journaled legacy migration, and separately fenced private maintenance artifacts.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("foundation.doctor-readiness", "Non-mutating host readiness diagnostics", .stable, 2, 117, "Doctor reports five stable readiness states across platform, Apple services, secure state, networking, signing trust, resource pressure, and required tools; runtime probes are bounded behind RuntimeAdapter and existing state is inspected as an immutable checkpointed snapshot.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("gui.native", "Native SwiftUI application and menu bar", .unavailable, 14, 270, "No native GUI, accessibility-qualified workflow, signed update channel, or CLI/API parity matrix exists.", [.uxAccessibility, .localIntegration, .securityAssessment]),
        capability("images.supply-chain", "OCI image lifecycle and supply-chain trust", .unavailable, 5, 152, "Complete image operations, registry authentication, digest locks, signatures, SBOMs, vulnerability policy, provenance, leases, and cache GC are not implemented.", [.unitContract, .localIntegration, .securityAssessment, .interopConformance]),
        capability("interop.docker-compose", "Docker, Compose, Podman, and Testcontainers", .unavailable, 13, 257, "No version-negotiated Docker Engine endpoint or complete client conformance matrix is available.", [.interopConformance, .securityAssessment, .resilienceChaos]),
        capability("interop.kubernetes", "CRI, CNI, CSI, Helm, and Kubernetes node interoperability", .unavailable, 12, 247, "The required pod-sandbox VM and guest-agent boundary, CRI services, real guest networking, storage adapters, and conformance reports do not exist.", [.interopConformance, .multiHost, .resilienceChaos, .securityAssessment]),
        capability("lifecycle.single-host", "Complete declarative single-host lifecycle", .unavailable, 4, 140, "Current apply behavior is intentionally narrow and lacks the durable multi-service operation DAG, full lifecycle commands, probes, rolling updates, and automatic rollback.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .resilienceChaos]),
        capability("manifest.restricted-parser", "Restricted Hostwright YAML parser", .stable, 1, 110, "The bounded parser and validator are covered by unit tests; general YAML and the complete Manifest v2 workload schema are not claimed.", [.unitContract]),
        capability("manifest.v2", "Manifest v2 contract and migration preview", .experimental, 1, 110, "The breaking version contract and read-only preview are present while the complete executable workload schema remains Phase 04 work.", [.unitContract, .migrationUpgrade]),
        capability("multi-host.ha", "Multi-Mac consensus and high availability", .unavailable, 11, 235, "Cluster membership, managed etcd, replicated desired state, fencing, failover, remote volumes, and disaster recovery are not implemented.", [.multiHost, .resilienceChaos, .securityAssessment, .migrationUpgrade]),
        capability("networking.project", "Project networking, DNS, ingress, policy, and tunnels", .unavailable, 7, 178, "Owned networks, DNS, dual-stack transport, ingress, certificate lifecycle, policy enforcement, and tunnel providers are incomplete.", [.unitContract, .liveRuntime, .securityAssessment, .resilienceChaos]),
        capability("observability.telemetry", "Events, metrics, traces, logs, and support bundles", .experimental, 8, 194, "Local events and redacted diagnostics exist, but OSLog integration, metrics, traces, retention, streaming recovery, and leak-qualified soak evidence are incomplete.", [.localIntegration, .resilienceChaos, .securityAssessment]),
        capability("release.ga", "v0.0.2 general availability gate", .unavailable, 15, 283, "The two clean RC runs, security audit, fuzzing, soak, conformance, performance, signed provenance, and release lifecycle evidence have not completed.", [.distributionArtifact, .securityAssessment, .resilienceChaos, .multiHost, .interopConformance, .uxAccessibility]),
        capability("runtime.apple-container-cli", "Apple container CLI provider", .stable, 3, 129, "Apple container 1.0.0 and 1.1.0 use explicit structured codecs, immutable capability negotiation, deterministic observation, normalized outcomes, generation binding, migration, and restart/upgrade recovery for the declared local-image lifecycle subset.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("runtime.containerization", "Direct Apple Containerization provider", .stable, 3, 129, "Exact Containerization 0.35.0 runs only through the authenticated out-of-process helper and passes the shared conformance, fencing, migration, crash/restart, upgrade, cancellation, and exact-cleanup gates for its declared local-image lifecycle subset.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("scheduler.optimization", "Resource scheduler and pressure optimization", .unavailable, 10, 219, "Requests, limits, hard filters, fair packing, topology, preemption, hysteresis, thermal policy, and exact-oracle qualification are not implemented.", [.unitContract, .hardwareBenchmark, .resilienceChaos]),
        capability("secrets.keychain", "Production Keychain and secret providers", .experimental, 5, 152, "Secret references and redaction boundaries exist, but production CRUD, provider lifecycle, rotation, and end-to-end no-leak evidence are incomplete.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("state.backup-restore-repair", "Verified state backup, restore, integrity, repair, and recovery", .stable, 2, 114, "Private online backups, strict catalogs, full integrity classification, confirmation-bound atomic restore, projection-only repair, cross-process fencing, and durable checkpoint recovery are executable and tested; direct writes outside Hostwright and arbitrary authoritative-row salvage remain forbidden.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("state.sqlite-v7", "Durable single-host SQLite state schema v7", .stable, 2, 115, "Hostwright-mediated single-Mac state enforces application ownership, private database and sidecar identity, explicit WAL/FULL durability, serialized writers, bounded managed transactions, rollback under cancellation and pressure, and fail-closed migration; same-user direct writers, distributed authority, and arbitrary authoritative salvage are not claimed.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("storage.persistent", "Persistent volumes, snapshots, backup, and restore", .unavailable, 6, 163, "Named-volume lifecycle, provider SPI, snapshots, quotas, fencing, reclaim policy, and verified restore are not implemented.", [.unitContract, .liveRuntime, .resilienceChaos, .securityAssessment]),
        capability("team.mdm", "Team approvals and MDM policy", .experimental, 14, 270, "Local team profiles and approvals exist, but full role administration, MDM deployment, policy distribution, and enterprise qualification are incomplete.", [.unitContract, .securityAssessment, .uxAccessibility])
    ]

    private static func capability(
        _ identifier: String,
        _ title: String,
        _ state: HostwrightCapabilityState,
        _ phase: Int,
        _ issue: Int,
        _ reason: String,
        _ requiredEvidence: [HostwrightEvidenceClass]
    ) -> HostwrightCapability {
        HostwrightCapability(
            identifier: identifier,
            title: title,
            state: state,
            phase: phase,
            issue: issue,
            reason: reason,
            requiredEvidence: requiredEvidence
        )
    }
}
