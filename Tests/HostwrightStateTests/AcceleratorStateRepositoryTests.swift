import Foundation
import XCTest
@testable import HostwrightState

final class AcceleratorStateRepositoryTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        let value: Int
        let label: String
    }

    private struct ValuesPayload: Codable {
        let values: [Int]
    }

    private struct TypedPayload: AcceleratorStatePayload {
        static let statePayloadKey = "inventory"
        let value: Int
    }

    func testPeerStateRecordUsesSequenceDigestAndTypedReplay() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let first = try AcceleratorStateRecord(
                recordID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                sequence: 1,
                previousRecordDigest: nil,
                payload: TypedPayload(value: 1)
            )
            let second = try AcceleratorStateRecord(
                recordID: first.recordID,
                sequence: 2,
                previousRecordDigest: first.recordDigest,
                payload: TypedPayload(value: 2)
            )
            let firstEntry = try repository.append(
                first,
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "typed-1"
            )
            _ = try repository.append(
                second,
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 2),
                mutationID: "typed-2",
                expected: try AcceleratorStateRepositoryExpectedVersion(
                    generation: firstEntry.generation,
                    fence: firstEntry.fence
                )
            )
            XCTAssertEqual(
                try repository.replay(
                    AcceleratorStateRecord<TypedPayload>.self,
                    kind: .inventory
                ).map(\.payload.value),
                [1, 2]
            )
        }
    }

    func testAppendAllAuthorityKindsReopensAndReplaysDeterministically() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let observedAt = Date(timeIntervalSince1970: 1_754_000_000)

            let inventory = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-inventory"
            )
            let claim = try append(
                repository,
                kind: .claim,
                recordID: "claim-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-claim",
                dependencies: [dependency(inventory)]
            )
            let reservation = try append(
                repository,
                kind: .reservation,
                recordID: "reservation-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-reservation",
                dependencies: [dependency(inventory), dependency(claim)]
            )
            let grant = try append(
                repository,
                kind: .grant,
                recordID: "grant-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-grant",
                dependencies: [
                    dependency(inventory),
                    dependency(claim),
                    dependency(reservation)
                ]
            )
            let execution = try append(
                repository,
                kind: .executionRequest,
                recordID: "execution-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-execution",
                dependencies: [
                    dependency(inventory),
                    dependency(claim),
                    dependency(reservation),
                    dependency(grant)
                ]
            )
            let result = try append(
                repository,
                kind: .executionResult,
                recordID: "result-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-result",
                dependencies: [
                    dependency(execution),
                    dependency(grant),
                    dependency(reservation)
                ]
            )
            let usage = try append(
                repository,
                kind: .usage,
                recordID: "usage-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-usage",
                dependencies: [dependency(execution)]
            )
            let provenance = try append(
                repository,
                kind: .provenance,
                recordID: "provenance-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-provenance",
                dependencies: [dependency(execution)]
            )
            let cancellation = try append(
                repository,
                kind: .cancellation,
                recordID: "cancellation-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-cancellation",
                dependencies: [dependency(execution)]
            )
            _ = try append(
                repository,
                kind: .revocation,
                recordID: "revocation-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: observedAt,
                mutationID: "mutation-revocation"
            )

            XCTAssertEqual(
                try repository.allEntries().map(\.kind),
                [
                    .inventory, .claim, .reservation, .grant,
                    .executionRequest, .executionResult, .usage,
                    .provenance, .cancellation, .revocation
                ]
            )
            XCTAssertEqual(
                try repository.current(
                    Payload.self,
                    kind: .claim,
                    recordID: "claim-1",
                    scopeKey: "project:one"
                ),
                Payload(value: 1, label: "claim")
            )
            XCTAssertEqual(
                try repository.history(
                    kind: .executionRequest,
                    recordID: "execution-1",
                    scopeKey: "project:one"
                ).count,
                1
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .cancellation,
                    recordID: cancellation.recordID,
                    scopeKey: "project:one"
                ),
                cancellation
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .usage,
                    recordID: usage.recordID,
                    scopeKey: "project:one"
                )?.recordJSON,
                "{\"label\":\"usage\",\"value\":1}"
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .provenance,
                    recordID: provenance.recordID,
                    scopeKey: "project:one"
                )?.recordSHA256.count,
                64
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .executionResult,
                    recordID: result.recordID,
                    scopeKey: "project:one"
                ),
                result
            )

            let reopened = SQLiteStateStore(path: store.path)
            let reopenedRepository = AcceleratorStateRepository(store: reopened)
            XCTAssertEqual(
                try reopenedRepository.allEntries().map(\.eventID),
                try repository.allEntries().map(\.eventID)
            )
            XCTAssertEqual(
                try reopenedRepository.replay(
                    Payload.self,
                    kind: .claim,
                    recordID: "claim-1",
                    scopeKey: "project:one"
                ),
                [Payload(value: 1, label: "claim")]
            )
        }
    }

    func testReplacementRequiresExpectedVersionAndPreservesAppendOnlyHistory() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let first = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 10),
                mutationID: "mutation-1"
            )

            XCTAssertEqual(
                try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 10),
                    mutationID: "mutation-1"
                ),
                first
            )
            assertRepositoryError(.idempotencyConflict) {
                _ = try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 10),
                    mutationID: "mutation-1",
                    value: 2
                )
            }
            assertRepositoryError(.expectedVersionRequired) {
                _ = try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 11),
                    mutationID: "mutation-2",
                    value: 2,
                    generation: 2
                )
            }

            let expected = try AcceleratorStateRepositoryExpectedVersion(
                generation: first.generation,
                fence: first.fence
            )
            let second = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: try makeFence(nodeEpoch: 1, reservationSequence: 2),
                observedAt: Date(timeIntervalSince1970: 11),
                mutationID: "mutation-2",
                value: 2,
                expected: expected
            )
            XCTAssertEqual(second.generation, 2)
            XCTAssertEqual(
                try repository.log(kind: .inventory).count,
                2
            )

            assertRepositoryError(.expectedVersionMismatch) {
                _ = try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: try makeFence(nodeEpoch: 1, reservationSequence: 2),
                    observedAt: Date(timeIntervalSince1970: 12),
                    mutationID: "mutation-3",
                    value: 3,
                    expected: expected
                )
            }
            assertRepositoryError(.fenceConflict) {
                let lowerFence = fence
                _ = try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: lowerFence,
                    observedAt: Date(timeIntervalSince1970: 12),
                    mutationID: "mutation-3",
                    value: 3,
                    expected: try AcceleratorStateRepositoryExpectedVersion(
                        generation: second.generation,
                        fence: second.fence
                    )
                )
            }
            assertRepositoryError(.observedTimeRegression) {
                _ = try append(
                    repository,
                    kind: .inventory,
                    recordID: "inventory-1",
                    fence: try makeFence(nodeEpoch: 1, reservationSequence: 2),
                    observedAt: Date(timeIntervalSince1970: 9),
                    mutationID: "mutation-3",
                    value: 3,
                    expected: try AcceleratorStateRepositoryExpectedVersion(
                        generation: second.generation,
                        fence: second.fence
                    )
                )
            }
        }
    }

    func testDependencyBindingIsTransactionalAndRejectsStaleParents() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let inventory = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 10),
                mutationID: "inventory-1"
            )
            let claim = try append(
                repository,
                kind: .claim,
                recordID: "claim-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 10),
                mutationID: "claim-1",
                dependencies: [dependency(inventory)]
            )
            let reservation = try append(
                repository,
                kind: .reservation,
                recordID: "reservation-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 10),
                mutationID: "reservation-1",
                dependencies: [dependency(inventory), dependency(claim)]
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .claim,
                    recordID: "claim-1",
                    scopeKey: "project:one"
                ),
                claim
            )

            let updatedClaim = try append(
                repository,
                kind: .claim,
                recordID: "claim-1",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 11),
                mutationID: "claim-2",
                value: 2,
                dependencies: [dependency(inventory)],
                expected: try AcceleratorStateRepositoryExpectedVersion(
                    generation: claim.generation,
                    fence: claim.fence
                )
            )
            assertRepositoryError(
                .dependencyChanged(kind: .claim, recordID: "claim-1")
            ) {
                _ = try append(
                    repository,
                    kind: .reservation,
                    recordID: "reservation-1",
                    scopeKey: "project:one",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 12),
                    mutationID: "reservation-2",
                    value: 2,
                    dependencies: [dependency(inventory), dependency(claim)],
                    expected: try AcceleratorStateRepositoryExpectedVersion(
                        generation: reservation.generation,
                        fence: reservation.fence
                    )
                )
            }
            XCTAssertEqual(
                try repository.current(
                    kind: .reservation,
                    recordID: "reservation-1",
                    scopeKey: "project:one"
                ),
                reservation
            )
            XCTAssertEqual(updatedClaim.generation, 2)

            assertRepositoryError(
                .missingDependency(kind: .inventory, recordID: "missing")
            ) {
                _ = try append(
                    repository,
                    kind: .claim,
                    recordID: "claim-missing",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 12),
                    mutationID: "claim-missing",
                    dependencies: [
                        try AcceleratorStateRepositoryDependency(
                            kind: .inventory,
                            recordID: "missing",
                            generation: 1,
                            fence: fence
                        )
                    ]
                )
            }
        }
    }

    func testHistoricalReplayPinsTheReferencedDependencyGeneration() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let inventoryV1 = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-history",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "inventory-history-1"
            )
            let claim = try append(
                repository,
                kind: .claim,
                recordID: "claim-history",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 2),
                mutationID: "claim-history-1",
                dependencies: [dependency(inventoryV1)]
            )
            let inventoryV2 = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-history",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 3),
                mutationID: "inventory-history-2",
                value: 2,
                expected: try expectedVersion(inventoryV1)
            )

            XCTAssertEqual(
                try repository.log(kind: .claim),
                [claim]
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .inventory,
                    recordID: "inventory-history"
                ),
                inventoryV2
            )
            assertRepositoryError(
                .dependencyChanged(kind: .inventory, recordID: "inventory-history")
            ) {
                _ = try append(
                    repository,
                    kind: .claim,
                    recordID: "claim-history-new",
                    scopeKey: "project:one",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 4),
                    mutationID: "claim-history-stale",
                    dependencies: [dependency(inventoryV1)]
                )
            }
        }
    }

    func testPayloadAndNodeBudgetsFailClosed() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            assertRepositoryError(.payloadTooLarge) {
                _ = try repository.append(
                    kind: .inventory,
                    recordID: "large",
                    generation: 1,
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 1),
                    mutationID: "large",
                    record: Payload(
                        value: 1,
                        label: String(
                            repeating: "x",
                            count: AcceleratorStateRepository.maximumPayloadBytes
                        )
                    )
                )
            }
            assertRepositoryError(.nodeBudgetExceeded) {
                _ = try repository.append(
                    kind: .inventory,
                    recordID: "nodes",
                    generation: 1,
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 1),
                    mutationID: "nodes",
                    record: ValuesPayload(
                        values: Array(
                            0..<(AcceleratorStateRepository.maximumJSONNodes + 10)
                        )
                    )
                )
            }
        }
    }

    func testPersistedUnknownEnvelopeKeyFailsClosed() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let entry = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: try makeFence(),
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "mutation-1"
            )
            try store.withValidatedConnection { connection in
                guard let payload = try connection.query(
                    "SELECT payload_json_redacted FROM accelerator_state_current WHERE id = ?",
                    bindings: [.text(entry.eventID)]
                ).first?.first ?? nil else {
                    throw StateStoreError.invalidRecord("Test event was not persisted.")
                }
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: Data(payload.utf8),
                        options: [.fragmentsAllowed]
                    ) as? [String: Any]
                )
                object["futureField"] = true
                let tampered = try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
                try connection.run(
                    "UPDATE accelerator_state_current SET payload_json_redacted = ? WHERE id = ?",
                    bindings: [
                        .text(String(decoding: tampered, as: UTF8.self)),
                        .text(entry.eventID)
                    ]
                )
            }
            assertRepositoryError(.unknownKey(field: "futureField")) {
                _ = try repository.current(
                    kind: .inventory,
                    recordID: "inventory-1"
                )
            }
        }
    }

    func testPersistedDuplicateEnvelopeKeyFailsClosed() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let entry = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-1",
                fence: try makeFence(),
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "mutation-1"
            )
            try store.withValidatedConnection { connection in
                guard let payload = try connection.query(
                    "SELECT payload_json_redacted FROM accelerator_state_current WHERE id = ?",
                    bindings: [.text(entry.eventID)]
                ).first?.first ?? nil else {
                    throw StateStoreError.invalidRecord("Test event was not persisted.")
                }
                let duplicate = payload.replacingOccurrences(
                    of: "\"kind\":\"inventory\"",
                    with: "\"kind\":\"inventory\",\"kind\":\"inventory\""
                )
                guard duplicate != payload else {
                    throw StateStoreError.invalidRecord("Test envelope did not contain its kind key.")
                }
                try connection.run(
                    "UPDATE accelerator_state_current SET payload_json_redacted = ? WHERE id = ?",
                    bindings: [.text(duplicate), .text(entry.eventID)]
                )
            }
            assertRepositoryError(.duplicateKey) {
                _ = try repository.current(
                    kind: .inventory,
                    recordID: "inventory-1"
                )
            }
        }
    }

    func testPersistedEnvelopeVersionDistinguishesJSONNumberFromBoolean() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let entry = try append(
                repository,
                kind: .inventory,
                recordID: "numeric-envelope-version",
                fence: try makeFence(),
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "numeric-envelope-version"
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .inventory,
                    recordID: entry.recordID
                ),
                entry
            )

            try store.withConnection { connection in
                guard let payload = try connection.query(
                    "SELECT payload_json_redacted FROM accelerator_state_current WHERE id = ?",
                    bindings: [.text(entry.eventID)]
                ).first?.first.flatMap({ $0 }) else {
                    throw StateStoreError.invalidRecord("Test envelope was not persisted.")
                }
                let booleanVersion = payload.replacingOccurrences(
                    of: "\"envelopeVersion\":1",
                    with: "\"envelopeVersion\":true"
                )
                guard booleanVersion != payload else {
                    throw StateStoreError.invalidRecord("Test envelope did not contain a numeric version.")
                }
                try connection.run(
                    "UPDATE accelerator_state_current SET payload_json_redacted = ? WHERE id = ?",
                    bindings: [.text(booleanVersion), .text(entry.eventID)]
                )
            }

            assertRepositoryError(.unsupportedPersistedVersion) {
                _ = try repository.current(
                    kind: .inventory,
                    recordID: entry.recordID
                )
            }
        }
    }

    func testAuthorityUsesDedicatedJournalAndCurrentTables() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let entry = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-dedicated",
                fence: try makeFence(),
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "dedicated-mutation"
            )
            try store.withValidatedConnection(readOnly: true) { connection in
                let journalCount = try connection.query(
                    "SELECT COUNT(*) FROM accelerator_state_journal"
                ).first?.first.flatMap { $0 }
                let currentCount = try connection.query(
                    "SELECT COUNT(*) FROM accelerator_state_current"
                ).first?.first.flatMap { $0 }
                let eventCount = try connection.query(
                    "SELECT COUNT(*) FROM event_ledger WHERE source = ?",
                    bindings: [.text("accelerator-state-journal")]
                ).first?.first.flatMap { $0 }
                XCTAssertEqual(journalCount, "1")
                XCTAssertEqual(currentCount, "1")
                XCTAssertEqual(eventCount, "0")
                XCTAssertEqual(
                    try connection.query(
                        "SELECT record_id FROM accelerator_state_current WHERE type = ?",
                        bindings: [.text("accelerator.state.inventory")]
                    ).first?.first.flatMap { $0 },
                    entry.recordID
                )
                let timestampRow = try connection.query(
                    "SELECT timestamp, julianday(timestamp) "
                        + "FROM accelerator_state_journal WHERE id = ?",
                    bindings: [.text(entry.eventID)]
                ).first
                let timestamp = timestampRow?.first.flatMap { $0 }
                let julianDay = timestampRow?.dropFirst().first.flatMap { $0 }
                XCTAssertTrue(timestamp?.contains("T") == true)
                XCTAssertNotNil(julianDay)
            }
            let reopened = SQLiteStateStore(path: store.path)
            XCTAssertEqual(
                try reopened.acceleratorState.current(
                    kind: .inventory,
                    recordID: entry.recordID
                ),
                entry
            )
        }
    }

    func testCurrentGenerationAndHistoryAreIndependentPerRecordAndProject() throws {
        try withStore { store in
            let repository = AcceleratorStateRepository(store: store)
            let fence = try makeFence()
            let inventory = try append(
                repository,
                kind: .inventory,
                recordID: "inventory-shared",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 0),
                mutationID: "inventory-shared"
            )
            let firstProject = try append(
                repository,
                kind: .claim,
                recordID: "claim-shared",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 1),
                mutationID: "claim-one-1",
                dependencies: [dependency(inventory)]
            )
            let firstOtherProject = try append(
                repository,
                kind: .claim,
                recordID: "claim-shared",
                scopeKey: "project:two",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 2),
                mutationID: "claim-two-1",
                dependencies: [dependency(inventory)]
            )
            let secondProject = try append(
                repository,
                kind: .claim,
                recordID: "claim-shared",
                scopeKey: "project:one",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 3),
                mutationID: "claim-one-2",
                value: 2,
                dependencies: [dependency(inventory)],
                expected: try expectedVersion(firstProject)
            )
            let secondOtherProject = try append(
                repository,
                kind: .claim,
                recordID: "claim-shared",
                scopeKey: "project:two",
                fence: fence,
                observedAt: Date(timeIntervalSince1970: 4),
                mutationID: "claim-two-2",
                value: 2,
                dependencies: [dependency(inventory)],
                expected: try expectedVersion(firstOtherProject)
            )

            XCTAssertEqual(
                try repository.current(
                    kind: .claim,
                    recordID: "claim-shared",
                    scopeKey: "project:one"
                ),
                secondProject
            )
            XCTAssertEqual(
                try repository.current(
                    kind: .claim,
                    recordID: "claim-shared",
                    scopeKey: "project:two"
                ),
                secondOtherProject
            )
            XCTAssertEqual(
                try repository.history(
                    kind: .claim,
                    recordID: "claim-shared",
                    scopeKey: "project:one"
                ).count,
                2
            )
            XCTAssertEqual(
                try repository.history(
                    kind: .claim,
                    recordID: "claim-shared",
                    scopeKey: "project:two"
                ).count,
                2
            )

            assertRepositoryError(.expectedVersionMismatch) {
                _ = try append(
                    repository,
                    kind: .claim,
                    recordID: "claim-shared",
                    scopeKey: "project:two",
                    fence: fence,
                    observedAt: Date(timeIntervalSince1970: 5),
                    mutationID: "claim-two-cross-project",
                    value: 3,
                    dependencies: [dependency(inventory)],
                    expected: try expectedVersion(firstProject)
                )
            }
            try store.withValidatedConnection(readOnly: true) { connection in
                let scopes = try connection.query(
                    "SELECT project_id FROM accelerator_state_current "
                        + "WHERE type = ? AND record_id = ? ORDER BY project_id",
                    bindings: [
                        .text("accelerator.state.claim"),
                        .text("claim-shared")
                    ]
                ).compactMap { $0.first.flatMap { $0 } }
                XCTAssertEqual(scopes, ["project:one", "project:two"])
            }
        }
    }

    private func append(
        _ repository: AcceleratorStateRepository,
        kind: AcceleratorStateRepositoryKind,
        recordID: String,
        scopeKey: String? = nil,
        fence: AcceleratorStateRepositoryFence,
        observedAt: Date,
        mutationID: String,
        value: Int = 1,
        generation: Int64? = nil,
        dependencies: [AcceleratorStateRepositoryDependency] = [],
        expected: AcceleratorStateRepositoryExpectedVersion? = nil
    ) throws -> AcceleratorStateRepositoryEntry {
        try repository.append(
            kind: kind,
            recordID: recordID,
            scopeKey: scopeKey,
            generation: generation ?? (expected.map { $0.generation + 1 } ?? 1),
            fence: fence,
            observedAt: observedAt,
            mutationID: mutationID,
            dependencies: ordered(dependencies),
            expected: expected,
            record: Payload(value: value, label: kind.rawValue)
        )
    }

    private func ordered(
        _ dependencies: [AcceleratorStateRepositoryDependency]
    ) -> [AcceleratorStateRepositoryDependency] {
        dependencies.sorted {
            let lhs = $0.kind.rawValue + ":" + $0.recordID
            let rhs = $1.kind.rawValue + ":" + $1.recordID
            return lhs < rhs
        }
    }

    private func dependency(
        _ entry: AcceleratorStateRepositoryEntry
    ) throws -> AcceleratorStateRepositoryDependency {
        try AcceleratorStateRepositoryDependency(
            kind: entry.kind,
            recordID: entry.recordID,
            scopeKey: entry.scopeKey,
            generation: entry.generation,
            fence: entry.fence
        )
    }

    private func expectedVersion(
        _ entry: AcceleratorStateRepositoryEntry
    ) throws -> AcceleratorStateRepositoryExpectedVersion {
        try AcceleratorStateRepositoryExpectedVersion(
            generation: entry.generation,
            fence: entry.fence
        )
    }

    private func makeFence(
        nodeEpoch: Int64 = 1,
        reservationSequence: Int64 = 1
    ) throws -> AcceleratorStateRepositoryFence {
        try AcceleratorStateRepositoryFence(
            nodeEpoch: nodeEpoch,
            reservationSequence: reservationSequence
        )
    }

    private func assertRepositoryError(
        _ expected: AcceleratorStateRepositoryError,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body()) { error in
            XCTAssertEqual(error as? AcceleratorStateRepositoryError, expected)
        }
    }

    private func withStore(
        _ body: (SQLiteStateStore) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-accelerator-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(
            path: root.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        try body(store)
    }
}
