import Foundation
import HostwrightObservability
import HostwrightState

struct TraceCommandRunner {
    let options: TraceCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        let service = StateTraceService(
            store: SQLiteStateStore(configuration: stateStoreConfiguration),
            date: environment.traceDate
        )
        switch options.action {
        case .inspect(let traceID, let limit):
            let page = try service.inspect(traceID: traceID, limit: limit)
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? CLIJSON.codable(page)
                    : render(page)
            )
        case .export(let traceID, let outputPath, let confirmationSHA256):
            let trace = try service.completeTrace(traceID)
            guard trace.traceSHA256 == confirmationSHA256 else {
                throw HostwrightTraceError.confirmationMismatch
            }
            guard !environment.traceCancelled() else {
                throw StateStoreError.operationCancelled(path: outputPath)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(trace)
            let written = try SecureLocalExportWriter.write(
                data,
                to: outputPath,
                maximumBytes: HostwrightTraceContract.maximumExportBytes,
                isCancelled: environment.traceCancelled,
                unsafeError: HostwrightTraceError.unsafeExportPath
            )
            let receipt = HostwrightTraceExportReceipt(
                traceID: trace.traceID,
                traceSHA256: trace.traceSHA256,
                outputPath: outputPath,
                outputSHA256: written.outputSHA256,
                outputBytes: written.outputBytes
            )
            return CLIRunResult(
                standardOutput: options.output == .json
                    ? CLIJSON.codable(receipt)
                    : render(receipt)
            )
        }
    }

    private func render(_ page: HostwrightTracePage) -> String {
        var lines = [
            "Hostwright local traces",
            "Schema: v\(page.schemaVersion)",
            "Generated: \(page.generatedAt)",
            "Retained traces: \(page.retainedTraceCount)",
            "Retention authority: \(page.retentionAuthority)",
            "Automatic upload: false",
            "Traces:"
        ]
        if page.traces.isEmpty {
            lines.append("  none")
        }
        for trace in page.traces {
            lines.append(
                "  \(trace.traceID) status=\(trace.status?.rawValue ?? "incomplete") " +
                    "complete=\(trace.complete) spans=\(trace.spanCount) dropped=\(trace.droppedSpanCount)"
            )
            lines.append("    correlation: \(trace.processCorrelationID)")
            lines.append("    trace-sha256: \(trace.traceSHA256)")
            lines.append("    events: \(trace.eventIDs.count) operations: \(trace.operationIDs.count)")
            for span in trace.spans {
                lines.append(
                    "    span \(span.name.rawValue) status=\(span.status.rawValue) " +
                        "depth=\(span.depth) duration-ms=\(span.durationMilliseconds)"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func render(_ receipt: HostwrightTraceExportReceipt) -> String {
        """
        Hostwright trace export
        Schema: v\(receipt.schemaVersion)
        Trace: \(receipt.traceID)
        Trace SHA-256: \(receipt.traceSHA256)
        Output: \(receipt.outputPath)
        Output SHA-256: \(receipt.outputSHA256)
        Output bytes: \(receipt.outputBytes)
        Automatic upload: false
        Ownership: operator-owned

        """
    }
}
