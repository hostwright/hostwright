import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageCapacityPolicyTests: XCTestCase {
    private let now: Int64 = 1_000_000
    private let operationID =
        "11111111-1111-4111-8111-111111111111"

    func testPressureBoundariesAndHysteresisAreDeterministic()
        throws
    {
        let policy = StorageCapacityPolicy()
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 2_001),
                previous: .normal
            ),
            .normal
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 2_000),
                previous: .normal
            ),
            .warning
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 1_000),
                previous: .normal
            ),
            .critical
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 500),
                previous: .normal
            ),
            .emergency
        )

        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 2_100),
                previous: .warning
            ),
            .warning
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 2_251),
                previous: .warning
            ),
            .normal
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 1_100),
                previous: .critical
            ),
            .critical
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 1_251),
                previous: .critical
            ),
            .warning
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 600),
                previous: .emergency
            ),
            .emergency
        )
        XCTAssertEqual(
            policy.pressure(
                for: try sample(available: 751),
                previous: .emergency
            ),
            .critical
        )
    }

    func testBytesInodesAndPressureRejectBeforeUnsafeGrowth()
        throws
    {
        let policy = StorageCapacityPolicy()
        let normal = try sample(available: 5_000)
        XCTAssertEqual(
            policy.evaluate(
                try request(bytes: 1_000, inodes: 100),
                sample: normal,
                previousPressure: .normal,
                atUnixMilliseconds: now
            ).disposition,
            .admit
        )

        let bytes = policy.evaluate(
            try request(bytes: 5_001, inodes: 1),
            sample: normal,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(bytes.disposition, .reject)
        XCTAssertEqual(bytes.reason, .bytesExhausted)
        XCTAssertEqual(bytes.retryDisposition, .afterFreshSample)

        let diskFull = policy.evaluate(
            try request(bytes: 1, inodes: 0),
            sample: try sample(available: 0),
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(diskFull.reason, .bytesExhausted)

        let inodeLimited = try sample(
            available: 5_000,
            availableInodes: 0
        )
        let inodes = policy.evaluate(
            try request(bytes: 1, inodes: 1),
            sample: inodeLimited,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(inodes.disposition, .reject)
        XCTAssertEqual(inodes.reason, .inodesExhausted)

        let critical = policy.evaluate(
            try request(bytes: 1, inodes: 1),
            sample: try sample(available: 1_000),
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(critical.disposition, .throttle)
        XCTAssertEqual(critical.reason, .criticalPressure)

        let emergency = try sample(available: 500)
        let writableAttach = policy.evaluate(
            try request(
                action: .attach,
                bytes: 0,
                inodes: 0,
                writable: true
            ),
            sample: emergency,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(writableAttach.disposition, .reject)
        XCTAssertEqual(
            writableAttach.reason,
            .emergencyPressure
        )
        XCTAssertEqual(
            policy.evaluate(
                try request(
                    action: .attach,
                    bytes: 0,
                    inodes: 0,
                    writable: false
                ),
                sample: emergency,
                previousPressure: .normal,
                atUnixMilliseconds: now
            ).disposition,
            .admit
        )
    }

    func testStaleSamplesAndRetriesAreBounded() throws {
        let policy = StorageCapacityPolicy()
        let stale = try sample(
            available: 5_000,
            capturedAt: now - 120_000,
            validUntil: now - 60_000
        )
        let first = policy.evaluate(
            try request(bytes: 1, inodes: 1),
            sample: stale,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(first.reason, .staleSample)
        XCTAssertEqual(
            first.retryDisposition,
            .afterFreshSample
        )

        let exhausted = policy.evaluate(
            try request(
                bytes: 1,
                inodes: 1,
                attempt: 3
            ),
            sample: stale,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(exhausted.reason, .retryExhausted)
        XCTAssertEqual(exhausted.retryDisposition, .never)
        XCTAssertEqual(exhausted.disposition, .reject)
    }

    func testQuotaClaimsAndLimitsFailClosed() throws {
        let policy = StorageCapacityPolicy()
        let logical = try sample(
            available: 5_000,
            quota: try StorageQuotaCapability(mode: .logical)
        )
        let unavailable = policy.evaluate(
            try request(
                bytes: 1,
                inodes: 1,
                requiresHardQuota: true
            ),
            sample: logical,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(
            unavailable.reason,
            .hardQuotaUnavailable
        )
        XCTAssertEqual(unavailable.retryDisposition, .never)

        let hard = try sample(
            available: 5_000,
            quota: try StorageQuotaCapability(
                mode: .hard,
                evidenceSHA256:
                    String(repeating: "a", count: 64)
            )
        )
        let exceeded = policy.evaluate(
            try request(
                bytes: 101,
                inodes: 1,
                requiresHardQuota: true,
                quotaUsedBytes: 900,
                quotaLimitBytes: 1_000
            ),
            sample: hard,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(exceeded.reason, .quotaExceeded)
        XCTAssertEqual(exceeded.disposition, .reject)

        XCTAssertEqual(
            policy.evaluate(
                try request(
                    bytes: 100,
                    inodes: 1,
                    requiresHardQuota: true,
                    quotaUsedBytes: 900,
                    quotaLimitBytes: 1_000
                ),
                sample: hard,
                previousPressure: .normal,
                atUnixMilliseconds: now
            ).disposition,
            .admit
        )
    }

    func testCancellationTimeoutAndAmbiguityHaveStableRecovery()
        throws
    {
        let policy = StorageCapacityPolicy()
        let current = try sample(available: 5_000)
        let cancelled = policy.evaluate(
            try request(
                bytes: 1,
                inodes: 1,
                interruption: .cancelled
            ),
            sample: current,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(cancelled.disposition, .cancelled)
        XCTAssertEqual(cancelled.checkpoint, .cancelled)

        let timedOut = policy.evaluate(
            try request(
                bytes: 1,
                inodes: 1,
                interruption: .timedOut
            ),
            sample: current,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(timedOut.reason, .timedOut)
        XCTAssertEqual(
            timedOut.retryDisposition,
            .afterFreshSample
        )

        let ambiguous = policy.evaluate(
            try request(
                bytes: 1,
                inodes: 1,
                interruption: .ambiguousEffect
            ),
            sample: current,
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(
            ambiguous.disposition,
            .recoveryRequired
        )
        XCTAssertEqual(
            ambiguous.checkpoint,
            .observationRequired
        )
        XCTAssertEqual(
            ambiguous.retryDisposition,
            .resumeFromCheckpoint
        )
    }

    func testGCPlanIsDeterministicAndNeverSelectsUnsafeResources()
        throws
    {
        let policy = StorageCapacityPolicy()
        let eligibleOld = try candidate(
            id: "20000000-0000-4000-8000-000000000001",
            kind: .snapshot,
            bytes: 60,
            lastUsed: 10
        )
        let eligibleOrphan = try candidate(
            id: "20000000-0000-4000-8000-000000000002",
            kind: .orphan,
            bytes: 50,
            lastUsed: 20
        )
        let held = try candidate(
            id: "20000000-0000-4000-8000-000000000003",
            kind: .orphan,
            bytes: 1_000,
            hold: true,
            lastUsed: 1
        )
        let attached = try candidate(
            id: "20000000-0000-4000-8000-000000000004",
            kind: .volume,
            bytes: 1_000,
            attachment: true,
            lastUsed: 1
        )
        let retained = try candidate(
            id: "20000000-0000-4000-8000-000000000005",
            kind: .backup,
            bytes: 1_000,
            reclaimPolicy: .retain,
            lastUsed: 1
        )
        let disrupted = try candidate(
            id: "20000000-0000-4000-8000-000000000006",
            kind: .backup,
            bytes: 1_000,
            disruptionAllows: false,
            lastUsed: 1
        )
        let unowned = try candidate(
            id: "20000000-0000-4000-8000-000000000007",
            kind: .backup,
            bytes: 1_000,
            owned: false,
            lastUsed: 1
        )
        let input = [
            eligibleOld,
            held,
            attached,
            retained,
            disrupted,
            unowned,
            eligibleOrphan,
        ]
        let digest = String(repeating: "b", count: 64)
        let first = try policy.planGarbageCollection(
            candidates: input,
            targetBytes: 100,
            targetInodes: 2,
            maximumItems: 10,
            sampleDigestSHA256: digest
        )
        let second = try policy.planGarbageCollection(
            candidates: Array(input.reversed()),
            targetBytes: 100,
            targetInodes: 2,
            maximumItems: 10,
            sampleDigestSHA256: digest
        )
        XCTAssertEqual(
            first.selected.map(\.resourceID),
            [
                eligibleOrphan.resourceID,
                eligibleOld.resourceID,
            ]
        )
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.targetSatisfied)
        XCTAssertEqual(
            first.confirmationSHA256.utf8.count,
            64
        )
        XCTAssertTrue(
            Set(first.selected.map(\.resourceID))
                .isDisjoint(with: [
                    held.resourceID,
                    attached.resourceID,
                    retained.resourceID,
                    disrupted.resourceID,
                    unowned.resourceID,
                ])
        )

        let cancelled = try policy.planGarbageCollection(
            candidates: input,
            targetBytes: 100,
            targetInodes: 1,
            maximumItems: 10,
            sampleDigestSHA256: digest,
            cancelled: true
        )
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.selected.isEmpty)
    }

    func testAccountingAndThresholdBoundariesRejectOverflow()
        throws
    {
        XCTAssertThrowsError(
            try StoragePressureThresholds(
                warningAvailableBasisPoints: 1_000,
                criticalAvailableBasisPoints: 2_000,
                emergencyAvailableBasisPoints: 500,
                hysteresisBasisPoints: 250
            )
        )
        let result = StorageCapacityPolicy().evaluate(
            try request(
                bytes: StorageCapacityLimits.maximumBytes,
                inodes: 1,
                quotaUsedBytes:
                    StorageCapacityLimits.maximumBytes,
                quotaLimitBytes:
                    StorageCapacityLimits.maximumBytes
            ),
            sample: try sample(available: 5_000),
            previousPressure: .normal,
            atUnixMilliseconds: now
        )
        XCTAssertEqual(result.reason, .quotaExceeded)
    }

    private func sample(
        available: Int64,
        availableInodes: Int64? = nil,
        capturedAt: Int64? = nil,
        validUntil: Int64? = nil,
        quota: StorageQuotaCapability? = nil
    ) throws -> StorageCapacitySample {
        let inodeAvailability = availableInodes ?? available
        return try StorageCapacitySample(
            id: "30000000-0000-4000-8000-000000000001",
            providerID: "local-apfs",
            topologyNodeID: "dev-mbp",
            source: .provider,
            requestedBytes: 0,
            reservedBytes: 0,
            usedBytes: 10_000 - available,
            reclaimableBytes: 0,
            availableBytes: available,
            totalBytes: 10_000,
            requestedInodes: 0,
            reservedInodes: 0,
            usedInodes: 10_000 - inodeAvailability,
            reclaimableInodes: 0,
            availableInodes: inodeAvailability,
            totalInodes: 10_000,
            quotaCapability: quota ??
                (try StorageQuotaCapability(mode: .logical)),
            capturedAtUnixMilliseconds: capturedAt ?? now - 1,
            validUntilUnixMilliseconds:
                validUntil ?? now + 60_000
        )
    }

    private func request(
        action: StorageCapacityAction = .create,
        bytes: Int64,
        inodes: Int64,
        writable: Bool = true,
        requiresHardQuota: Bool = false,
        quotaUsedBytes: Int64 = 0,
        quotaLimitBytes: Int64? = nil,
        attempt: Int = 1,
        interruption: StorageCapacityInterruption = .none
    ) throws -> StorageCapacityAdmissionRequest {
        try StorageCapacityAdmissionRequest(
            operationID: operationID,
            idempotencyKey: String(repeating: "c", count: 64),
            action: action,
            additionalBytes: bytes,
            additionalInodes: inodes,
            writable: writable,
            requiresHardQuota: requiresHardQuota,
            quotaUsedBytes: quotaUsedBytes,
            quotaLimitBytes: quotaLimitBytes,
            attempt: attempt,
            interruption: interruption
        )
    }

    private func candidate(
        id: String,
        kind: StorageGCCandidateKind,
        bytes: Int64,
        hold: Bool = false,
        attachment: Bool = false,
        reclaimPolicy: StorageCapacityReclaimPolicy = .delete,
        disruptionAllows: Bool = true,
        owned: Bool = true,
        lastUsed: Int64
    ) throws -> StorageGCCandidate {
        try StorageGCCandidate(
            resourceID: id,
            kind: kind,
            reclaimPolicy: reclaimPolicy,
            reclaimableBytes: bytes,
            reclaimableInodes: 1,
            hasActiveHold: hold,
            hasActiveAttachment: attachment,
            disruptionBudgetAllows: disruptionAllows,
            ownershipProofSHA256: owned
                ? String(repeating: "d", count: 64)
                : nil,
            disruptionPolicySHA256:
                String(repeating: "e", count: 64),
            generation: 1,
            fencingToken:
                "40000000-0000-4000-8000-000000000001",
            lastUsedAtUnixMilliseconds: lastUsed
        )
    }
}
