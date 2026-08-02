import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightObservability
import HostwrightState

struct MetricsCommandRunner {
    let options: MetricsCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        let snapshot = try StateMetricsService(
            store: SQLiteStateStore(configuration: stateStoreConfiguration),
            date: environment.metricsDate
        ).snapshot()
        switch options.action {
        case .snapshot:
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? CLIJSON.codable(snapshot)
                    : render(snapshot)
            )
        case .export(let outputPath, let confirmationSHA256):
            guard confirmationSHA256 == snapshot.snapshotSHA256 else {
                throw HostwrightMetricsError.snapshotChanged
            }
            guard !environment.metricsCancelled() else {
                throw StateStoreError.operationCancelled(path: stateStoreConfiguration.databasePath)
            }
            let data = try canonicalData(snapshot)
            let written = try SecureLocalExportWriter.write(
                data,
                to: outputPath,
                maximumBytes: HostwrightTraceContract.maximumExportBytes,
                isCancelled: environment.metricsCancelled,
                unsafeError: HostwrightMetricsError.unsafeExportPath
            )
            let receipt = HostwrightMetricsExportReceipt(
                snapshotSHA256: snapshot.snapshotSHA256,
                outputPath: outputPath,
                outputSHA256: written.outputSHA256,
                outputBytes: written.outputBytes
            )
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? CLIJSON.codable(receipt)
                    : """
                    Hostwright metrics export
                    Schema: v\(receipt.schemaVersion)
                    Snapshot SHA-256: \(receipt.snapshotSHA256)
                    Output: \(receipt.outputPath)
                    Output SHA-256: \(receipt.outputSHA256)
                    Output bytes: \(receipt.outputBytes)
                    Automatic upload: false
                    Ownership: operator-owned

                    """
            )
        }
    }

    private func canonicalData(_ snapshot: HostwrightMetricsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= 1_048_576 else {
            throw HostwrightMetricsError.seriesBudgetExceeded
        }
        return data
    }

    private func render(_ snapshot: HostwrightMetricsSnapshot) -> String {
        let metricLines = snapshot.series.map { item in
            let labels = item.labels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            let identity = labels.isEmpty ? item.name : "\(item.name){\(labels)}"
            if let value = item.value {
                return "  \(identity) [\(item.type.rawValue)] \(value)"
            }
            if let histogram = item.histogram {
                return "  \(identity) [histogram] count=\(histogram.count) sum=\(histogram.sum)"
            }
            if let summary = item.summary {
                let mean = summary.mean.map { String($0) } ?? "unavailable"
                return "  \(identity) [summary] count=\(summary.count) sum=\(summary.sum) mean=\(mean)"
            }
            return "  \(identity) [invalid]"
        }
        let sloLines = snapshot.slos.map { slo in
            let observed = slo.observed.map { String($0) } ?? "unavailable"
            return "  \(slo.name): \(slo.status.rawValue) samples=\(slo.sampleCount) observed=\(observed)"
        }
        return ([
            "Hostwright local metrics",
            "Schema: v\(snapshot.schemaVersion)",
            "State schema: v\(snapshot.source.schemaVersion)",
            "Source SHA-256: \(snapshot.source.databaseSHA256)",
            "Source bytes: \(snapshot.source.databaseBytes)",
            "Generated: \(snapshot.generatedAt)",
            "Series: \(snapshot.series.count)/\(HostwrightMetricCatalog.maximumSeries)",
            "Snapshot SHA-256: \(snapshot.snapshotSHA256)",
            "Retention authority: \(snapshot.retention.authority)",
            "Automatic upload: false",
            "Metrics:"
        ] + metricLines + ["SLOs:"] + sloLines + [""]).joined(separator: "\n")
    }
}

struct SecureLocalExportReceipt {
    let outputSHA256: String
    let outputBytes: UInt64
}

enum SecureLocalExportWriter {
    static func write(
        _ data: Data,
        to path: String,
        maximumBytes: Int,
        isCancelled: () -> Bool,
        unsafeError: any Error
    ) throws -> SecureLocalExportReceipt {
        guard data.count <= maximumBytes else { throw unsafeError }
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw unsafeError
        }
        let parent = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        guard !parent.isEmpty, !filename.isEmpty, filename != ".", filename != "..",
              filename.utf8.count <= 255,
              let resolved = realpath(parent, nil) else {
            throw unsafeError
        }
        defer { free(resolved) }
        guard String(cString: resolved) == parent else {
            throw unsafeError
        }

        let parentDescriptor = Darwin.open(
            parent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw unsafeError
        }
        defer { Darwin.close(parentDescriptor) }
        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == geteuid(),
              parentMetadata.st_mode & 0o077 == 0 else {
            throw unsafeError
        }
        try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
            fileDescriptor: parentDescriptor,
            path: parent,
            role: "local export parent"
        )
        guard !isCancelled() else {
            throw StateStoreError.operationCancelled(path: path)
        }

        let descriptor = filename.withCString { name in
            Darwin.openat(
                parentDescriptor,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw unsafeError
        }
        var created = stat()
        guard fstat(descriptor, &created) == 0,
              created.st_mode & S_IFMT == S_IFREG,
              created.st_uid == geteuid(),
              created.st_nlink == 1,
              created.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
            Darwin.close(descriptor)
            filename.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
            throw unsafeError
        }

        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                var current = stat()
                let matches = filename.withCString {
                    Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW) == 0
                } && current.st_dev == created.st_dev && current.st_ino == created.st_ino
                if matches {
                    filename.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
                    _ = Darwin.fsync(parentDescriptor)
                }
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !isCancelled() else {
                    throw StateStoreError.operationCancelled(path: path)
                }
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              finalMetadata.st_dev == created.st_dev,
              finalMetadata.st_ino == created.st_ino,
              finalMetadata.st_nlink == 1,
              finalMetadata.st_mode & S_IFMT == S_IFREG,
              finalMetadata.st_uid == geteuid(),
              finalMetadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              finalMetadata.st_size == data.count else {
            throw unsafeError
        }

        var observed = Data(count: data.count)
        var offset = 0
        while offset < observed.count {
            let readCount = observed.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += readCount
        }
        guard observed == data else {
            throw unsafeError
        }
        var pathMetadata = stat()
        let pathMatches = filename.withCString {
            Darwin.fstatat(parentDescriptor, $0, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0
        }
        guard pathMatches,
              pathMetadata.st_dev == created.st_dev,
              pathMetadata.st_ino == created.st_ino,
              pathMetadata.st_nlink == 1,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw unsafeError
        }
        guard !isCancelled() else {
            throw StateStoreError.operationCancelled(path: path)
        }
        let outputSHA256 = SHA256.hash(data: observed)
            .map { String(format: "%02x", $0) }
            .joined()
        completed = true
        return SecureLocalExportReceipt(
            outputSHA256: outputSHA256,
            outputBytes: UInt64(data.count)
        )
    }
}
