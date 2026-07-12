import Foundation
import XCTest
@testable import HostwrightCore

final class HostwrightCoreTests: XCTestCase {
    func testProductionSourcesDoNotContainTestDoubleTypes() throws {
        let root = try packageRoot()
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var violations: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            if contents.range(
                of: #"\b(?:struct|class|actor|enum)\s+(?:Mock|Fake)[A-Za-z0-9_]*"#,
                options: .regularExpression
            ) != nil {
                violations.append(fileURL.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }

        XCTAssertEqual(violations, [], "Test-double types must remain outside production Sources.")
    }

    func testEvidenceContractSeparatesDeterministicAndRealProof() throws {
        let root = try packageRoot()
        let policy = try read("docs/reference/testing-evidence.md", root: root)
        let schemaText = try read("schemas/hostwright-evidence.schema.json", root: root)
        let schemaData = try XCTUnwrap(schemaText.data(using: .utf8))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let evidenceClass = try XCTUnwrap(properties["evidenceClass"] as? [String: Any])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])
        let commands = try XCTUnwrap(properties["commands"] as? [String: Any])
        let constraints = try XCTUnwrap(schema["allOf"] as? [[String: Any]])

        XCTAssertEqual(
            evidenceClass["enum"] as? [String],
            ["unit-contract", "local-integration", "live-runtime", "hardware-benchmark", "distribution-artifact"]
        )
        XCTAssertEqual(status["enum"] as? [String], ["passed", "failed", "blocked"])
        XCTAssertEqual(commands["minItems"] as? Int, 1)
        XCTAssertEqual(constraints.count, 4)
        XCTAssertTrue(schemaText.contains(#""exitCode": {"const": 0}"#))
        XCTAssertTrue(schemaText.contains(#""exactResourceIdentifiers": {"minItems": 1}"#))
        XCTAssertTrue(schemaText.contains(#"{"properties": {"status": {"const": "passed"}}}"#))
        XCTAssertTrue(policy.contains("there is no skipped-success status"))
        XCTAssertTrue(policy.contains("may not be converted to passed with a fixture"))
        XCTAssertTrue(policy.contains("Exact cleanup failure makes live-runtime or hardware evidence fail"))
        XCTAssertFalse(policy.localizedCaseInsensitiveContains("skipped tests count as passed"))
    }

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
        let distributionReadiness = try read("docs/release/distribution-readiness.md", root: root)
        let releaseNotes = try read("docs/release/v0.1.0-alpha.1-notes.md", root: root)
        let install = try read("docs/reference/install.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0035-packaging-signing-notarization.md", root: root)
        let publicDocs = [
            releaseProcess,
            distributionReadiness,
            releaseNotes,
            install,
            security,
            limitations,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(releaseProcess.contains("v0.1.0-alpha.1"))
        XCTAssertTrue(releaseProcess.contains("GitHub Releases are created only for `v*` tags."))
        XCTAssertTrue(releaseProcess.contains("Artifact policy: source-only"))
        XCTAssertTrue(releaseProcess.contains("## Distribution Readiness Gate"))
        XCTAssertTrue(distributionReadiness.contains("Status: Phase 35 fail-closed distribution readiness gate."))
        XCTAssertTrue(distributionReadiness.contains("No binary artifacts are produced by Phase 35."))
        XCTAssertTrue(distributionReadiness.contains("| `.pkg` installer | Blocked |"))
        XCTAssertTrue(distributionReadiness.contains("Developer ID Application signing proof"))
        XCTAssertTrue(distributionReadiness.contains("package-channel approval"))
        XCTAssertTrue(releaseNotes.localizedCaseInsensitiveContains("not production ready"))
        XCTAssertTrue(install.localizedCaseInsensitiveContains("source-only alpha"))
        XCTAssertTrue(install.contains("Phase 35 defines the future distribution readiness gate"))
        XCTAssertTrue(security.localizedCaseInsensitiveContains("not production ready"))
        XCTAssertTrue(security.contains("## Release Distribution Boundary"))
        XCTAssertTrue(limitations.contains("Release distribution readiness documentation"))
        XCTAssertTrue(requirements.contains("HW-REL-005"))
        XCTAssertTrue(requirements.contains("HW-REL-006"))
        XCTAssertTrue(acceptance.contains("Phase 35 Gate: Packaging Signing Notarization And Distribution"))
        XCTAssertTrue(traceability.contains("HW-REL-005, HW-REL-006, HW-GOV-003"))
        XCTAssertTrue(implementationPlan.contains("## Phase 35 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 35 is blocked"))
        XCTAssertTrue(devlog.contains("No binary artifacts."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("brew install"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("installer package is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("binary downloads are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("signed binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("notarized binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Homebrew formula is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("install script is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("SBOM is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("provenance is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("package-channel support is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("launch agent installer is implemented"))
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
        let secretStoreSource = try read("Sources/HostwrightSecrets/SecretStore.swift", root: root)
        let publicDocs = [boundary, manifest, security, limitations].joined(separator: "\n")

        XCTAssertTrue(boundary.contains("Status: Phase 24 local boundary."))
        XCTAssertTrue(boundary.contains("secretEnv:"))
        XCTAssertTrue(boundary.contains("`MacOSKeychainSecretStore` is a read-only production backend"))
        XCTAssertTrue(boundary.contains("There is no conditional skip path"))
        XCTAssertTrue(boundary.contains("Live macOS Keychain access is not enabled by default in Phase 24"))
        XCTAssertTrue(manifest.contains("secretEnv"))
        XCTAssertTrue(security.contains("unit-contract tests inject a test-only in-memory secret store"))
        XCTAssertTrue(security.contains("Production Hostwright code does not create, update, or delete Keychain items."))
        XCTAssertTrue(limitations.contains("no live Keychain default"))
        XCTAssertTrue(secretStoreSource.contains("SecItemCopyMatching"))
        XCTAssertTrue(secretStoreSource.contains("interactionNotAllowed = true"))
        XCTAssertFalse(secretStoreSource.contains("SecItemAdd"))
        XCTAssertFalse(secretStoreSource.contains("SecItemDelete"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("live macOS Keychain access is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright writes Keychain items"))
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
        let benchmarkLab = try read("docs/architecture/benchmark-lab.md", root: root)
        let constraints = try read("docs/architecture/apple-silicon-constraints.md", root: root)
        let compatibility = try read("docs/reference/compatibility.md", root: root)
        let doctor = try read("docs/reference/doctor-checks.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0036-ci-benchmarking-performance-lab.md", root: root)
        let ci = try read(".github/workflows/ci.yml", root: root)
        let publicDocs = [
            methodology,
            benchmarkLab,
            constraints,
            compatibility,
            doctor,
            limitations,
            releaseProcess,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog,
            ci
        ].joined(separator: "\n")

        XCTAssertTrue(methodology.contains("Status: Phase 26 local reporting boundary, extended by the Phase 36 benchmark lab."))
        XCTAssertTrue(methodology.contains("Phase 36 adds a separate [Benchmark Lab](benchmark-lab.md) report contract"))
        XCTAssertTrue(benchmarkLab.contains("Status: Phase 36 local dry-run and fixture-backed benchmark lab."))
        XCTAssertTrue(benchmarkLab.contains("Every benchmark dimension must be present."))
        XCTAssertTrue(benchmarkLab.contains("disposable resource names use a `hostwright-` prefix"))
        XCTAssertTrue(methodology.contains("If any dimension is not measured, the report must say `unmeasured` instead of inferring a value."))
        XCTAssertTrue(doctor.contains("does not run Apple container commands"))
        XCTAssertTrue(compatibility.contains("Phase 36 benchmark lab parses dry-run/fixture reports only"))
        XCTAssertTrue(limitations.contains("resource intelligence is also local and diagnostic"))
        XCTAssertTrue(limitations.contains("Phase 36 benchmark lab report models"))
        XCTAssertTrue(releaseProcess.contains("## Benchmark Gate"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-011"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-012"))
        XCTAssertTrue(acceptance.contains("Phase 36 Gate: CI Benchmarking And Performance Lab"))
        XCTAssertTrue(traceability.contains("HW-COMPAT-011, HW-COMPAT-012, HW-REL-004"))
        XCTAssertTrue(implementationPlan.contains("## Phase 36 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 36 is partial"))
        XCTAssertTrue(devlog.contains("No benchmark numbers or performance marketing claims."))
        XCTAssertTrue(ci.contains("scripts/lint.sh"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright guarantees capacity"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright publishes benchmark numbers"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright monitors performance"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright runs live benchmarks in CI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Apple container version compatibility is guaranteed"))
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
        XCTAssertTrue(limitations.contains("Policy evaluation is local and deterministic."))
        XCTAssertTrue(security.contains("Policy evaluation is local, deterministic, and non-mutating."))
        XCTAssertTrue(requirements.contains("HW-SAFE-008"))
        XCTAssertTrue(acceptance.contains("Phase 32 Gate: Policy Engine"))
        XCTAssertTrue(implementationPlan.contains("## Phase 32 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 32 added a local deterministic policy engine"))
        XCTAssertTrue(devlog.contains("No remote policy service."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote policy service is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote team policy workflow is implemented"))
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

    func testExternalOrchestrationCompatibilityResearchKeepsCurrentSupportUnsupported() throws {
        let root = try packageRoot()
        let decision = try read("docs/architecture/external-orchestration-compatibility-research.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0029-external-orchestration-compatibility-research.md", root: root)
        let publicDocs = [
            decision,
            limitations,
            requirements,
            acceptance,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(decision.contains("Status: Phase 29 research-only decision record."))
        XCTAssertTrue(decision.contains("| CRI runtime compatibility | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Kubernetes node or kubelet replacement | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Docker Engine API shim | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Testcontainers target compatibility | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Full Docker Compose parity | Reject from current core |"))
        XCTAssertTrue(decision.contains("Prototype requires separate maintainer approval before any code implementation."))
        XCTAssertTrue(limitations.contains("External orchestration compatibility remains research-only."))
        XCTAssertTrue(requirements.contains("HW-COMPAT-005"))
        XCTAssertTrue(acceptance.contains("Phase 29 Gate: External Orchestration Compatibility Research"))
        XCTAssertTrue(implementationPlan.contains("## Phase 29 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 29 was research-only."))
        XCTAssertTrue(devlog.contains("No CRI shim."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Kubernetes"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports CRI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Docker API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Docker Compose"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright is Kubernetes-compatible"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright is Docker-compatible"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements CRI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements Docker API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements Compose parity"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Testcontainers-compatible"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("CRI shim is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Docker API shim is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("external scheduler API is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("port-forward compatibility is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("attach compatibility is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("exec compatibility is implemented"))
    }

    func testMultiHostPlatformResearchKeepsCurrentSupportSingleHost() throws {
        let root = try packageRoot()
        let decision = try read("docs/architecture/multi-host-platform-research.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0030-multi-host-platform-research.md", root: root)
        let publicDocs = [
            decision,
            limitations,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(decision.contains("Status: Phase 30 research-only decision record."))
        XCTAssertTrue(decision.contains("Hostwright core stays single-host."))
        XCTAssertTrue(decision.contains("| Keep current core single-host | Accept |"))
        XCTAssertTrue(decision.contains("| Peer-to-peer multi-host control | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Replicated state database | Reject from current core |"))
        XCTAssertTrue(decision.contains("| Remote control plane | Reject from current core |"))
        XCTAssertTrue(decision.contains("Prototype requires separate maintainer approval before any code implementation."))
        XCTAssertTrue(limitations.contains("Multi-host platform work remains research-only."))
        XCTAssertTrue(requirements.contains("HW-COMPAT-009"))
        XCTAssertTrue(acceptance.contains("Phase 30 Gate: Multi-Host Apple Silicon Platform Research"))
        XCTAssertTrue(traceability.contains("HW-COMPAT-009"))
        XCTAssertTrue(traceability.contains("current core single-host"))
        XCTAssertTrue(implementationPlan.contains("## Phase 30 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 30 was research-only."))
        XCTAssertTrue(devlog.contains("No multi-host orchestration."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports multi-host"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports multi-Mac"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports remote hosts"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports remote placement"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports cloud control plane"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements multi-host"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements remote host agents"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements state replication"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements scheduler API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("multi-host orchestration is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote mutation is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("state replication is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("membership service is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("peer discovery is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote placement is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cloud control plane is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("scheduler API is implemented"))
    }

    func testAdvisorySchedulerDocsDescribeLocalAdvisoryBoundary() throws {
        let root = try packageRoot()
        let architecture = try read("docs/architecture/advisory-scheduler.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let policy = try read("docs/reference/policy.md", root: root)
        let resourceIntelligence = try read("docs/architecture/resource-intelligence.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0031-scheduler-placement-engine.md", root: root)
        let publicDocs = [
            architecture,
            limitations,
            policy,
            resourceIntelligence,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(architecture.contains("Status: Phase 31 local advisory model."))
        XCTAssertTrue(architecture.contains("advisoryOnly = true"))
        XCTAssertTrue(architecture.contains("requested accelerator dimensions are blockers"))
        XCTAssertTrue(limitations.contains("Local advisory scheduler reports"))
        XCTAssertTrue(limitations.contains("Advisory scheduling is local and diagnostic."))
        XCTAssertTrue(policy.contains("Advisory scheduling consumes local policy decisions"))
        XCTAssertTrue(resourceIntelligence.contains("Phase 31 advisory scheduling may consume resource reports"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-010"))
        XCTAssertTrue(acceptance.contains("Phase 31 Gate: Scheduler And Placement Engine"))
        XCTAssertTrue(traceability.contains("HW-COMPAT-010"))
        XCTAssertTrue(implementationPlan.contains("## Phase 31 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 31 adds a local advisory scheduler model"))
        XCTAssertTrue(devlog.contains("No automatic placement."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright automatically places workloads"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright reserves capacity"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports scheduler API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright implements scheduler API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports remote placement"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright schedules accelerators"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("automatic placement is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("resource reservation is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote placement is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("scheduler API is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("accelerator-aware scheduling is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Kubernetes scheduler behavior is implemented"))
    }

    func testControlPlaneDirectionKeepsCurrentCoreSingleHost() throws {
        let root = try packageRoot()
        let direction = try read("docs/architecture/control-plane-direction.md", root: root)
        let charter = try read("docs/PROJECT_CHARTER.md", root: root)
        let readme = try read("README.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0040-control-plane-direction.md", root: root)
        let publicDocs = [
            direction,
            charter,
            readme,
            limitations,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(direction.contains("Status: Phase 40 direction decision."))
        XCTAssertTrue(direction.contains("Hostwright core remains a single-host Apple silicon control plane"))
        XCTAssertTrue(direction.contains("| Single-host core | Accept |"))
        XCTAssertTrue(direction.contains("| Kubernetes-class Apple silicon control plane in current core | Reject |"))
        XCTAssertTrue(direction.contains("| Multi-host inside current core | Reject |"))
        XCTAssertTrue(direction.contains("| CRI compatibility in current core | Reject |"))
        XCTAssertTrue(direction.contains("| Cloud control plane in current core | Reject |"))
        XCTAssertTrue(direction.contains("| Accelerator-aware scheduling | Reject for current core |"))
        XCTAssertTrue(direction.contains("Follow-up issues may be opened only for evidence-backed work in the chosen direction."))
        XCTAssertTrue(charter.contains("Phase 40 keeps current core on the single-host path"))
        XCTAssertTrue(readme.contains("Control-plane direction"))
        XCTAssertTrue(limitations.contains("Apple silicon control-plane direction documentation"))
        XCTAssertTrue(requirements.contains("HW-COMPAT-013"))
        XCTAssertTrue(acceptance.contains("Phase 40 Gate: Apple Silicon Control-Plane Direction Decision"))
        XCTAssertTrue(traceability.contains("HW-COMPAT-013"))
        XCTAssertTrue(implementationPlan.contains("## Phase 40 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 40 adds an Apple silicon control-plane direction decision"))
        XCTAssertTrue(devlog.contains("No cluster implementation."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Kubernetes"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports CRI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Docker API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports Docker Compose"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports multi-host"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports cloud control plane"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright supports remote placement"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright schedules accelerators"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Kubernetes-class control plane is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("CRI shim is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Docker API shim is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("multi-host orchestration is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote placement is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cloud control plane is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("accelerator-aware scheduling is implemented"))
    }

    func testGovernanceDocsDescribeReviewAndSupportBoundaries() throws {
        let root = try packageRoot()
        let governance = try read("GOVERNANCE.md", root: root)
        let contributing = try read("CONTRIBUTING.md", root: root)
        let securityPolicy = try read("SECURITY.md", root: root)
        let pullRequestTemplate = try read(".github/PULL_REQUEST_TEMPLATE.md", root: root)
        let issueTemplate = try read(".github/ISSUE_TEMPLATE/engineering-task.md", root: root)
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let securityReference = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0038-governance-contributor-model.md", root: root)
        let publicDocs = [
            governance,
            contributing,
            securityPolicy,
            pullRequestTemplate,
            issueTemplate,
            releaseProcess,
            limitations,
            securityReference,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(governance.contains("Risky areas require explicit maintainer review"))
        XCTAssertTrue(governance.contains("Hostwright does not currently enforce CODEOWNERS."))
        XCTAssertTrue(contributing.contains("Ask for maintainer review before changing"))
        XCTAssertTrue(securityPolicy.contains("request a private maintainer contact first"))
        XCTAssertTrue(pullRequestTemplate.contains("Risky areas from `GOVERNANCE.md` and `SECURITY.md`"))
        XCTAssertTrue(issueTemplate.contains("Security/governance review triggers"))
        XCTAssertTrue(releaseProcess.contains("## Governance Gate"))
        XCTAssertTrue(limitations.contains("Governance, contribution, security reporting"))
        XCTAssertTrue(securityReference.contains("## Governance Boundary"))
        XCTAssertTrue(requirements.contains("HW-GOV-001"))
        XCTAssertTrue(requirements.contains("HW-GOV-002"))
        XCTAssertTrue(requirements.contains("HW-GOV-003"))
        XCTAssertTrue(acceptance.contains("Phase 38 Gate: Governance And Contributor Model"))
        XCTAssertTrue(traceability.contains("HW-GOV-001, HW-GOV-002, HW-GOV-003"))
        XCTAssertTrue(implementationPlan.contains("## Phase 38 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 38 adds governance"))
        XCTAssertTrue(devlog.contains("No CODEOWNERS enforcement."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("CODEOWNERS enforcement is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("branch protection is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright provides a support SLA"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hosted diagnostics are implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("telemetry upload is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cloud service is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("binary downloads are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("installer packages are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("signing is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("notarization is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("SBOM is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("provenance is provided"))
    }

    func testControlSurfaceDocsDescribeBoundaryWithoutImplementation() throws {
        let root = try packageRoot()
        let boundary = try read("docs/architecture/control-surface-api-boundary.md", root: root)
        let cli = try read("docs/reference/cli.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0021-control-surface-api-boundary.md", root: root)
        let publicDocs = [
            boundary,
            cli,
            limitations,
            security,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(boundary.contains("Status: Phase 21 requirements and API boundary only."))
        XCTAssertTrue(boundary.contains("A control surface must not call Apple container, SQLite, `RuntimeAdapter`, state migrations, cleanup deletion, or health execution directly."))
        XCTAssertTrue(boundary.contains("| Cleanup preview | `hostwright cleanup --state-db <path> --dry-run` |"))
        XCTAssertTrue(boundary.contains("Full keyboard navigation"))
        XCTAssertTrue(boundary.contains("Screen-reader labels"))
        XCTAssertTrue(boundary.contains("maintainer approval for any new API wrapper"))
        XCTAssertTrue(cli.contains("hostwright diagnostics --state-db <path> --bundle <path>"))
        XCTAssertTrue(limitations.contains("Local control-surface requirements and API boundary documentation"))
        XCTAssertTrue(security.contains("## Control Surface Boundary"))
        XCTAssertTrue(requirements.contains("HW-GUI-001"))
        XCTAssertTrue(requirements.contains("HW-GUI-004"))
        XCTAssertTrue(acceptance.contains("Phase 21 Gate: GUI Control Surface Requirements And API Boundary"))
        XCTAssertTrue(traceability.contains("HW-GUI-001, HW-GUI-002, HW-GUI-003, HW-GUI-004"))
        XCTAssertTrue(implementationPlan.contains("## Phase 21 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 21 adds local control-surface requirements"))
        XCTAssertTrue(devlog.contains("No GUI code."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("GUI is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("web dashboard is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cloud dashboard is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("daemon API is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("control surface may call Apple container directly"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("control surface may access SQLite directly"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("RuntimeAdapter bypass is allowed"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hosted diagnostics are implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("telemetry upload is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cleanup tokens can be bypassed"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("plan hashes can be bypassed"))
    }

    func testExtensionArchitectureDocsDescribeDeclarationPolicyOnly() throws {
        let root = try packageRoot()
        let architecture = try read("docs/architecture/plugin-extension-architecture.md", root: root)
        let policy = try read("docs/reference/policy.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0033-plugin-extension-architecture.md", root: root)
        let publicDocs = [
            architecture,
            policy,
            limitations,
            security,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(architecture.contains("Status: Phase 33 declaration policy and architecture boundary."))
        XCTAssertTrue(architecture.contains("This is a non-mutating prototype. It does not run extension code."))
        XCTAssertTrue(architecture.contains("| Tunnel provider | Current core blocks tunnels, DNS, reverse proxy setup, and public exposure. |"))
        XCTAssertTrue(policy.contains("Extension declarations can be evaluated as local data."))
        XCTAssertTrue(limitations.contains("Local extension declaration policy decisions"))
        XCTAssertTrue(security.contains("## Extension Boundary"))
        XCTAssertTrue(requirements.contains("HW-EXT-001"))
        XCTAssertTrue(requirements.contains("HW-EXT-003"))
        XCTAssertTrue(acceptance.contains("Phase 33 Gate: Plugin And Extension Architecture"))
        XCTAssertTrue(traceability.contains("HW-EXT-001, HW-EXT-002, HW-EXT-003"))
        XCTAssertTrue(implementationPlan.contains("## Phase 33 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 33 adds typed extension declarations"))
        XCTAssertTrue(devlog.contains("No plugin loader."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright loads plugins"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright executes plugins"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote plugin registry is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("untrusted extension execution is supported"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("runtime mutation extension is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("state-write extension is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("networking provider is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("tunnel provider is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("secret backend extension is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("accelerator extension is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("extension may bypass RuntimeAdapter"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("extension may access SQLite directly"))
    }

    func testTeamWorkflowDocsDescribeLocalOptInBoundary() throws {
        let root = try packageRoot()
        let teamWorkflow = try read("docs/reference/team-workflow.md", root: root)
        let governance = try read("GOVERNANCE.md", root: root)
        let policy = try read("docs/reference/policy.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0034-enterprise-team-workflow.md", root: root)
        let publicDocs = [
            teamWorkflow,
            governance,
            policy,
            limitations,
            security,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(teamWorkflow.contains("Status: Phase 34 local operational profile and approval workflow."))
        XCTAssertTrue(teamWorkflow.contains("Hostwright loads team policy only from an explicit `--team-profile <path>`"))
        XCTAssertTrue(teamWorkflow.contains("There is no weakening override format."))
        XCTAssertTrue(teamWorkflow.contains("Profile-aware mutation carries the profile, manifest, plan, and approval hashes"))
        XCTAssertTrue(governance.contains("Team workflow"))
        XCTAssertTrue(policy.contains("Team policy profiles can be evaluated as local data."))
        XCTAssertTrue(limitations.contains("Explicit local team profiles"))
        XCTAssertTrue(security.contains("## Team Workflow Boundary"))
        XCTAssertTrue(requirements.contains("HW-TEAM-001"))
        XCTAssertTrue(requirements.contains("HW-TEAM-004"))
        XCTAssertTrue(acceptance.contains("Phase 34 Gate: Enterprise And Team Workflow"))
        XCTAssertTrue(traceability.contains("HW-TEAM-001, HW-TEAM-002, HW-TEAM-003, HW-TEAM-004"))
        XCTAssertTrue(implementationPlan.contains("## Phase 34 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 34 is complete locally"))
        XCTAssertTrue(devlog.contains("No cloud team service"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("cloud team service is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("central remote control is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hosted audit log is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("user tracking is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("enterprise support workflow is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("remote policy distribution is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team profiles bypass plan hashes"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team profiles bypass cleanup tokens"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team profiles bypass ownership checks"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team workflow manages macOS users"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("team workflow manages shared secrets"))
    }

    func testDocumentationSiteDocsDescribeSourceOfTruthBoundary() throws {
        let root = try packageRoot()
        let sitePlan = try read("docs/architecture/documentation-site-public-education.md", root: root)
        let readme = try read("README.md", root: root)
        let cli = try read("docs/reference/cli.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0037-documentation-site-public-education.md", root: root)
        let publicDocs = [
            sitePlan,
            readme,
            cli,
            limitations,
            releaseProcess,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(sitePlan.contains("Status: Phase 37 source-of-truth and information architecture boundary."))
        XCTAssertTrue(sitePlan.contains("Core repository owns source reference truth"))
        XCTAssertTrue(sitePlan.contains("The separate `hostwright.dev` repository owns presentation"))
        XCTAssertTrue(sitePlan.contains("Website copy must link back to the source docs when it describes current behavior."))
        XCTAssertTrue(sitePlan.contains("examples/single-service/hostwright.yaml"))
        XCTAssertTrue(sitePlan.contains("examples/app-suite/hostwright.yaml"))
        XCTAssertTrue(sitePlan.contains("Run `hostwright validate` and `hostwright plan`."))
        XCTAssertTrue(sitePlan.contains("current `apply` executes at most one supported action"))
        XCTAssertTrue(sitePlan.contains("cleanup deletes only exact eligible Hostwright-owned non-running containers"))
        XCTAssertTrue(readme.contains("Documentation-site source-of-truth plan"))
        XCTAssertTrue(limitations.contains("Documentation-site information architecture"))
        XCTAssertTrue(releaseProcess.contains("## Public Education Gate"))
        XCTAssertTrue(requirements.contains("HW-DOCS-005"))
        XCTAssertTrue(acceptance.contains("Phase 37 Gate: Documentation Site And Public Education"))
        XCTAssertTrue(traceability.contains("HW-DOCS-001, HW-DOCS-002, HW-DOCS-003, HW-DOCS-005"))
        XCTAssertTrue(implementationPlan.contains("## Phase 37 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 37 adds documentation-site source-of-truth"))
        XCTAssertTrue(devlog.contains("No website frontend."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hostwright.dev is deployed from this repository"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hosted docs are implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("documentation-site frontend is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("website analytics are enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("website search is implemented"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("website owns source truth"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("marketing claims can override limitations"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("tutorials may skip limitations"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("public docs may claim Kubernetes support"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("public docs may claim Docker API support"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("public docs may claim tunnel support"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("public docs may claim GPU support"))
    }

    func testBetaReadinessDocsKeepBetaBlockedUntilEvidence() throws {
        let root = try packageRoot()
        let betaReadiness = try read("docs/release/beta-readiness.md", root: root)
        let readme = try read("README.md", root: root)
        let install = try read("docs/reference/install.md", root: root)
        let compatibility = try read("docs/reference/compatibility.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let requirements = try read("docs/requirements/REQUIREMENTS.md", root: root)
        let acceptance = try read("docs/requirements/ACCEPTANCE_MATRIX.md", root: root)
        let traceability = try read("docs/requirements/SOURCE_TRACEABILITY.md", root: root)
        let implementationPlan = try read("docs/IMPLEMENTATION_PLAN.md", root: root)
        let buildStatus = try read("docs/BUILD_STATUS.md", root: root)
        let devlog = try read("docs/devlog/0039-beta-readiness.md", root: root)
        let publicDocs = [
            betaReadiness,
            readme,
            install,
            compatibility,
            limitations,
            releaseProcess,
            requirements,
            acceptance,
            traceability,
            implementationPlan,
            buildStatus,
            devlog
        ].joined(separator: "\n")

        XCTAssertTrue(betaReadiness.contains("Status: Phase 39 beta readiness gate."))
        XCTAssertTrue(betaReadiness.contains("No beta tag, GitHub Release, binary artifact, installer, support promise, production-readiness claim, or version bump is approved by this document."))
        XCTAssertTrue(betaReadiness.contains("The next beta can remain source-only"))
        XCTAssertTrue(betaReadiness.contains("| Source install | Clean checkout from the intended `v*` tag builds"))
        XCTAssertTrue(betaReadiness.contains("## Blockers Before Beta"))
        XCTAssertTrue(betaReadiness.contains("## Deferrable Past Beta"))
        XCTAssertTrue(betaReadiness.contains("## Clean-Checkout Smoke"))
        XCTAssertTrue(readme.contains("Beta readiness gate"))
        XCTAssertTrue(install.contains("Phase 39 defines the beta readiness gate"))
        XCTAssertTrue(compatibility.contains("no beta compatibility claim exists"))
        XCTAssertTrue(limitations.contains("Beta readiness checklist documentation"))
        XCTAssertTrue(releaseProcess.contains("## Beta Readiness Gate"))
        XCTAssertTrue(requirements.contains("HW-REL-007"))
        XCTAssertTrue(requirements.contains("HW-REL-008"))
        XCTAssertTrue(acceptance.contains("Phase 39 Gate: Beta Readiness"))
        XCTAssertTrue(traceability.contains("HW-REL-007, HW-REL-008, HW-DOCS-002, HW-GOV-003"))
        XCTAssertTrue(implementationPlan.contains("## Phase 39 Outputs"))
        XCTAssertTrue(buildStatus.contains("Phase 39 adds beta readiness"))
        XCTAssertTrue(devlog.contains("No beta tag."))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright is beta ready"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("v0.1.0-beta.1 is released"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("Hostwright is production ready"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("binary downloads are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("installer packages are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("support SLA is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("beta compatibility is guaranteed"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("beta support is active"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("clean checkout proof exists"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("hosted telemetry is enabled"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("external telemetry is enabled"))
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
