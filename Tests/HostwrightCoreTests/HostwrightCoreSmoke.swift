import Foundation
import XCTest
@testable import HostwrightCore

final class HostwrightCoreTests: XCTestCase {
    func testHostwrightIdentityConstants() {
        XCTAssertEqual(HostwrightIdentity.projectName, "Hostwright")
        XCTAssertEqual(HostwrightIdentity.cliName, "hostwright")
        XCTAssertEqual(HostwrightIdentity.daemonName, "hostwrightd")
        XCTAssertEqual(HostwrightIdentity.manifestFileName, "hostwright.yaml")
        XCTAssertEqual(HostwrightIdentity.domain, "hostwright.dev")
        XCTAssertEqual(HostwrightIdentity.version, "0.1.0-alpha.1")
    }

    func testCompatibilityGateRejectsUnsupportedPlatform() {
        let diagnostics = CompatibilityGate.evaluate(
            PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(diagnostics.map(\.code), [.unsupportedArchitecture, .unsupportedMacOSVersion])
    }

    func testReleaseDocsDescribeAlphaSourceOnlyTruth() throws {
        let root = try packageRoot()
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let releaseNotes = try read("docs/release/v0.1.0-alpha.1-notes.md", root: root)
        let install = try read("docs/reference/install.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let publicDocs = [releaseProcess, releaseNotes, install, security, limitations].joined(separator: "\n")

        XCTAssertTrue(releaseProcess.contains("v0.1.0-alpha.1"))
        XCTAssertTrue(releaseProcess.contains("GitHub Releases are created only for `v*` tags."))
        XCTAssertTrue(releaseProcess.contains("Artifact policy: source-only"))
        XCTAssertTrue(releaseNotes.localizedCaseInsensitiveContains("not production ready"))
        XCTAssertTrue(install.localizedCaseInsensitiveContains("source-only alpha"))
        XCTAssertTrue(security.localizedCaseInsensitiveContains("not production ready"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("brew install"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("installer package is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("binary downloads are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("signed binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("notarized binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("is production ready"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Kubernetes"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports CRI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Docker API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Docker Compose"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports cloud"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports GPU"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports ANE"))
    }

    func testSecureExposureResearchKeepsCurrentSupportUnsupported() throws {
        let root = try packageRoot()
        let decision = try read("docs/architecture/secure-exposure-research.md", root: root)
        let networking = try read("docs/architecture/networking-boundary.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let securityReference = try read("docs/reference/security-safety.md", root: root)
        let securityPolicy = try read("SECURITY.md", root: root)
        let publicDocs = [decision, networking, limitations, securityReference, securityPolicy].joined(separator: "\n")

        XCTAssertTrue(decision.contains("Status: research-only decision record for Phase 23."))
        XCTAssertTrue(decision.contains("| Cloudflare Tunnel public application | Reject from core; defer only to plugin or later prototype |"))
        XCTAssertTrue(decision.contains("| Tailscale Serve | Reject from core; defer only to plugin or later prototype |"))
        XCTAssertTrue(decision.contains("| WireGuard | Reject from core for now |"))
        XCTAssertTrue(decision.contains("| Cloud control plane | Reject for current core |"))
        XCTAssertTrue(decision.contains("No provider integration is implemented by this research phase."))
        XCTAssertTrue(networking.contains("See [Secure Exposure Research](secure-exposure-research.md)"))
        XCTAssertTrue(limitations.contains("Cloudflare Tunnel, Tailscale Serve/Funnel, WireGuard, mTLS provisioning, or reverse proxy setup."))

        XCTAssertTrue(securityPolicy.contains("No tunnel, DNS, cloud, CRI, Kubernetes, or Docker API behavior exists."))
        XCTAssertTrue(securityPolicy.contains("Destructive mutation is limited to ownership-scoped cleanup delete"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports tunnels"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports cloud exposure"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Cloudflare"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Tailscale"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports WireGuard"))
    }

    func testSecretsKeychainDocsDescribeLocalBoundaryOnly() throws {
        let root = try packageRoot()
        let boundary = try read("docs/architecture/secrets-keychain-boundary.md", root: root)
        let manifest = try read("docs/reference/manifest.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let publicDocs = [boundary, manifest, security, limitations].joined(separator: "\n")

        XCTAssertTrue(boundary.contains("Status: Phase 24 local boundary."))
        XCTAssertTrue(boundary.contains("secretEnv:"))
        XCTAssertTrue(boundary.contains("Live macOS Keychain access is not enabled by default in Phase 24."))
        XCTAssertTrue(manifest.contains("secretEnv"))
        XCTAssertTrue(security.contains("tests use a fake Keychain backend"))
        XCTAssertTrue(limitations.contains("no live Keychain default"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("live macOS Keychain access is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports cloud secret"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports registry credential"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Kubernetes secrets"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Compose secrets"))
    }

    func testSupplyChainImageTrustDocsDescribeLocalPolicyOnly() throws {
        let root = try packageRoot()
        let boundary = try read("docs/architecture/supply-chain-image-trust.md", root: root)
        let manifest = try read("docs/reference/manifest.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let publicDocs = [boundary, manifest, security, limitations].joined(separator: "\n")

        XCTAssertTrue(boundary.contains("Status: Phase 25 local policy and research boundary."))
        XCTAssertTrue(boundary.contains("imagePolicy: require-digest"))
        XCTAssertTrue(manifest.contains("Digest pinning gives Hostwright a stable content identifier string"))
        XCTAssertTrue(security.contains("local string validation only"))
        XCTAssertTrue(limitations.contains("Hostwright does not query registries, resolve tags, verify signatures, inspect SBOMs, scan vulnerabilities, or prove provenance."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright verifies signatures"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright scans vulnerabilities"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright generates SBOM"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright proves provenance"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright pulls images"))
    }

    func testResourceIntelligenceDocsDescribeLocalReportingOnly() throws {
        let root = try packageRoot()
        let methodology = try read("docs/architecture/resource-intelligence.md", root: root)
        let constraints = try read("docs/architecture/apple-silicon-constraints.md", root: root)
        let compatibility = try read("docs/reference/compatibility.md", root: root)
        let doctor = try read("docs/reference/doctor-checks.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let publicDocs = [methodology, constraints, compatibility, doctor, limitations].joined(separator: "\n")

        XCTAssertTrue(methodology.contains("Status: Phase 26 local reporting boundary."))
        XCTAssertTrue(methodology.contains("If any dimension is not measured, the report must say `unmeasured` instead of inferring a value."))
        XCTAssertTrue(doctor.contains("does not run Apple container commands"))
        XCTAssertTrue(compatibility.contains("no capacity guarantee"))
        XCTAssertTrue(limitations.contains("resource intelligence is also local and diagnostic"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright guarantees capacity"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright schedules GPU"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports ANE"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Metal"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Core ML"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports MLX"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("uploads telemetry"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("automatically places workloads"))
    }

    func testAcceleratorBoundaryResearchKeepsCurrentSupportUnsupported() throws {
        let root = try packageRoot()
        let decision = try read("docs/architecture/accelerator-boundary-research.md", root: root)
        let constraints = try read("docs/architecture/apple-silicon-constraints.md", root: root)
        let resourceIntelligence = try read("docs/architecture/resource-intelligence.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0027-accelerator-boundary-research.md", root: root)
        let publicDocs = [
            decision,
            constraints,
            resourceIntelligence,
            limitations,
            security,
            requirements,
            acceptance,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(decision.contains("Status: Phase 27 research-only decision record."))
        XCTAssertTrue(decision.contains("| Apple container GPU or Metal passthrough | Reject from current core |"))
        XCTAssertTrue(decision.contains("| PyTorch MPS inside Apple container Linux workloads | Reject from current core |"))
        XCTAssertTrue(decision.contains("| MLX inside Apple container Linux workloads | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Core ML or ANE inside Apple container Linux workloads | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Host-native accelerator helper or service | Defer to plugin or later prototype |"))
        XCTAssertTrue(decision.contains("| Scheduler accelerator dimensions | Defer and block |"))
        XCTAssertTrue(limitations.contains("Current Hostwright core does not expose Apple GPU, ANE, Metal, Core ML, MLX, PyTorch MPS"))
        XCTAssertTrue(security.contains("Host-native accelerator helpers or services require a separate threat model"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-007"))
        XCTAssertTrue(resourceIntelligence.contains("See [Accelerator Boundary Research](accelerator-boundary-research.md)"))
        XCTAssertTrue(acceptance.contains("Phase 27 Gate: Apple Silicon Accelerator Boundary Research"))
        XCTAssertTrue(implementationPlan.contains("## Phase 27 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 27 was research-only."))
        XCTAssertTrue(devlog.contains("No GPU, ANE, Metal, Core ML, MLX, or PyTorch MPS implementation."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports GPU"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports ANE"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Metal"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Core ML"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports MLX"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports PyTorch MPS"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright exposes host GPU"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright schedules accelerators"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright runs host-native accelerator services"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright uses private ANE"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright passes through GPU"))
    }

    func testPolicyEngineDocsDescribeLocalNonMutatingBoundary() throws {
        let root = try packageRoot()
        let architecture = try read("docs/architecture/policy-engine.md", root: root)
        let reference = try read("docs/reference/policy.md", root: root)
        let manifest = try read("docs/reference/manifest.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0032-policy-engine.md", root: root)
        let publicDocs = [
            architecture,
            reference,
            manifest,
            limitations,
            security,
            requirements,
            acceptance,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(architecture.contains("Status: Phase 32 local policy boundary."))
        XCTAssertTrue(reference.contains("Hostwright policy is local and deterministic."))
        XCTAssertTrue(manifest.contains("Policy evaluation is local and non-mutating"))
        XCTAssertTrue(limitations.contains("Policy evaluation is local and diagnostic."))
        XCTAssertTrue(security.contains("Policy evaluation is local, deterministic, and non-mutating."))
        XCTAssertTrue(requirements.contains("HW-SAFE-008"))
        XCTAssertTrue(acceptance.contains("Phase 32 Gate: Policy Engine"))
        XCTAssertTrue(implementationPlan.contains("## Phase 32 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 32 added a local deterministic policy engine"))
        XCTAssertTrue(devlog.contains("No remote policy service."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote policy service is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team policy workflow is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("silent bypass is allowed"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("policy mutates runtime"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("policy uploads telemetry"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("policy configures tunnels"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("policy enables accelerators"))
    }

    func testStackImportDocsDescribeConversionOnlyBoundary() throws {
        let root = try packageRoot()
        let cli = try read("docs/reference/cli.md", root: root)
        let guide = try read("docs/guides/stack-import.md", root: root)
        let manifest = try read("docs/reference/manifest.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let policy = try read("docs/reference/policy.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0028-stack-file-import.md", root: root)
        let publicDocs = [
            cli,
            guide,
            manifest,
            limitations,
            policy,
            requirements,
            acceptance,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(cli.contains("hostwright import-stack <path> [--output text|json]"))
        XCTAssertTrue(guide.contains("Status: Phase 28 import-only conversion."))
        XCTAssertTrue(manifest.contains("`hostwright import-stack <path>` can convert a smaller stack-file subset"))
        XCTAssertTrue(limitations.contains("The stack-file importer is also not a general YAML or Compose parser."))
        XCTAssertTrue(policy.contains("Stack-file import uses local policy reason codes"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-008"))
        XCTAssertTrue(acceptance.contains("Phase 28 Gate: Stack-File Import And Migration Tooling"))
        XCTAssertTrue(implementationPlan.contains("## Phase 28 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 28 adds import-only stack-file conversion"))
        XCTAssertTrue(devlog.contains("No Docker Compose parity."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Docker Compose"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright is Compose-compatible"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("import-stack writes hostwright.yaml"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("import-stack applies"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("import-stack observes runtime"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("import-stack pulls images"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("import-stack configures networks"))
    }

    private func read(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "HostwrightCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
            }
            url = parent
        }
    }
}
