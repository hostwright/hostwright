import Foundation
import XCTest
import HostwrightAccelerator
@testable import HostwrightState

final class AcceleratorStateRecordTests: XCTestCase {
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testCanonicalAcceleratorPayloadRoundTripsThroughV23Envelope() throws {
        let payload = try makeInventory()
        let record = try AcceleratorInventoryStateRecord(
            recordID: snapshotID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: payload
        )
        let snapshot = try AcceleratorStateSnapshot(inventories: [record])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoded = try JSONDecoder().decode(
            AcceleratorStateSnapshot.self,
            from: encoder.encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.schemaVersion, AcceleratorStateSchema.currentVersion)
        XCTAssertEqual(decoded.inventories.first?.payload, payload)
        try decoded.validate()
    }

    func testEnvelopeRejectsFutureVersionUnknownFieldAndDigestTampering() throws {
        let record = try AcceleratorInventoryStateRecord(
            recordID: snapshotID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: try makeInventory()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(record)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["futureField"] = true
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventoryStateRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .unknownField
            )
        }

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = AcceleratorStateSchema.currentVersion + 1
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventoryStateRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .futureVersion
            )
        }

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["recordDigest"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventoryStateRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .invalidDigest
            )
        }
    }

    func testCanonicalZeroUUIDIsRejectedBeforeStatePersistence() throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertThrowsError(
            try AcceleratorInventorySnapshot(
                snapshotID: zero,
                hostID: hostID,
                observedAt: now,
                observedGeneration: 1,
                modeEvidence: try makeModeEvidence(),
                budgets: []
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorValidationError)?.code,
                .invalidIdentifier
            )
        }
    }

    func testPayloadDecoderRejectsUnknownNestedKeyAndRecordLogRejectsReplay() throws {
        let record = try AcceleratorInventoryStateRecord(
            recordID: snapshotID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: try makeInventory()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(record)
            ) as? [String: Any]
        )
        var payload = try XCTUnwrap(object["inventory"] as? [String: Any])
        payload["unexpectedNestedKey"] = true
        object["inventory"] = payload
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorInventoryStateRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .unknownField
            )
        }

        XCTAssertThrowsError(
            try AcceleratorInventoryStateRecord.validateAppendOnly(
                [record, record]
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .invalidOrdering
            )
        }
    }

    func testStateRecordBoundsAndVersionAreRejectedWithoutClamping() throws {
        struct TypedPayload: AcceleratorStatePayload {
            static let statePayloadKey = "inventory"
            let value: Int
        }

        let recordID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let record = try AcceleratorStateRecord(
            recordID: recordID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: TypedPayload(value: 1)
        )
        XCTAssertThrowsError(
            try AcceleratorStateRecord(
                recordID: recordID,
                sequence: 1,
                previousRecordDigest: nil,
                payload: TypedPayload(value: 1),
                schemaVersion: AcceleratorStateSchema.currentVersion + 1
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .futureVersion
            )
        }
        XCTAssertThrowsError(
            try AcceleratorStateRecord.validateAppendOnly(
                Array(
                    repeating: record,
                    count: AcceleratorStateSchema.maxArrayCount + 1
                )
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.code,
                .invalidOrdering
            )
        }
    }

    func testV23PayloadKeysCoverEveryAcceleratorAuthorityRecord() {
        XCTAssertEqual(AcceleratorInventorySnapshot.statePayloadKey, "inventory")
        XCTAssertEqual(AcceleratorClaim.statePayloadKey, "claim")
        XCTAssertEqual(AcceleratorReservation.statePayloadKey, "reservation")
        XCTAssertEqual(AcceleratorGrant.statePayloadKey, "grant")
        XCTAssertEqual(AcceleratorExecutionRequest.statePayloadKey, "execution")
        XCTAssertEqual(AcceleratorExecutionResult.statePayloadKey, "result")
        XCTAssertEqual(AcceleratorMeasuredUsage.statePayloadKey, "usage")
        XCTAssertEqual(AcceleratorExecutionProvenance.statePayloadKey, "provenance")
        XCTAssertEqual(AcceleratorCancellationRecord.statePayloadKey, "cancellation")
        XCTAssertEqual(AcceleratorRevocationRecord.statePayloadKey, "revocation")
    }

    func testDurableClaimRevocationRequiresThePersistedClaimIssuer() throws {
        let inventory = try makeInventory()
        let inventoryRecord = try AcceleratorInventoryStateRecord(
            recordID: inventory.snapshotID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: inventory
        )
        let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let claimID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let issuer = try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-owner",
            authenticationDigest: try AcceleratorDigest(String(repeating: "c", count: 64)),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let claim = try AcceleratorClaim(
            claimID: claimID,
            scope: .project(projectID: projectID),
            allowedModes: [.metal],
            modelHash: nil,
            quota: try AcceleratorQuota(
                budget: try AcceleratorBudgetVector(
                    memoryBytes: 1,
                    computeUnits: 1,
                    concurrencyUnits: 1
                ),
                maxInputBytes: 1,
                maxOutputBytes: 1,
                maxTimeoutMilliseconds: 1
            ),
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            issuer: issuer,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let claimRecord = try AcceleratorClaimStateRecord(
            recordID: claim.claimID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: claim
        )
        let attacker = try AcceleratorAuthenticationContext(
            subjectID: "subject-attacker",
            sessionID: "session-attacker",
            authenticationDigest: try AcceleratorDigest(String(repeating: "d", count: 64)),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let revocation = try AcceleratorRevocationRecord(
            revocationID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            targetKind: .claim,
            targetIdentifier: claim.claimID.uuidString.lowercased(),
            scope: claim.scope,
            fence: nil,
            actor: attacker,
            reason: "operator-request",
            evidenceDigest: try AcceleratorDigest(String(repeating: "e", count: 64)),
            revokedAt: now.addingTimeInterval(2)
        )
        let revocationRecord = try AcceleratorRevocationStateRecord(
            recordID: revocation.revocationID,
            sequence: 1,
            previousRecordDigest: nil,
            payload: revocation
        )

        XCTAssertThrowsError(
            try AcceleratorStateSnapshot(
                inventories: [inventoryRecord],
                claims: [claimRecord],
                revocations: [revocationRecord]
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorStateRecordValidationError)?.field,
                "revocation.claim"
            )
        }
    }

    private func makeInventory() throws -> AcceleratorInventorySnapshot {
        try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 1,
            modeEvidence: try makeModeEvidence(),
            budgets: []
        )
    }

    private func makeModeEvidence() throws -> [AcceleratorModeEvidence] {
        let digest = try AcceleratorDigest(String(repeating: "a", count: 64))
        let execution = try AcceleratorHostNativeExecutionEvidence(
            mode: .metal,
            backendIdentifier: "metal",
            frameworkIdentifier: "metal",
            operatingSystem: "macos",
            executionDigest: digest,
            provenanceDigest: digest,
            observedGeneration: 1,
            observedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        return [
            try AcceleratorModeEvidence(
                mode: .linuxGuestANEPassthrough,
                status: .blocked,
                evidenceDigest: digest,
                source: .contractBoundary,
                observedGeneration: 1,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .linuxGuestGPUPassthrough,
                status: .blocked,
                evidenceDigest: digest,
                source: .contractBoundary,
                observedGeneration: 1,
                reasonCode: .linuxGuestPassthroughBlocked
            ),
            try AcceleratorModeEvidence(
                mode: .metal,
                status: .available,
                evidenceDigest: digest,
                source: .hostNativeExecutionSelfTest,
                observedGeneration: 1,
                executionEvidence: execution
            )
        ]
    }
}
