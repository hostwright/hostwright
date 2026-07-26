import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageSemanticEngineTests: XCTestCase {
    private let engine = StorageSemanticEngine()
    private let volumeID = "11111111-1111-4111-8111-111111111111"
    private let restoredVolumeID =
        "22222222-2222-4222-8222-222222222222"
    private let snapshotID = "33333333-3333-4333-8333-333333333333"
    private let fence = "44444444-4444-4444-8444-444444444444"

    func testCompleteControllerAndNodeLifecycleIsIdempotent() throws {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        var state = try StorageSemanticState(
            topology: topology,
            totalCapacityBytes: 1_000
        )

        var transition = try engine.apply(
            request(.capacity, topology: topology),
            to: state
        )
        XCTAssertEqual(transition.result.availableCapacityBytes, 1_000)
        XCTAssertEqual(transition.result.disposition, .observed)

        let create = try request(
            .create,
            volumeID: volumeID,
            volumeName: "database",
            capacityBytes: 400,
            topology: topology,
            accessMode: .readWriteOnce
        )
        transition = try engine.apply(create, to: state)
        XCTAssertEqual(transition.result.disposition, .performed)
        state = transition.state
        XCTAssertEqual(state.availableCapacityBytes, 600)
        XCTAssertEqual(
            try engine.apply(create, to: state).result.disposition,
            .alreadySatisfied
        )

        transition = try engine.apply(
            request(
                .health,
                volumeID: volumeID
            ),
            to: state
        )
        XCTAssertEqual(transition.result.health, .healthy)

        let stage = try request(
            .stage,
            volumeID: volumeID,
            topology: topology,
            stagingPath: "/var/tmp/hostwright/stage/database"
        )
        transition = try engine.apply(stage, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(stage, to: state).result.disposition,
            .alreadySatisfied
        )

        let publish = try request(
            .publish,
            volumeID: volumeID,
            topology: topology,
            stagingPath: "/var/tmp/hostwright/stage/database",
            targetPath: "/var/tmp/hostwright/publish/database",
            readOnly: false
        )
        transition = try engine.apply(publish, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(publish, to: state).result.disposition,
            .alreadySatisfied
        )

        let snapshot = try request(
            .snapshot,
            volumeID: volumeID,
            snapshotID: snapshotID,
            snapshotName: "database-snapshot"
        )
        transition = try engine.apply(snapshot, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(snapshot, to: state).result.disposition,
            .alreadySatisfied
        )

        let expand = try request(
            .expand,
            volumeID: volumeID,
            capacityBytes: 500
        )
        transition = try engine.apply(expand, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(expand, to: state).result.disposition,
            .alreadySatisfied
        )

        let unpublish = try request(
            .unpublish,
            volumeID: volumeID,
            topology: topology,
            targetPath: "/var/tmp/hostwright/publish/database"
        )
        transition = try engine.apply(unpublish, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(unpublish, to: state).result.disposition,
            .alreadySatisfied
        )

        let unstage = try request(
            .unstage,
            volumeID: volumeID,
            topology: topology,
            stagingPath: "/var/tmp/hostwright/stage/database"
        )
        transition = try engine.apply(unstage, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(unstage, to: state).result.disposition,
            .alreadySatisfied
        )

        let delete = try request(.delete, volumeID: volumeID)
        transition = try engine.apply(delete, to: state)
        state = transition.state
        XCTAssertEqual(
            try engine.apply(delete, to: state).result.disposition,
            .alreadySatisfied
        )

        let restore = try request(
            .restore,
            volumeID: restoredVolumeID,
            volumeName: "database-restored",
            snapshotID: snapshotID,
            capacityBytes: 400,
            topology: topology,
            accessMode: .readWriteOnce
        )
        transition = try engine.apply(restore, to: state)
        XCTAssertEqual(transition.result.disposition, .performed)
        XCTAssertEqual(
            transition.state.volumes.first?.sourceSnapshotID,
            snapshotID
        )
        XCTAssertEqual(
            try engine.apply(
                restore,
                to: transition.state
            ).result.disposition,
            .alreadySatisfied
        )
    }

    func testReorderedCallsFailWithoutPretendSuccess() throws {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        var state = try createdState(topology: topology)

        XCTAssertStorageFailure(
            try request(
                .publish,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage",
                targetPath: "/var/tmp/publish",
                readOnly: false
            ),
            state: state,
            code: .failedPrecondition,
            retry: .never
        )

        state = try engine.apply(
            request(
                .stage,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage"
            ),
            to: state
        ).state
        state = try engine.apply(
            request(
                .publish,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage",
                targetPath: "/var/tmp/publish",
                readOnly: false
            ),
            to: state
        ).state

        XCTAssertStorageFailure(
            try request(
                .unstage,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage"
            ),
            state: state,
            code: .failedPrecondition,
            retry: .never
        )
        XCTAssertStorageFailure(
            try request(.delete, volumeID: volumeID),
            state: state,
            code: .failedPrecondition,
            retry: .never
        )
    }

    func testStaleGenerationFenceAndInterruptionsHaveStableRetryClasses()
        throws
    {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        let state = try createdState(topology: topology)

        let stale = try context(generation: 2)
        XCTAssertStorageFailure(
            try StorageSemanticRequest(
                operation: .delete,
                context: stale,
                volumeID: volumeID
            ),
            state: state,
            code: .staleGeneration,
            retry: .safeAfterObservation
        )

        let wrongFence = try context(
            fencingToken:
                "55555555-5555-4555-8555-555555555555"
        )
        XCTAssertStorageFailure(
            try StorageSemanticRequest(
                operation: .delete,
                context: wrongFence,
                volumeID: volumeID
            ),
            state: state,
            code: .fencingConflict,
            retry: .safeAfterObservation
        )

        for (interruption, code, retry) in [
            (
                StorageSemanticInterruption.cancelled,
                StorageSemanticErrorCode.cancelled,
                StorageSemanticRetryClass.safeAfterObservation
            ),
            (
                .timedOut,
                .timedOut,
                .safeAfterObservation
            ),
            (
                .ambiguousEffect,
                .ambiguousEffect,
                .resumeFromCheckpoint
            )
        ] {
            let request = try StorageSemanticRequest(
                operation: .delete,
                context: context(interruption: interruption),
                volumeID: volumeID
            )
            XCTAssertStorageFailure(
                request,
                state: state,
                code: code,
                retry: retry
            )
        }
    }

    func testReadOnlyManyRejectsReadWritePublish() throws {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        var state = try StorageSemanticState(
            topology: topology,
            totalCapacityBytes: 1_000
        )
        state = try engine.apply(
            request(
                .create,
                volumeID: volumeID,
                volumeName: "shared",
                capacityBytes: 100,
                topology: topology,
                accessMode: .readOnlyMany
            ),
            to: state
        ).state
        state = try engine.apply(
            request(
                .stage,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage"
            ),
            to: state
        ).state

        XCTAssertStorageFailure(
            try request(
                .publish,
                volumeID: volumeID,
                topology: topology,
                stagingPath: "/var/tmp/stage",
                targetPath: "/var/tmp/publish",
                readOnly: false
            ),
            state: state,
            code: .failedPrecondition,
            retry: .never
        )
    }

    func testCapacityTopologyAndHealthFailuresAreBounded() throws {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        let other = try StorageLocalTopology(nodeID: "other-mac")
        let state = try StorageSemanticState(
            topology: topology,
            totalCapacityBytes: 100,
            providerHealth: .unhealthy
        )

        XCTAssertStorageFailure(
            try request(.capacity, topology: other),
            state: state,
            code: .unsupportedTopology,
            retry: .never
        )
        XCTAssertStorageFailure(
            try request(
                .create,
                volumeID: volumeID,
                volumeName: "too-large",
                capacityBytes: 101,
                topology: topology,
                accessMode: .readWriteOnce
            ),
            state: try StorageSemanticState(
                topology: topology,
                totalCapacityBytes: 100
            ),
            code: .capacityExhausted,
            retry: .safeAfterObservation
        )
        let health = try engine.apply(
            request(.health),
            to: state
        )
        XCTAssertEqual(health.result.health, .unhealthy)
    }

    func testDecodedRequestCannotBypassContextValidation() throws {
        let topology = try StorageLocalTopology(nodeID: "dev-mbp")
        let state = try createdState(topology: topology)
        let valid = try request(.delete, volumeID: volumeID)
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        var contextObject = try XCTUnwrap(
            object["context"] as? [String: Any]
        )
        contextObject["generation"] = 0
        object["context"] = contextObject
        let decoded = try JSONDecoder().decode(
            StorageSemanticRequest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertStorageFailure(
            decoded,
            state: state,
            code: .invalidArgument,
            retry: .never
        )
    }

    private func createdState(
        topology: StorageLocalTopology
    ) throws -> StorageSemanticState {
        let empty = try StorageSemanticState(
            topology: topology,
            totalCapacityBytes: 1_000
        )
        return try engine.apply(
            request(
                .create,
                volumeID: volumeID,
                volumeName: "database",
                capacityBytes: 400,
                topology: topology,
                accessMode: .readWriteOnce
            ),
            to: empty
        ).state
    }

    private func context(
        generation: Int64 = 1,
        fencingToken: String? = nil,
        interruption: StorageSemanticInterruption = .none
    ) throws -> StorageSemanticContext {
        try StorageSemanticContext(
            operationID:
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            idempotencyKey: String(repeating: "b", count: 64),
            providerID: "local-apfs",
            generation: generation,
            fencingToken: fencingToken ?? fence,
            interruption: interruption
        )
    }

    private func request(
        _ operation: StorageSemanticOperation,
        volumeID: String? = nil,
        volumeName: String? = nil,
        snapshotID: String? = nil,
        snapshotName: String? = nil,
        capacityBytes: Int64? = nil,
        topology: StorageLocalTopology? = nil,
        stagingPath: String? = nil,
        targetPath: String? = nil,
        readOnly: Bool? = nil,
        accessMode: StorageSemanticAccessMode? = nil
    ) throws -> StorageSemanticRequest {
        try StorageSemanticRequest(
            operation: operation,
            context: context(),
            volumeID: volumeID,
            volumeName: volumeName,
            snapshotID: snapshotID,
            snapshotName: snapshotName,
            capacityBytes: capacityBytes,
            topology: topology,
            stagingPath: stagingPath,
            targetPath: targetPath,
            readOnly: readOnly,
            accessMode: accessMode
        )
    }

    private func XCTAssertStorageFailure(
        _ request: StorageSemanticRequest,
        state: StorageSemanticState,
        code: StorageSemanticErrorCode,
        retry: StorageSemanticRetryClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try engine.apply(request, to: state),
            file: file,
            line: line
        ) { error in
            guard let failure = error as? StorageSemanticError else {
                return XCTFail(
                    "Expected StorageSemanticError, got \(error).",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(failure.code, code, file: file, line: line)
            XCTAssertEqual(
                failure.retryClass,
                retry,
                file: file,
                line: line
            )
        }
    }
}
