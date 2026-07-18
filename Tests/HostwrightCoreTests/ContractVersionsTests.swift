import Foundation
import XCTest
@testable import HostwrightCore

final class ContractVersionsTests: XCTestCase {
    func testReleaseAndBreakingContractVersionsHaveOneAuthority() {
        XCTAssertNotNil(
            HostwrightIdentity.version.range(
                of: #"^0\.0\.2-dev\.[56]$"#,
                options: .regularExpression
            )
        )
        XCTAssertEqual(HostwrightIdentity.releaseTarget, "v0.0.2")
        XCTAssertEqual(HostwrightContractVersions.manifest, 2)
        XCTAssertEqual(HostwrightContractVersions.controlAPI, 2)
        XCTAssertEqual(HostwrightContractVersions.runtimeProviderAPI, 2)
        XCTAssertEqual(HostwrightContractVersions.pluginABI, 1)
        XCTAssertEqual(HostwrightContractVersions.stateSchema, 7)
    }

    func testCapabilityCatalogIsDeterministicUniqueAndCoversEveryRoadmapPhase() {
        let report = HostwrightCapabilityCatalog.report
        let identifiers = report.capabilities.map(\.identifier)

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.productVersion, HostwrightIdentity.version)
        XCTAssertEqual(report.releaseTarget, HostwrightIdentity.releaseTarget)
        XCTAssertEqual(report.contracts.manifest, HostwrightContractVersions.manifest)
        XCTAssertEqual(identifiers, identifiers.sorted())
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(Set(report.capabilities.map(\.phase)), Set(1...15))
        XCTAssertTrue(report.capabilities.allSatisfy { !$0.title.isEmpty && !$0.reason.isEmpty })
        XCTAssertTrue(report.capabilities.allSatisfy { $0.issue > 0 })

        let states = Set(report.capabilities.map(\.state))
        XCTAssertTrue(states.contains(.stable))
        XCTAssertTrue(states.contains(.experimental))
        XCTAssertTrue(states.contains(.unavailable))
        XCTAssertTrue(states.contains(.blocked))

        guard let secureSubprocess = report.capabilities.first(where: {
            $0.identifier == "foundation.secure-subprocess"
        }) else {
            return XCTFail("Secure subprocess capability is missing.")
        }
        XCTAssertEqual(secureSubprocess.state, .stable)
        XCTAssertEqual(secureSubprocess.issue, 116)

        guard let installedLifecycle = report.capabilities.first(where: {
            $0.identifier == "distribution.installed-lifecycle"
        }) else {
            return XCTFail("Installed distribution lifecycle capability is missing.")
        }
        XCTAssertEqual(installedLifecycle.state, .stable)
        XCTAssertEqual(installedLifecycle.issue, 118)

        guard let releaseEvidence = report.capabilities.first(where: {
            $0.identifier == "distribution.release-evidence"
        }) else {
            return XCTFail("Release evidence capability is missing.")
        }
        XCTAssertEqual(releaseEvidence.state, .experimental)
        XCTAssertEqual(releaseEvidence.issue, 119)
        XCTAssertEqual(
            Set(releaseEvidence.requiredEvidence),
            Set([.unitContract, .localIntegration, .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos])
        )
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
