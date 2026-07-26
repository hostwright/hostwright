import Darwin
import Foundation
import XCTest
@testable import HostwrightStorage

final class StorageCapacityProbeTests: XCTestCase {
    private let probe = StorageCapacityProbe()
    private let sampleID =
        "50000000-0000-4000-8000-000000000001"

    func testInjectedFilesystemCountersProduceExactAccounting()
        throws
    {
        let counters = try StorageCapacityFilesystemCounters(
            blockSize: 4_096,
            totalBlocks: 1_000,
            freeBlocks: 400,
            availableBlocks: 300,
            totalInodes: 500,
            freeInodes: 200
        )
        let sample = try probe.sample(
            counters: counters,
            id: sampleID,
            providerID: "local-apfs",
            topologyNodeID: "dev-mbp",
            requestedBytes: 2_000_000,
            reservedBytes: 100_000,
            reclaimableBytes: 200_000,
            requestedInodes: 350,
            reservedInodes: 10,
            reclaimableInodes: 20,
            quotaCapability: try StorageQuotaCapability(
                mode: .logical
            ),
            capturedAtUnixMilliseconds: 1_000,
            lifetimeMilliseconds: 60_000
        )
        XCTAssertEqual(sample.totalBytes, 4_096_000)
        XCTAssertEqual(sample.usedBytes, 2_457_600)
        XCTAssertEqual(sample.availableBytes, 1_228_800)
        XCTAssertEqual(
            sample.effectiveAvailableBytes,
            1_128_800
        )
        XCTAssertEqual(sample.usedInodes, 300)
        XCTAssertEqual(sample.effectiveAvailableInodes, 190)
        XCTAssertEqual(sample.digestSHA256.utf8.count, 64)
    }

    func testUnknownInodesOverflowAndHardQuotaClaimsFailClosed()
        throws
    {
        XCTAssertThrowsError(
            try StorageCapacityFilesystemCounters(
                blockSize: 4_096,
                totalBlocks: 1_000,
                freeBlocks: 500,
                availableBlocks: 500,
                totalInodes: 0,
                freeInodes: 0
            )
        )

        let overflow = try StorageCapacityFilesystemCounters(
            blockSize: 1_073_741_824,
            totalBlocks: Int64.max,
            freeBlocks: 0,
            availableBlocks: 0,
            totalInodes: 1,
            freeInodes: 1
        )
        XCTAssertThrowsError(
            try injected(
                counters: overflow,
                quota: StorageQuotaCapability(mode: .unavailable)
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageCapacityError)?.code,
                .arithmeticOverflow
            )
        }

        let counters = try StorageCapacityFilesystemCounters(
            blockSize: 4_096,
            totalBlocks: 1_000,
            freeBlocks: 500,
            availableBlocks: 500,
            totalInodes: 1_000,
            freeInodes: 500
        )
        XCTAssertThrowsError(
            try injected(
                counters: counters,
                quota: StorageQuotaCapability(
                    mode: .hard,
                    evidenceSHA256:
                        String(repeating: "a", count: 64)
                )
            )
        )
    }

    func testRealStatFSSampleIsBoundedWithoutFabricatingQuota()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-capacity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("payload")
        try Data(repeating: 0x5a, count: 16_384).write(
            to: payload,
            options: .withoutOverwriting
        )
        let descriptor = open(payload.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 {
            XCTAssertEqual(fsync(descriptor), 0)
            close(descriptor)
        }

        let sample = try probe.sample(
            path: directory.path,
            id: sampleID,
            providerID: "local-apfs",
            topologyNodeID: "dev-mbp",
            requestedBytes: 16_384,
            reservedBytes: 0,
            reclaimableBytes: 0,
            requestedInodes: 1,
            reservedInodes: 0,
            reclaimableInodes: 0,
            quotaCapability: try StorageQuotaCapability(
                mode: .unavailable
            ),
            capturedAtUnixMilliseconds: 1_000,
            lifetimeMilliseconds: 60_000
        )
        XCTAssertEqual(sample.source, .statfs)
        XCTAssertEqual(
            sample.quotaCapability.mode,
            .unavailable
        )
        XCTAssertGreaterThan(sample.totalBytes, 0)
        XCTAssertGreaterThan(sample.totalInodes, 0)
        XCTAssertLessThanOrEqual(
            sample.usedBytes + sample.availableBytes,
            sample.totalBytes
        )
        XCTAssertLessThanOrEqual(
            sample.usedInodes + sample.availableInodes,
            sample.totalInodes
        )
    }

    private func injected(
        counters: StorageCapacityFilesystemCounters,
        quota: StorageQuotaCapability
    ) throws -> StorageCapacitySample {
        try probe.sample(
            counters: counters,
            id: sampleID,
            providerID: "local-apfs",
            topologyNodeID: "dev-mbp",
            requestedBytes: 0,
            reservedBytes: 0,
            reclaimableBytes: 0,
            requestedInodes: 0,
            reservedInodes: 0,
            reclaimableInodes: 0,
            quotaCapability: quota,
            capturedAtUnixMilliseconds: 1_000,
            lifetimeMilliseconds: 60_000
        )
    }
}
