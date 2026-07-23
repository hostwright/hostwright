import Foundation

public enum AppleContainerStatsParser {
    public static let maximumBytes = 256 * 1_024

    public static func parse(
        _ text: String,
        expectedResourceIdentifier: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> RuntimeResourceUsageSnapshot {
        guard RuntimeManagedResourceIdentity.isCurrentIdentifier(expectedResourceIdentifier) else {
            throw RuntimeAdapterError.outputParseFailed("Resource stats require an exact versioned Hostwright identifier.")
        }

        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                text,
                operation: "Apple container stats",
                maximumBytes: maximumBytes
            )
            let payloads = try JSONDecoder().decode([StatsPayload].self, from: data)
            guard payloads.count == 1, let payload = payloads.first,
                  payload.id == expectedResourceIdentifier,
                  payload.numProcesses <= UInt64(Int.max) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container stats did not return exactly the requested Hostwright resource."
                )
            }
            return RuntimeResourceUsageSnapshot(
                resourceIdentifier: payload.id,
                cpuUsageMicroseconds: payload.cpuUsageUsec,
                memoryUsageBytes: payload.memoryUsageBytes,
                memoryLimitBytes: payload.memoryLimitBytes,
                networkReceiveBytes: payload.networkRxBytes,
                networkTransmitBytes: payload.networkTxBytes,
                blockReadBytes: payload.blockReadBytes,
                blockWriteBytes: payload.blockWriteBytes,
                processCount: Int(payload.numProcesses)
            )
        } catch let error as RuntimeAdapterError {
            throw error
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                redactionPolicy.redact("Could not parse Apple container stats JSON: \(error)")
            )
        }
    }

    private struct StatsPayload: Decodable {
        let id: String
        let cpuUsageUsec: UInt64
        let memoryUsageBytes: UInt64
        let memoryLimitBytes: UInt64
        let networkRxBytes: UInt64
        let networkTxBytes: UInt64
        let blockReadBytes: UInt64
        let blockWriteBytes: UInt64
        let numProcesses: UInt64
    }
}
