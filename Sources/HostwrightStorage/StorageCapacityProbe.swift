import Darwin
import Foundation

public struct StorageCapacityFilesystemCounters:
    Equatable,
    Sendable
{
    public let blockSize: Int64
    public let totalBlocks: Int64
    public let freeBlocks: Int64
    public let availableBlocks: Int64
    public let totalInodes: Int64
    public let freeInodes: Int64

    public init(
        blockSize: Int64,
        totalBlocks: Int64,
        freeBlocks: Int64,
        availableBlocks: Int64,
        totalInodes: Int64,
        freeInodes: Int64
    ) throws {
        guard blockSize > 0,
              blockSize <= 1_073_741_824,
              totalBlocks > 0,
              freeBlocks >= 0,
              availableBlocks >= 0,
              freeBlocks <= totalBlocks,
              availableBlocks <= freeBlocks,
              totalInodes > 0,
              freeInodes >= 0,
              freeInodes <= totalInodes else {
            throw StorageCapacityError(
                code: .invalidSample,
                retryDisposition: .afterFreshSample,
                message:
                    "Filesystem counters violate bounded block or inode accounting."
            )
        }
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
        self.availableBlocks = availableBlocks
        self.totalInodes = totalInodes
        self.freeInodes = freeInodes
    }
}

public struct StorageCapacityProbe: Sendable {
    public init() {}

    public func sample(
        path: String,
        id: String,
        providerID: String,
        topologyNodeID: String,
        requestedBytes: Int64,
        reservedBytes: Int64,
        reclaimableBytes: Int64,
        requestedInodes: Int64,
        reservedInodes: Int64,
        reclaimableInodes: Int64,
        quotaCapability: StorageQuotaCapability,
        capturedAtUnixMilliseconds: Int64,
        lifetimeMilliseconds: Int64
    ) throws -> StorageCapacitySample {
        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL.path
        guard path.hasPrefix("/"),
              normalized == path,
              FileManager.default.fileExists(atPath: path),
              quotaCapability.mode != .hard else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "statfs sampling requires an existing normalized path and cannot claim hard quota enforcement."
            )
        }

        let descriptor = open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw StorageCapacityError(
                code: .probeFailed,
                retryDisposition: .afterFreshSample,
                message:
                    "Capacity probe could not open the exact filesystem root."
            )
        }
        defer { close(descriptor) }

        var information = statfs()
        guard fstatfs(descriptor, &information) == 0,
              let blockSize = Int64(exactly: information.f_bsize),
              let totalBlocks = Int64(
                  exactly: information.f_blocks
              ),
              let freeBlocks = Int64(
                  exactly: information.f_bfree
              ),
              let availableBlocks = Int64(
                  exactly: information.f_bavail
              ),
              let totalInodes = Int64(
                  exactly: information.f_files
              ),
              let freeInodes = Int64(
                  exactly: information.f_ffree
              ) else {
            throw StorageCapacityError(
                code: .probeFailed,
                retryDisposition: .afterFreshSample,
                message:
                    "statfs could not produce bounded filesystem counters."
            )
        }
        let counters = try StorageCapacityFilesystemCounters(
            blockSize: blockSize,
            totalBlocks: totalBlocks,
            freeBlocks: freeBlocks,
            availableBlocks: availableBlocks,
            totalInodes: totalInodes,
            freeInodes: freeInodes
        )
        return try sample(
            counters: counters,
            id: id,
            providerID: providerID,
            topologyNodeID: topologyNodeID,
            requestedBytes: requestedBytes,
            reservedBytes: reservedBytes,
            reclaimableBytes: reclaimableBytes,
            requestedInodes: requestedInodes,
            reservedInodes: reservedInodes,
            reclaimableInodes: reclaimableInodes,
            quotaCapability: quotaCapability,
            capturedAtUnixMilliseconds:
                capturedAtUnixMilliseconds,
            lifetimeMilliseconds: lifetimeMilliseconds
        )
    }

    public func sample(
        counters: StorageCapacityFilesystemCounters,
        id: String,
        providerID: String,
        topologyNodeID: String,
        requestedBytes: Int64,
        reservedBytes: Int64,
        reclaimableBytes: Int64,
        requestedInodes: Int64,
        reservedInodes: Int64,
        reclaimableInodes: Int64,
        quotaCapability: StorageQuotaCapability,
        capturedAtUnixMilliseconds: Int64,
        lifetimeMilliseconds: Int64
    ) throws -> StorageCapacitySample {
        guard quotaCapability.mode != .hard else {
            throw StorageCapacityError(
                code: .invalidArgument,
                retryDisposition: .never,
                message:
                    "Filesystem counters cannot prove hard quota enforcement."
            )
        }
        let totalBytes = try multiply(
            counters.totalBlocks,
            counters.blockSize
        )
        let freeBytes = try multiply(
            counters.freeBlocks,
            counters.blockSize
        )
        let availableBytes = try multiply(
            counters.availableBlocks,
            counters.blockSize
        )
        let usedBytes = totalBytes - freeBytes
        let usedInodes =
            counters.totalInodes - counters.freeInodes
        let expiry = capturedAtUnixMilliseconds
            .addingReportingOverflow(lifetimeMilliseconds)
        guard !expiry.overflow else {
            throw StorageCapacityError(
                code: .arithmeticOverflow,
                retryDisposition: .never,
                message: "Capacity sample expiry overflowed."
            )
        }
        return try StorageCapacitySample(
            id: id,
            providerID: providerID,
            topologyNodeID: topologyNodeID,
            source: .statfs,
            requestedBytes: requestedBytes,
            reservedBytes: reservedBytes,
            usedBytes: usedBytes,
            reclaimableBytes: reclaimableBytes,
            availableBytes: availableBytes,
            totalBytes: totalBytes,
            requestedInodes: requestedInodes,
            reservedInodes: reservedInodes,
            usedInodes: usedInodes,
            reclaimableInodes: reclaimableInodes,
            availableInodes: counters.freeInodes,
            totalInodes: counters.totalInodes,
            quotaCapability: quotaCapability,
            capturedAtUnixMilliseconds:
                capturedAtUnixMilliseconds,
            validUntilUnixMilliseconds: expiry.partialValue
        )
    }

    private func multiply(
        _ count: Int64,
        _ size: Int64
    ) throws -> Int64 {
        let result = count.multipliedReportingOverflow(by: size)
        guard !result.overflow,
              result.partialValue <=
                StorageCapacityLimits.maximumBytes else {
            throw StorageCapacityError(
                code: .arithmeticOverflow,
                retryDisposition: .never,
                message:
                    "Filesystem byte accounting exceeded supported bounds."
            )
        }
        return result.partialValue
    }
}
