import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProviderContractTests: XCTestCase {
    func testRuntimeMetadataAdvertisesProviderAPIV2() {
        let metadata = RuntimeAdapterMetadata(
            adapterName: "test-provider",
            adapterVersion: "1.0.0",
            runtimeName: "test-runtime",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )

        XCTAssertEqual(metadata.providerAPIVersion, HostwrightContractVersions.runtimeProviderAPI)
        XCTAssertNil(RuntimeProviderCompatibility.mutationIncompatibility(metadata))
    }

    func testMutationCompatibilityRejectsOtherProviderAPIVersions() {
        let metadata = RuntimeAdapterMetadata(
            providerAPIVersion: 1,
            adapterName: "legacy-provider",
            adapterVersion: "1.0.0",
            runtimeName: "legacy-runtime",
            supportsMutation: true,
            capabilities: [.lifecycleMutation]
        )

        XCTAssertEqual(
            RuntimeProviderCompatibility.mutationIncompatibility(metadata),
            "Runtime provider legacy-provider advertises API v1; Hostwright requires Runtime Provider API v2."
        )
    }

    func testCheckedInRuntimeProviderMetadataGoldenDecodesThroughProductionContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2/runtime-provider-metadata.json")
        let metadata = try JSONDecoder().decode(RuntimeAdapterMetadata.self, from: Data(contentsOf: root))

        XCTAssertEqual(metadata.providerAPIVersion, HostwrightContractVersions.runtimeProviderAPI)
        XCTAssertEqual(metadata.adapterName, "golden-provider")
        XCTAssertEqual(metadata.capabilities, [.readOnlyObservation, .lifecycleMutation])
        XCTAssertNil(RuntimeProviderCompatibility.mutationIncompatibility(metadata))
    }

    func testMutationContextRequiresVersionedUUIDAndGenerationBindings() {
        let valid = RuntimeMutationContext(
            operationID: "operation-1",
            resourceUUID: HostwrightResourceUUID.generate(),
            resourceGeneration: 1,
            projectResourceUUID: HostwrightResourceUUID.generate(),
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: HostwrightResourceUUID.generate()
        )
        XCTAssertNil(valid.validationIssue)

        let invalid = RuntimeMutationContext(
            providerAPIVersion: 1,
            operationID: "",
            resourceUUID: "runtime-name",
            resourceGeneration: 0,
            projectResourceUUID: "project-name",
            projectGeneration: 0,
            providerGeneration: 0,
            fencingToken: "stale"
        )
        XCTAssertNotNil(invalid.validationIssue)
    }
}
