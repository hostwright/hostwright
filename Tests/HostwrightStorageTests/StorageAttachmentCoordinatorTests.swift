import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageAttachmentCoordinatorTests: XCTestCase {
    private let now: Int64 = 1_000_000
    private let lease: Int64 = 60_000
    private let attachmentID =
        "11111111-1111-4111-8111-111111111111"
    private let secondAttachmentID =
        "22222222-2222-4222-8222-222222222222"
    private let volumeID =
        "33333333-3333-4333-8333-333333333333"
    private let nodeUUID =
        "44444444-4444-4444-8444-444444444444"
    private let secondNodeUUID =
        "55555555-5555-4555-8555-555555555555"
    private let workloadUUID =
        "66666666-6666-4666-8666-666666666666"
    private let secondWorkloadUUID =
        "77777777-7777-4777-8777-777777777777"
    private let operationID =
        "88888888-8888-4888-8888-888888888888"
    private let detachOperationID =
        "99999999-9999-4999-8999-999999999999"
    private let firstFence =
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let secondFence =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let observation = String(repeating: "c", count: 64)

    func testAttachPersistsEveryCheckpointInOrderAndReplaysExactly()
        throws
    {
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now
        )
        let empty = try StorageAttachmentLedger()
        let intent = try attachIntent()

        var transition = try coordinator.beginAttach(intent, in: empty)
        XCTAssertEqual(transition.disposition, .performed)
        XCTAssertEqual(
            transition.record.checkpoint,
            .attachIntentPersisted
        )
        XCTAssertEqual(transition.record.lifecycleState, .attaching)
        XCTAssertEqual(
            try coordinator.beginAttach(
                intent,
                in: transition.ledger
            ).disposition,
            .alreadySatisfied
        )
        XCTAssertAttachmentFailure(
            try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                to: .attachProviderEffectRequested,
                in: transition.ledger
            ),
            code: .invalidTransition,
            retry: .never
        )

        transition = try advance(
            transition,
            to: .attachFenceAcquired,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachProviderEffectRequested,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachProviderObserved,
            observation: observation,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachedCommitted,
            coordinator: coordinator
        )

        XCTAssertEqual(transition.record.lifecycleState, .attached)
        XCTAssertEqual(
            transition.record.providerObservationSHA256,
            observation
        )
        XCTAssertEqual(
            try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                to: .attachedCommitted,
                in: transition.ledger
            ).disposition,
            .alreadySatisfied
        )
    }

    func testSingleWriterHolderLeaseAndFenceConflictsFailClosed()
        throws
    {
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now
        )
        let first = try coordinator.beginAttach(
            attachIntent(),
            in: StorageAttachmentLedger()
        )

        XCTAssertAttachmentFailure(
            try coordinator.beginAttach(
                attachIntent(
                    attachmentID: secondAttachmentID,
                    nodeUUID: secondNodeUUID,
                    workloadUUID: secondWorkloadUUID
                ),
                in: first.ledger
            ),
            code: .singleWriterConflict,
            retry: .safeAfterObservation
        )
        XCTAssertAttachmentFailure(
            try coordinator.beginAttach(
                attachIntent(
                    attachmentID: secondAttachmentID,
                    nodeUUID: secondNodeUUID,
                    workloadUUID: secondWorkloadUUID,
                    readOnly: true
                ),
                in: first.ledger
            ),
            code: .singleWriterConflict,
            retry: .safeAfterObservation
        )

        let reader = try coordinator.beginAttach(
            attachIntent(readOnly: true),
            in: StorageAttachmentLedger()
        )
        XCTAssertAttachmentFailure(
            try coordinator.beginAttach(
                attachIntent(
                    attachmentID: secondAttachmentID,
                    readOnly: true
                ),
                in: reader.ledger
            ),
            code: .holderConflict,
            retry: .safeAfterObservation
        )

        XCTAssertAttachmentFailure(
            try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(generation: 2),
                to: .attachFenceAcquired,
                in: first.ledger
            ),
            code: .staleGeneration,
            retry: .safeAfterObservation
        )
        XCTAssertAttachmentFailure(
            try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(
                    fence: secondFence
                ),
                to: .attachFenceAcquired,
                in: first.ledger
            ),
            code: .fencingConflict,
            retry: .safeAfterObservation
        )

        let renewalCoordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now + 10_000
        )
        let renewed = try renewalCoordinator.renewLease(
            attachmentID: attachmentID,
            holderNodeUUID: nodeUUID,
            holderWorkloadUUID: workloadUUID,
            expectedAuthority: try authority(),
            durationMilliseconds: lease,
            in: first.ledger
        )
        XCTAssertEqual(
            renewed.record.leaseRenewedAtUnixMilliseconds,
            now + 10_000
        )
        XCTAssertEqual(
            renewed.record.leaseExpiresAtUnixMilliseconds,
            now + 70_000
        )

        let staleCoordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now + lease
        )
        XCTAssertAttachmentFailure(
            try staleCoordinator.renewLease(
                attachmentID: attachmentID,
                holderNodeUUID: nodeUUID,
                holderWorkloadUUID: workloadUUID,
                expectedAuthority: try authority(),
                durationMilliseconds: lease,
                in: first.ledger
            ),
            code: .leaseExpired,
            retry: .resumeFromCheckpoint
        )
    }

    func testAttachInterruptionIsResumableOrHeldAtExactEffect()
        throws
    {
        for interruption in [
            StorageAttachmentInterruption.cancelled,
            .timedOut,
            .crashed,
        ] {
            let coordinator = StorageAttachmentCoordinator(
                nowUnixMilliseconds: now
            )
            var transition = try coordinator.beginAttach(
                attachIntent(),
                in: StorageAttachmentLedger()
            )
            let beforeEffect = try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                to: .attachFenceAcquired,
                interruption: interruption,
                in: transition.ledger
            )
            XCTAssertEqual(beforeEffect.disposition, .interrupted)
            XCTAssertEqual(
                beforeEffect.record.checkpoint,
                .attachIntentPersisted
            )

            transition = try advance(
                transition,
                to: .attachFenceAcquired,
                coordinator: coordinator
            )
            transition = try advance(
                transition,
                to: .attachProviderEffectRequested,
                coordinator: coordinator
            )
            let held = try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                to: .attachProviderObserved,
                interruption: interruption,
                in: transition.ledger
            )
            XCTAssertEqual(held.disposition, .held)
            XCTAssertEqual(
                held.record.checkpoint,
                .attachProviderEffectRequested
            )
            XCTAssertEqual(
                held.record.lifecycleState,
                .ambiguousHold
            )
            XCTAssertAttachmentFailure(
                try coordinator.advance(
                    attachmentID: attachmentID,
                    expectedAuthority: try authority(),
                    to: .attachProviderObserved,
                    providerObservationSHA256: observation,
                    in: held.ledger
                ),
                code: .ambiguousHold,
                retry: .resumeFromCheckpoint
            )

            let resolved = try coordinator.resolveAmbiguous(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                providerObservedAttached: true,
                providerObservationSHA256: observation,
                in: held.ledger
            )
            XCTAssertEqual(
                resolved.record.checkpoint,
                .attachProviderObserved
            )
            XCTAssertNil(resolved.record.ambiguousHoldReason)
        }
    }

    func testCancellationAtEveryCheckpointPreservesAResumableRecord()
        throws
    {
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now
        )
        var attach = try coordinator.beginAttach(
            attachIntent(),
            in: StorageAttachmentLedger()
        )
        let attachTargets: [StorageAttachmentCheckpoint] = [
            .attachFenceAcquired,
            .attachProviderEffectRequested,
            .attachProviderObserved,
            .attachedCommitted,
        ]
        for target in attachTargets {
            let interrupted = try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: try authority(),
                to: target,
                providerObservationSHA256:
                    target == .attachProviderObserved
                        ? observation
                        : nil,
                interruption: .cancelled,
                in: attach.ledger
            )
            if attach.record.checkpoint
                .providerEffectMayBeAmbiguous {
                XCTAssertEqual(interrupted.disposition, .held)
                XCTAssertEqual(
                    interrupted.record.checkpoint,
                    attach.record.checkpoint
                )
            } else {
                XCTAssertEqual(
                    interrupted.disposition,
                    .interrupted
                )
                XCTAssertEqual(interrupted.record, attach.record)
            }
            attach = try advance(
                attach,
                to: target,
                observation:
                    target == .attachProviderObserved
                        ? observation
                        : nil,
                coordinator: coordinator
            )
        }

        let replacement = try authority(
            generation: 2,
            fence: secondFence
        )
        let detachCoordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now + 1
        )
        var detach = try detachCoordinator.beginDetach(
            try detachIntent(replacement: replacement),
            in: attach.ledger
        )
        let detachTargets: [StorageAttachmentCheckpoint] = [
            .detachFenceAcquired,
            .detachProviderEffectRequested,
            .detachProviderAbsentObserved,
            .detachedCommitted,
        ]
        for target in detachTargets {
            let interrupted = try detachCoordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: replacement,
                to: target,
                providerObservationSHA256:
                    target == .detachProviderAbsentObserved
                        ? observation
                        : nil,
                interruption: .cancelled,
                in: detach.ledger
            )
            if detach.record.checkpoint
                .providerEffectMayBeAmbiguous {
                XCTAssertEqual(interrupted.disposition, .held)
                XCTAssertEqual(
                    interrupted.record.checkpoint,
                    detach.record.checkpoint
                )
            } else {
                XCTAssertEqual(
                    interrupted.disposition,
                    .interrupted
                )
                XCTAssertEqual(interrupted.record, detach.record)
            }
            detach = try advance(
                detach,
                to: target,
                authority: replacement,
                observation:
                    target == .detachProviderAbsentObserved
                        ? observation
                        : nil,
                coordinator: detachCoordinator
            )
        }
        XCTAssertEqual(detach.record.lifecycleState, .detached)
    }

    func testStaleHolderRequiresExactBoundedForceDetachAuthorization()
        throws
    {
        let attached = try attachedLedger()
        let staleNow = now + lease
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: staleNow
        )
        let replacement = try authority(
            generation: 2,
            fence: secondFence
        )
        let normal = try detachIntent(replacement: replacement)
        XCTAssertAttachmentFailure(
            try coordinator.beginDetach(normal, in: attached),
            code: .authorizationRequired,
            retry: .resumeFromCheckpoint
        )

        let record = try XCTUnwrap(attached.record(id: attachmentID))
        let expiry = staleNow + 30_000
        let token = coordinator.forceDetachAuthorization(
            for: record,
            validUntilUnixMilliseconds: expiry
        )
        XCTAssertAttachmentFailure(
            try coordinator.beginDetach(
                try detachIntent(
                    replacement: replacement,
                    holderNodeUUID: secondNodeUUID,
                    forceAuthorization: token,
                    forceAuthorizationExpiresAt: expiry
                ),
                in: attached
            ),
            code: .holderConflict,
            retry: .never
        )
        XCTAssertAttachmentFailure(
            try coordinator.beginDetach(
                try detachIntent(
                    replacement: replacement,
                    forceAuthorization:
                        "\(StorageAttachmentCoordinator.forceDetachAuthorizationPrefix)wrong",
                    forceAuthorizationExpiresAt: expiry
                ),
                in: attached
            ),
            code: .authorizationMismatch,
            retry: .never
        )
        let overlyLongExpiry = staleNow + 15 * 60 * 1_000 + 1
        XCTAssertAttachmentFailure(
            try coordinator.beginDetach(
                try detachIntent(
                    replacement: replacement,
                    forceAuthorization:
                        coordinator.forceDetachAuthorization(
                            for: record,
                            validUntilUnixMilliseconds:
                                overlyLongExpiry
                        ),
                    forceAuthorizationExpiresAt:
                        overlyLongExpiry
                ),
                in: attached
            ),
            code: .authorizationExpired,
            retry: .never
        )

        let forced = try coordinator.beginDetach(
            try detachIntent(
                replacement: replacement,
                forceAuthorization: token,
                forceAuthorizationExpiresAt: expiry
            ),
            in: attached
        )
        XCTAssertEqual(
            forced.record.checkpoint,
            .detachIntentPersisted
        )
        XCTAssertEqual(forced.record.authority, replacement)
        XCTAssertNotNil(
            forced.record.forceDetachAuthorizationSHA256
        )
        XCTAssertFalse(
            String(
                data: try JSONEncoder().encode(forced.record),
                encoding: .utf8
            )!.contains(token)
        )
    }

    func testDetachInterruptionObservationAndExactCleanupAreOrdered()
        throws
    {
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now + 1
        )
        let firstAuthority = try authority()
        let replacement = try authority(
            generation: 2,
            fence: secondFence
        )
        var transition = try coordinator.beginDetach(
            try detachIntent(replacement: replacement),
            in: try attachedLedger()
        )
        XCTAssertEqual(
            try coordinator.beginDetach(
                try detachIntent(replacement: replacement),
                in: transition.ledger
            ).disposition,
            .alreadySatisfied
        )
        XCTAssertAttachmentFailure(
            try coordinator.advance(
                attachmentID: attachmentID,
                expectedAuthority: firstAuthority,
                to: .detachFenceAcquired,
                in: transition.ledger
            ),
            code: .staleGeneration,
            retry: .safeAfterObservation
        )

        transition = try advance(
            transition,
            to: .detachFenceAcquired,
            authority: replacement,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .detachProviderEffectRequested,
            authority: replacement,
            coordinator: coordinator
        )
        let held = try coordinator.advance(
            attachmentID: attachmentID,
            expectedAuthority: replacement,
            to: .detachProviderAbsentObserved,
            interruption: .timedOut,
            in: transition.ledger
        )
        XCTAssertEqual(held.disposition, .held)

        transition = try coordinator.resolveAmbiguous(
            attachmentID: attachmentID,
            expectedAuthority: replacement,
            providerObservedAttached: false,
            providerObservationSHA256: observation,
            in: held.ledger
        )
        XCTAssertEqual(
            transition.record.checkpoint,
            .detachProviderAbsentObserved
        )
        transition = try advance(
            transition,
            to: .detachedCommitted,
            authority: replacement,
            coordinator: coordinator
        )
        XCTAssertEqual(transition.record.lifecycleState, .detached)

        let cleaned = try coordinator.removeDetached(
            attachmentID: attachmentID,
            expectedAuthority: replacement,
            from: transition.ledger
        )
        XCTAssertTrue(cleaned.records.isEmpty)
        XCTAssertEqual(
            try coordinator.removeDetached(
                attachmentID: attachmentID,
                expectedAuthority: replacement,
                from: cleaned
            ),
            cleaned
        )
    }

    private func attachedLedger() throws -> StorageAttachmentLedger {
        let coordinator = StorageAttachmentCoordinator(
            nowUnixMilliseconds: now
        )
        var transition = try coordinator.beginAttach(
            attachIntent(),
            in: StorageAttachmentLedger()
        )
        transition = try advance(
            transition,
            to: .attachFenceAcquired,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachProviderEffectRequested,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachProviderObserved,
            observation: observation,
            coordinator: coordinator
        )
        transition = try advance(
            transition,
            to: .attachedCommitted,
            coordinator: coordinator
        )
        return transition.ledger
    }

    private func attachIntent(
        attachmentID: String? = nil,
        nodeUUID: String? = nil,
        workloadUUID: String? = nil,
        readOnly: Bool = false
    ) throws -> StorageAttachmentIntent {
        StorageAttachmentIntent(
            attachmentID: attachmentID ?? self.attachmentID,
            volumeID: volumeID,
            nodeUUID: nodeUUID ?? self.nodeUUID,
            workloadUUID: workloadUUID ?? self.workloadUUID,
            accessMode: .readWriteOnce,
            readOnly: readOnly,
            authority: try authority(),
            operationID: operationID,
            idempotencyKey: String(repeating: "d", count: 64),
            leaseDurationMilliseconds: lease
        )
    }

    private func detachIntent(
        replacement: StorageAttachmentAuthority,
        holderNodeUUID: String? = nil,
        holderWorkloadUUID: String? = nil,
        forceAuthorization: String? = nil,
        forceAuthorizationExpiresAt: Int64? = nil
    ) throws -> StorageDetachIntent {
        StorageDetachIntent(
            attachmentID: attachmentID,
            holderNodeUUID: holderNodeUUID ?? nodeUUID,
            holderWorkloadUUID:
                holderWorkloadUUID ?? workloadUUID,
            expectedAuthority: try authority(),
            replacementAuthority: replacement,
            operationID: detachOperationID,
            idempotencyKey: String(repeating: "e", count: 64),
            leaseDurationMilliseconds: lease,
            forceAuthorization: forceAuthorization,
            forceAuthorizationExpiresAtUnixMilliseconds:
                forceAuthorizationExpiresAt
        )
    }

    private func authority(
        generation: Int64 = 1,
        fence: String? = nil
    ) throws -> StorageAttachmentAuthority {
        try StorageAttachmentAuthority(
            generation: generation,
            fencingToken: fence ?? firstFence
        )
    }

    private func advance(
        _ transition: StorageAttachmentTransition,
        to checkpoint: StorageAttachmentCheckpoint,
        authority: StorageAttachmentAuthority? = nil,
        observation: String? = nil,
        coordinator: StorageAttachmentCoordinator
    ) throws -> StorageAttachmentTransition {
        try coordinator.advance(
            attachmentID: attachmentID,
            expectedAuthority: authority ?? self.authority(),
            to: checkpoint,
            providerObservationSHA256: observation,
            in: transition.ledger
        )
    }

    private func XCTAssertAttachmentFailure<T>(
        _ expression: @autoclosure () throws -> T,
        code: StorageAttachmentFailureCode,
        retry: StorageSemanticRetryClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try expression(),
            file: file,
            line: line
        ) { error in
            guard let failure = error as? StorageAttachmentFailure else {
                return XCTFail(
                    "Expected StorageAttachmentFailure, got \(error).",
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
