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
        capability("accelerators.guest-passthrough", "Direct guest GPU and ANE passthrough", .blocked, 10, 219, "GPU and ANE passthrough is deferred for v0.0.2. No supported public Apple API exposes this boundary; the local release makes no accelerator claim.", [.unitContract, .securityAssessment, .hardwareBenchmark]),
        capability("accelerators.host-native", "Metal, Core ML, and MLX host-native service", .unavailable, 10, 219, "Host-native accelerators are deferred for v0.0.2. Retained development contracts and service slices do not establish supported accelerator execution.", [.unitContract, .localIntegration, .securityAssessment, .hardwareBenchmark]),
        capability("api.control-v2", "Persistent local Control API 2.2", .experimental, 9, 206, "The authenticated local Unix-socket API implements bounded unary requests and streams, authorization, RBAC, revocation, deterministic admission and plan confirmation. Current candidate security qualification remains required; complete CLI and desktop parity is deferred.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("architecture.contracts", "Versioned local v0.0.2 contracts", .experimental, 1, 110, "The local release uses Manifest v3, Control API 2.2 and SQLite schema v24, with declared Runtime Provider API v2 and Storage Provider API v1 capabilities. Final candidate and GA qualification remain required.", [.unitContract, .migrationUpgrade]),
        capability("ci.distribution", "Protected signed distribution and local qualification", .experimental, 15, 283, "Protected workflows implement exact-source signed/notarized staging, retained evidence acceptance and immutable promotion. Runtime qualification uses one physical M4 Pro and one macOS VM; current candidate acceptance and GA publication remain pending.", [.distributionArtifact, .securityAssessment]),
        capability("cloud.control-plane", "Optional team cloud control plane", .unavailable, 14, 270, "Cloud control-plane and team service claims are deferred for v0.0.2. The local release grants no tenant, remote-agent or cloud availability guarantee.", [.securityAssessment, .resilienceChaos, .uxAccessibility]),
        capability("daemon.reconciliation", "Local level-triggered reconciliation", .experimental, 8, 194, "Local reconciliation, restart budgets, maintenance deferral, health-gated lifecycle operations and durable recovery are implemented. Exact-source interruption, cancellation, cleanup and soak qualification remain required for the current candidate.", [.localIntegration, .liveRuntime, .resilienceChaos]),
        capability("distribution.homebrew-core", "Homebrew-core distribution", .blocked, 2, 120, "Homebrew-core submission is deferred for v0.0.2. The separate vendor tap supplies unsupported development artifacts; verified GA tap installation and upgrade remain required.", [.distributionArtifact]),
        capability("distribution.installed-lifecycle", "Verified install, upgrade, repair, rollback, and uninstall", .stable, 2, 118, "Verified artifacts use strict version transitions, deterministic cancellation and recovery, one verified prior-generation rollback, ownership-scoped repair/removal, confirmation-bound state deletion, and narrow stop/restore handling for an exact existing Homebrew launchd record; this lane creates no autonomous LaunchAgent and refuses unmanaged hostwrightd processes.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("distribution.release-evidence", "Release supply-chain evidence and independent verification", .experimental, 2, 119, "Exact-source builds, SPDX, signed checksums and provenance, signing/notarization verification and private evidence retention are implemented. Historical signed stages retain their original identities; the current candidate and final-version bytes require separate complete acceptance.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("distribution.vendor-tap", "Vendor Homebrew tap installation", .experimental, 2, 120, "The separate vendor tap currently supplies unsupported dev.12 prerelease bytes. The GA formula requires verified final-version publication, downloaded-byte comparison and real tap installation and upgrade.", [.distributionArtifact, .migrationUpgrade, .securityAssessment]),
        capability("extensions.wasi-xpc", "Capability-limited WASI and signed XPC extensions", .experimental, 9, 206, "Plugin ABI v1 provides fresh-instance capability-limited WASI execution, a reciprocal signed sandboxed XPC identity boundary, and explicit-source signed immutable package lifecycle through the authenticated Control API; aggregate notarized and lifecycle qualification remains pending.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("foundation.secure-subprocess", "Bounded secure subprocess foundation", .stable, 2, 116, "Direct argv execution, secret-safe environment transport, root-owned PATH resolution, descriptor-pinned working directories, bounded I/O and time, cancellation, fenced session process-group cleanup, and typed errors are executable and tested; native-code isolation remains owned by the WASI/XPC workstreams.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("foundation.secure-local-paths", "Secure macOS local paths and defaults", .stable, 2, 113, "State uses Application Support by default with explicit override precedence, private permissions, fail-closed path validation, journaled legacy migration, and separately fenced private maintenance artifacts.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("foundation.doctor-readiness", "Non-mutating host readiness diagnostics", .stable, 2, 117, "Doctor reports five stable readiness states across platform, Apple services, secure state, networking, signing trust, resource pressure, and required tools; runtime probes are bounded behind RuntimeAdapter and existing state is inspected as an immutable checkpointed snapshot.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("gui.native", "Native SwiftUI local desktop", .experimental, 14, 262, "The native desktop app provides manifest selection, service status, logs and confirmed up/down/restart through authenticated Control API 2.2. Current candidate desktop/accessibility checks remain required; automatic updates and full CLI parity are deferred.", [.uxAccessibility, .localIntegration, .securityAssessment]),
        capability("images.supply-chain", "OCI image lifecycle and supply-chain trust", .experimental, 5, 152, "Image lifecycle, registry authentication, immutable provider/platform digest locks, bounded referrer transport, signature trust, SBOM binding and vulnerability/provenance policy are implemented. The current candidate requires its exact-source security and artifact assessment; capability use remains subject to the declared runtime provider.", [.unitContract, .localIntegration, .securityAssessment, .interopConformance]),
        capability("interop.docker-compose", "General Docker and Compose client interoperability", .unavailable, 13, 257, "Docker-client, Podman and Testcontainers compatibility are deferred for v0.0.2. The implemented narrow Compose import converts supported fields into a reviewed Manifest v3; it provides no Docker Engine endpoint or general Compose orchestration.", [.interopConformance, .securityAssessment, .resilienceChaos]),
        capability("interop.kubernetes", "Kubernetes node interoperability", .unavailable, 12, 247, "Kubernetes, CRI, CNI, CSI and Helm interoperability are deferred for v0.0.2. Retained development code does not establish supported node or cluster behavior.", [.interopConformance, .multiHost, .resilienceChaos, .securityAssessment]),
        capability("lifecycle.single-host", "Declarative single-Mac lifecycle", .experimental, 10, 207, "Manifest v3 lifecycle uses authenticated plan confirmation, deterministic local CPU/memory admission, durable checkpoints and exact resource ownership. The current candidate requires live provider, recovery and signed-artifact qualification.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("manifest.restricted-parser", "Strict maintained Hostwright YAML parser", .stable, 4, 130, "Yams 6.2.2 is isolated behind a bounded source-aware decoder that rejects aliases, merge keys, custom tags, duplicate keys, ambiguous scalars, unknown fields, multiple documents, and configured byte, depth, and node limits.", [.unitContract, .securityAssessment]),
        capability("manifest.v3", "Manifest v3 local contract", .experimental, 10, 207, "Manifest v3 parsing, deterministic legacy migration, nested resource validation and local lifecycle admission are implemented. Current candidate and final-version qualification remain required; topology optimization, automatic preemption and cross-project fairness guarantees are deferred.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade]),
        capability("multi-host.ha", "Multi-Mac consensus and high availability", .unavailable, 11, 235, "Multi-Mac operations, cluster availability, replicated authority, failover, shared volumes and cluster disaster recovery are deferred for v0.0.2. The supported release targets one Mac.", [.multiHost, .resilienceChaos, .securityAssessment, .migrationUpgrade]),
        capability("networking.ingress", "Owned local HTTP and WebSocket ingress", .stable, 7, 172, "The signed on-demand network helper provides UUID-owned localhost and explicit-LAN HTTP/1.1/WebSocket ingress with TLS or mTLS policy, ready-only backends, bounded parsing, atomic configuration generations, graceful drain, restart recovery, and exact cleanup.", [.unitContract, .localIntegration, .liveRuntime, .securityAssessment, .resilienceChaos]),
        capability("networking.project", "Owned local project networking", .stable, 7, 178, "Local project networking, DNS, publication, host access, ingress, certificate policy and service tunnels are available only where the selected provider declares support. Unsupported provider features refuse before effects; this capability grants no shared-network or multi-Mac claim.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("observability.telemetry", "Local events, logs, diagnostics and support bundles", .experimental, 8, 194, "Durable local events, redacted diagnostics, OSLog, bounded cursor/watch recovery and consent-bound support bundles are implemented. Bundles remain local until shared explicitly; the current candidate requires its single-host soak.", [.localIntegration, .resilienceChaos, .securityAssessment]),
        capability("release.ga", "v0.0.2 general availability gate", .unavailable, 15, 283, "One complete clean RC, independent signed-artifact lifecycle, security review, retained-corpus fuzzing, supported sanitizers, ten cycles per declared provider and a checkpointed 30-minute single-host soak are required. Final 0.0.2 source and bytes require separate complete protected acceptance; GA is not published.", [.localIntegration, .liveRuntime, .distributionArtifact, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance, .uxAccessibility]),
        capability("registries.authentication", "Private registry authentication", .experimental, 5, 142, "Keychain-backed login/logout, guarded credential lookup, bounded Basic/Bearer challenges, exact scopes, token expiry, TLS and same-origin redirects are implemented. The current candidate requires applicable registry and security qualification.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("runtime.apple-container-cli", "Apple container CLI provider", .stable, 3, 129, "Apple container 1.0.0 and 1.1.0 use explicit structured codecs, immutable capability negotiation, deterministic observation, normalized outcomes, generation binding, migration, and restart/upgrade recovery for the declared local-image lifecycle subset.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("runtime.containerization", "Direct Apple Containerization provider", .stable, 3, 129, "Exact Containerization 0.35.0 runs only through the authenticated out-of-process helper and passes the shared conformance, fencing, migration, crash/restart, upgrade, cancellation, and exact-cleanup gates for its declared local-image lifecycle subset.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("scheduler.optimization", "Scheduler topology and pressure optimization", .unavailable, 10, 219, "Topology optimization, cross-project fairness guarantees, automatic preemption and VM reclamation are deferred for v0.0.2. Deterministic local CPU/memory admission is implemented through the single-Mac lifecycle; retained optimization code adds no supported guarantee.", [.unitContract, .hardwareBenchmark, .resilienceChaos]),
        capability("secrets.keychain", "Keychain and guarded secret providers", .experimental, 5, 152, "Keychain CRUD and workload-scoped Keychain, guarded environment-file and guarded local-file resolution are implemented. External/plugin references fail closed without registered providers; current candidate security and backup/recovery qualification remain required.", [.unitContract, .localIntegration, .securityAssessment]),
        capability("state.backup-restore-repair", "Verified state backup, restore, integrity, repair, and recovery", .stable, 2, 114, "Private online backups, strict catalogs, full integrity classification, confirmation-bound atomic restore, projection-only repair, cross-process fencing, and durable checkpoint recovery are executable and tested; direct writes outside Hostwright and arbitrary authoritative-row salvage remain forbidden.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("state.sqlite-v17", "Durable single-Mac SQLite state schema v24", .stable, 2, 115, "Current schema v24 retains historical schema-v17 rows and enforces private database/sidecar identity, WAL/FULL durability, serialized writers, bounded transactions, cancellation rollback, fail-closed migration, fenced resource authority and local restart budgets. Distributed authority, direct external writes and arbitrary authoritative salvage are outside the supported scope.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("state.control-identities-v18", "Persistent local control identities and sessions", .experimental, 9, 198, "Current schema v24 retains schema-v18 identity/session foundations and implements declared peers, connection-bound sessions, immediate revocation, request identity and idempotency through authenticated Control API 2.2. Current candidate authentication and recovery qualification remain required.", [.unitContract, .localIntegration, .migrationUpgrade, .securityAssessment, .resilienceChaos]),
        capability("storage.persistent", "Local persistent volumes, snapshots, backup and restore", .stable, 6, 163, "Storage Provider API v1 and the local provider implement guarded mounts, named-volume lifecycle, fencing, snapshots, verified local backup/restore, capacity accounting and exact owned reclaim through current schema-v24 state and Control API 2.2. Current candidate workload-data recovery qualification remains required; shared/multi-Mac storage and unmanaged/global deletion are deferred.", [.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos, .interopConformance]),
        capability("team.mdm", "Team approvals and MDM policy", .unavailable, 14, 270, "Team/MDM deployment, policy distribution and cloud services are deferred for v0.0.2. Retained local development profiles and approvals do not establish supported enterprise administration.", [.unitContract, .securityAssessment, .uxAccessibility])
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
