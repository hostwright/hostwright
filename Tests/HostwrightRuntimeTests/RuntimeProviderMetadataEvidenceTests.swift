import XCTest
@testable import HostwrightRuntime

final class RuntimeProviderMetadataEvidenceTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testLegacyStringArrayDefaultsToRevisionOneWithoutExposingEntries() throws {
        let evidence = try RuntimeProviderMetadataEvidence.parse(
            capabilitiesJSON: #"["readOnlyObservation","lifecycleMutation"]"#
        )

        XCTAssertTrue(evidence.isLegacy)
        XCTAssertEqual(evidence.providerMetadataRevision, 1)
        XCTAssertNil(evidence.capabilitySHA256)
    }

    func testCanonicalEvidenceAppendsBoundedReservedSuffixWithoutChangingCapabilities() throws {
        let capabilities = ["readOnlyObservation", "lifecycleMutation"]
        let entries = try RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
            to: capabilities,
            capabilitySHA256: digest
        )

        XCTAssertEqual(Array(entries.prefix(capabilities.count)), capabilities)
        XCTAssertEqual(
            entries.suffix(2),
            [
                RuntimeProviderMetadataEvidence.capabilitySHA256MarkerPrefix + digest,
                RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "2"
            ]
        )
        let evidence = try RuntimeProviderMetadataEvidence.parse(entries: entries)
        XCTAssertFalse(evidence.isLegacy)
        XCTAssertEqual(evidence.providerMetadataRevision, 2)
        XCTAssertEqual(evidence.capabilitySHA256, digest)
    }

    func testDuplicateIncompleteAndMalformedReservedEvidenceIsRejected() throws {
        let capabilityMarker = RuntimeProviderMetadataEvidence.capabilitySHA256MarkerPrefix + digest
        let revisionMarker = RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "2"

        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(
                entries: [capabilityMarker, capabilityMarker, revisionMarker]
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .duplicateReservedEvidence)
        }
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(entries: [capabilityMarker])
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .incompleteReservedEvidence)
        }
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(entries: [revisionMarker])
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .incompleteReservedEvidence)
        }
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(
                entries: [
                    RuntimeProviderMetadataEvidence.capabilitySHA256MarkerPrefix + digest.uppercased(),
                    revisionMarker
                ]
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .malformedReservedEvidence)
        }
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(capabilitiesJSON: #"["readOnlyObservation",1]"#)
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .invalidJSONStringArray)
        }
    }

    func testEvidenceParsingIsBoundedAndErrorsNeverContainInput() {
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(
                entries: Array(repeating: "readOnlyObservation", count: 65)
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .tooManyEntries)
        }

        let secret = "token=super-secret-recovery-value"
        XCTAssertThrowsError(
            try RuntimeProviderMetadataEvidence.parse(
                entries: ["hostwright.provider-metadata.\(secret)"]
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderMetadataEvidenceError, .malformedReservedEvidence)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }
}
