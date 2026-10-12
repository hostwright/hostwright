import Foundation
@testable import HostwrightDistribution
import XCTest

final class DistributionThirdPartyNoticesTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAllResolvedHostPinsAndNestedAttributionTextsArePreserved() throws {
        let notices = try DistributionThirdPartyNotices.read(root().appendingPathComponent("THIRD_PARTY_NOTICES"))
        let inventory = try DistributionThirdPartyNotices.decode(ThirdPartyLicenseInventory.self,
            data: DistributionThirdPartyNotices.read(root().appendingPathComponent("third-party-license-inventory.json")))
        let runtime = try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self,
            data: DistributionThirdPartyNotices.read(root().appendingPathComponent("runtime-license-inventory.json")))
        XCTAssertNoThrow(try DistributionThirdPartyNotices.validate(notices: notices, inventory: inventory, runtime: runtime))
        XCTAssertEqual(inventory.dependencies.count, 31)
        XCTAssertEqual(runtime.guestDependencies.count, 27)
        XCTAssertEqual(runtime.goDependencies.count, 7)
        for identity in ["swift-crypto", "swift-nio-ssl"] {
            let dependency = try XCTUnwrap(inventory.dependencies.first { $0.identity == identity })
            XCTAssertTrue(dependency.documents.contains { $0.category == "upstream-bundled-license" })
            XCTAssertTrue(dependency.documents.contains { $0.category == "source-license-header" })
        }
        XCTAssertTrue(inventory.runtimeDocuments.contains { $0.category == "runtime-license" })
        XCTAssertTrue(inventory.runtimeDocuments.contains { $0.category == "runtime-go-license" })
        XCTAssertTrue(inventory.runtimeDocuments.contains { $0.category == "runtime-go-toolchain-license" })
    }

    func testMissingOrAlteredNoticeTextAndNoncanonicalInventoryAreRefused() throws {
        var notices = try DistributionThirdPartyNotices.read(root().appendingPathComponent("THIRD_PARTY_NOTICES"))
        let data = try DistributionThirdPartyNotices.read(root().appendingPathComponent("third-party-license-inventory.json"))
        let inventory = try DistributionThirdPartyNotices.decode(ThirdPartyLicenseInventory.self, data: data)
        let runtime = try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self,
            data: DistributionThirdPartyNotices.read(root().appendingPathComponent("runtime-license-inventory.json")))
        notices[0] ^= 1
        XCTAssertThrowsError(try DistributionThirdPartyNotices.validate(notices: notices, inventory: inventory, runtime: runtime))
        XCTAssertThrowsError(try DistributionThirdPartyNotices.validate(notices: Data(), inventory: inventory, runtime: runtime))
        XCTAssertThrowsError(try DistributionThirdPartyNotices.decode(ThirdPartyLicenseInventory.self, data: data + Data(" ".utf8)))
    }

    func testShippedRuntimeInventoryBindsEveryActualAssetAndRefusesChangedPins() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hostwright-notices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let assets = try makeDistributionTestContainerizationAssets(at: scratch)
        let payload = try DistributionThirdPartyNotices.sourcePayload(root: root(), runtimeAssets: assets)
        let runtime = try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self,
            data: XCTUnwrap(payload[DistributionThirdPartyNotices.runtimeInventoryPath]))
        XCTAssertEqual(Set(runtime.payloadFiles.map(\.path)), Set(DistributionContainerizationAssets.payloadModes.keys))
        XCTAssertTrue(runtime.payloadFiles.allSatisfy { !$0.sha256.isEmpty && $0.sizeBytes > 0 })
        let changed = scratch.appendingPathComponent("changed-source")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
        for name in ["THIRD_PARTY_NOTICES", "third-party-license-inventory.json", "runtime-license-inventory.json"] {
            try FileManager.default.copyItem(at: root().appendingPathComponent(name), to: changed.appendingPathComponent(name))
        }
        try Data("{\"pins\":[]}\n".utf8).write(to: changed.appendingPathComponent("Package.resolved"))
        XCTAssertThrowsError(try DistributionThirdPartyNotices.sourcePayload(root: changed, runtimeAssets: assets))
    }

    func testRuntimeCorrespondingSourceQualificationUsesTheCommittedEvidenceState() throws {
        let repository = root()
        XCTAssertNoThrow(try DistributionThirdPartyNotices.requireQualifiedRuntimeSource(root: repository))

        let data = try DistributionThirdPartyNotices.read(repository.appendingPathComponent("runtime-license-inventory.json"))
        var inventory = try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self, data: data)
        let qualified = inventory.assets[0]
        inventory.assets[0] = RuntimeLicenseAsset(
            identity: qualified.identity,
            payloadPaths: qualified.payloadPaths,
            sha256: qualified.sha256,
            sizeBytes: qualified.sizeBytes,
            licenseExpression: qualified.licenseExpression,
            status: qualified.status,
            sourceReferences: qualified.sourceReferences,
            blockers: ["test-only missing source coverage"],
            sourceDistributionEvidence: qualified.sourceDistributionEvidence
        )

        try withTemporaryRoot { temporary in
            try DistributionThirdPartyNotices.encode(inventory)
                .write(to: temporary.appendingPathComponent("runtime-license-inventory.json"))
            XCTAssertThrowsError(try DistributionThirdPartyNotices.requireQualifiedRuntimeSource(root: temporary)) { error in
                guard case let DistributionError.invalidArtifact(message) = error else {
                    return XCTFail("Expected incomplete source evidence to be refused, received \(error)")
                }
                XCTAssertEqual(
                    message,
                    "Trusted release blocked: runtime corresponding-source, build provenance, or component-license evidence remains incomplete. See runtime-license-inventory.json."
                )
            }
        }
    }

    func testSchemaThreeRequiresNoticesAndHistoricalSchemaTwoLayoutRemainsVerifiable() {
        let current = Set(DistributionLayout.payloadModes.keys)
        XCTAssertNotNil(DistributionLayout.artifactPayloadModes(schemaVersion: 3, paths: current))
        XCTAssertNil(DistributionLayout.artifactPayloadModes(schemaVersion: 2, paths: current))
        XCTAssertNil(DistributionLayout.artifactPayloadModes(schemaVersion: 3,
            paths: current.subtracting(DistributionThirdPartyNotices.payloadModes.keys)))
        XCTAssertNotNil(DistributionLayout.artifactPayloadModes(schemaVersion: 2,
            paths: Set(DistributionLayout.legacyPayloadModesV5.keys)))
        XCTAssertNotNil(DistributionLayout.trustedPayloadModes(schemaVersion: 2,
            paths: Set(DistributionLayout.legacyPayloadModesV4.keys)))
    }

    func testKernelRecipeMetadataSurvivesPackagingAndRejectsChangedSource() throws {
        let runtimeData = try DistributionThirdPartyNotices.read(root().appendingPathComponent("runtime-license-inventory.json"))
        let runtime = try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self, data: runtimeData)
        XCTAssertEqual(try DistributionThirdPartyNotices.encode(runtime), runtimeData)
        XCTAssertEqual(runtime.kernelSourceEvidence.recipePath, "scripts/release/qualify-kernel-candidate.py")
        XCTAssertEqual(runtime.kernelSourceEvidence.recipeRevisionKind, "git-blob-sha1")
        XCTAssertNoThrow(try DistributionThirdPartyNotices.validateKernelRecipe(root: root(), evidence: runtime.kernelSourceEvidence))
        try withTemporaryRoot { temporary in
            let recipe = temporary.appendingPathComponent(runtime.kernelSourceEvidence.recipePath)
            try FileManager.default.createDirectory(at: recipe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("changed recipe\n".utf8).write(to: recipe)
            XCTAssertThrowsError(try DistributionThirdPartyNotices.validateKernelRecipe(root: temporary, evidence: runtime.kernelSourceEvidence))
        }
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: runtimeData) as? [String: Any])
        var evidence = try XCTUnwrap(document["kernelSourceEvidence"] as? [String: Any])
        for key in ["recipePath", "recipeRevisionKind"] {
            let original = evidence.removeValue(forKey: key)
            document["kernelSourceEvidence"] = evidence
            let changed = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
            XCTAssertThrowsError(try DistributionThirdPartyNotices.decode(RuntimeLicenseInventory.self, data: changed))
            evidence[key] = original
        }
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-runtime-qualification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary)
    }
}
