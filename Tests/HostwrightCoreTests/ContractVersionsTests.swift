import Foundation
import XCTest
@testable import HostwrightCore

final class ContractVersionsTests: XCTestCase {
    func testReleaseAndBreakingContractVersionsHaveOneAuthority() {
        XCTAssertNotNil(
            HostwrightIdentity.version.range(
                of: #"\A0\.0\.2(?:-(?:dev\.[1-9][0-9]{0,2}|rc\.[1-9][0-9]?))?\z"#,
                options: .regularExpression
            )
        )
        XCTAssertEqual(
            HostwrightIdentity.version.split(separator: "-", maxSplits: 1).first.map { "v\($0)" },
            HostwrightIdentity.releaseTarget
        )
        XCTAssertEqual(HostwrightIdentity.releaseTarget, "v0.0.2")
        XCTAssertEqual(HostwrightContractVersions.manifest, 3)
        XCTAssertEqual(HostwrightContractVersions.controlAPI, 2)
        XCTAssertEqual(HostwrightContractVersions.runtimeProviderAPI, 2)
        XCTAssertEqual(HostwrightContractVersions.storageProviderAPI, 1)
        XCTAssertEqual(HostwrightContractVersions.networkProviderSPI, 1)
        XCTAssertEqual(HostwrightContractVersions.pluginABI, 1)
        XCTAssertEqual(HostwrightContractVersions.stateSchema, 24)
    }

    func testCapabilityCatalogIsDeterministicUniqueAndCoversEveryRoadmapPhase() throws {
        let report = HostwrightCapabilityCatalog.report
        let identifiers = report.capabilities.map(\.identifier)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.productVersion, HostwrightIdentity.version)
        XCTAssertEqual(report.releaseTarget, HostwrightIdentity.releaseTarget)
        XCTAssertEqual(report.contracts.manifest, HostwrightContractVersions.manifest)
        XCTAssertEqual(identifiers, identifiers.sorted())
        XCTAssertEqual(Set(identifiers).count, identifiers.count)

        let states: [String: HostwrightCapabilityState] = [
            "foundation.secure-subprocess": .stable,
            "distribution.installed-lifecycle": .stable,
            "distribution.release-evidence": .experimental,
            "runtime.apple-container-cli": .stable,
            "runtime.containerization": .stable,
            "manifest.restricted-parser": .stable,
            "manifest.v3": .experimental,
            "lifecycle.single-host": .experimental,
            "networking.ingress": .stable,
            "storage.persistent": .stable,
            "secrets.keychain": .experimental,
            "registries.authentication": .experimental,
            "scheduler.optimization": .unavailable,
            "accelerators.host-native": .unavailable,
            "accelerators.guest-passthrough": .blocked,
            "interop.docker-compose": .unavailable,
            "interop.kubernetes": .unavailable,
            "cloud.control-plane": .unavailable,
            "multi-host.ha": .unavailable,
            "team.mdm": .experimental,
        ]
        for (identifier, expected) in states.sorted(by: { $0.key < $1.key }) {
            let capability = try XCTUnwrap(report.capabilities.first { $0.identifier == identifier }, identifier)
            XCTAssertEqual(capability.state, expected, identifier)
        }
        let required: Set<HostwrightEvidenceClass> = [
            .unitContract, .localIntegration, .liveRuntime, .migrationUpgrade,
            .securityAssessment, .resilienceChaos,
        ]
        for identifier in ["distribution.release-evidence", "runtime.apple-container-cli",
                           "runtime.containerization", "storage.persistent"] {
            let capability = try XCTUnwrap(report.capabilities.first { $0.identifier == identifier }, identifier)
            let expected = identifier == "distribution.release-evidence"
                ? required : required.union([.interopConformance])
            XCTAssertEqual(Set(capability.requiredEvidence), expected, identifier)
        }
    }
    func testVerificationConstitutionIncludesEveryV002EvidenceClass() {
        XCTAssertEqual(
            Set(HostwrightEvidenceClass.allCases.map(\.rawValue)),
            Set([
                "unit-contract",
                "local-integration",
                "live-runtime",
                "hardware-benchmark",
                "distribution-artifact",
                "migration-upgrade",
                "security-assessment",
                "resilience-chaos",
                "multi-host",
                "interop-conformance",
                "ux-accessibility"
            ])
        )
    }

    func testCheckedInV002VersionGoldenMatchesProductionAuthority() throws {
        struct Golden: Decodable {
            let productVersion: String
            let releaseTarget: String
            let manifest: Int
            let controlAPI: Int
            let runtimeProviderAPI: Int
            let storageProviderAPI: Int
            let networkProviderSPI: Int
            let pluginABI: Int
            let stateSchema: Int
        }

        let data = try Data(contentsOf: contractRoot().appendingPathComponent("versions.json"))
        let golden = try JSONDecoder().decode(Golden.self, from: data)
        XCTAssertEqual(golden.productVersion, HostwrightIdentity.version)
        XCTAssertEqual(golden.releaseTarget, HostwrightIdentity.releaseTarget)
        XCTAssertEqual(golden.manifest, HostwrightContractVersions.manifest)
        XCTAssertEqual(golden.controlAPI, HostwrightContractVersions.controlAPI)
        XCTAssertEqual(golden.runtimeProviderAPI, HostwrightContractVersions.runtimeProviderAPI)
        XCTAssertEqual(
            golden.storageProviderAPI,
            HostwrightContractVersions.storageProviderAPI
        )
        XCTAssertEqual(
            golden.networkProviderSPI,
            HostwrightContractVersions.networkProviderSPI
        )
        XCTAssertEqual(golden.pluginABI, HostwrightContractVersions.pluginABI)
        XCTAssertEqual(golden.stateSchema, HostwrightContractVersions.stateSchema)
    }

    private func contractRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2", isDirectory: true)
    }
}
