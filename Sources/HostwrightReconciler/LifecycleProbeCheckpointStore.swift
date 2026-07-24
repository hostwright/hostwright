import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

public enum LifecycleProbeCheckpointError: Error, Equatable, Sendable {
    case invalidSnapshot
    case encodingFailed
    case decodingFailed
}

public struct LifecycleProbeCheckpointStore: Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshotBase64: String
        let snapshotSHA256: String
    }

    private static let schemaVersion = 1
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func save(
        _ snapshot: RuntimeProbeSnapshot,
        groupID: String,
        fencingToken: String,
        serviceName: String?,
        updatedAt: String
    ) throws {
        guard !snapshot.resourceIdentifier.isEmpty,
              HostwrightResourceUUID.isValid(fencingToken) else {
            throw LifecycleProbeCheckpointError.invalidSnapshot
        }
        let sanitized = Self.sanitized(snapshot)
        let snapshotData = try Self.encodeData(sanitized)
        let metadata = try Self.encode(
            Envelope(
                schemaVersion: Self.schemaVersion,
                snapshotBase64: snapshotData.base64EncodedString(),
                snapshotSHA256: Self.sha256(snapshotData)
            )
        )
        let status: OperationGroupStepStatus
        if sanitized.states.contains(where: { $0.phase == .executing }) {
            status = .started
        } else if sanitized.states.contains(where: {
            $0.phase == .failed || $0.phase == .unavailable
        }) {
            status = .failed
        } else if sanitized.states.allSatisfy({ $0.phase == .succeeded }) {
            status = .succeeded
        } else {
            status = .planned
        }
        let checkpointDigest = Self.sha256(metadata)
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: HostwrightResourceUUID.generate(),
                groupID: groupID,
                stepKey: Self.stepKey(for: sanitized.resourceIdentifier),
                direction: .forward,
                plannedActionType: "probe-checkpoint",
                serviceName: serviceName,
                resourceIdentifier: sanitized.resourceIdentifier,
                stepIdempotencyKey: "probe:\(checkpointDigest)",
                status: status,
                startedAt: status == .started ? updatedAt : nil,
                updatedAt: updatedAt,
                finishedAt: status == .started ? nil : updatedAt,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "",
                metadataJSONRedacted: metadata
            ),
            expectedFencingToken: fencingToken
        )
    }

    public func loadLatest(
        groupID: String,
        resourceIdentifier: String
    ) throws -> RuntimeProbeSnapshot? {
        guard !resourceIdentifier.isEmpty else {
            throw LifecycleProbeCheckpointError.invalidSnapshot
        }
        guard let record = try store.operationGroupSteps.latest(
            groupID: groupID,
            stepKey: Self.stepKey(for: resourceIdentifier)
        ) else {
            return nil
        }
        guard let data = record.metadataJSONRedacted.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == Self.schemaVersion,
              let snapshotData = Data(base64Encoded: envelope.snapshotBase64),
              Self.sha256(snapshotData) == envelope.snapshotSHA256,
              let snapshot = try? JSONDecoder().decode(
                  RuntimeProbeSnapshot.self,
                  from: snapshotData
              ),
              snapshot.resourceIdentifier == resourceIdentifier else {
            throw LifecycleProbeCheckpointError.decodingFailed
        }
        return snapshot
    }

    private static func sanitized(_ snapshot: RuntimeProbeSnapshot) -> RuntimeProbeSnapshot {
        RuntimeProbeSnapshot(
            resourceIdentifier: snapshot.resourceIdentifier,
            startedAtMilliseconds: snapshot.startedAtMilliseconds,
            states: snapshot.states.map { state in
                RuntimeProbeState(
                    kind: state.kind,
                    phase: state.phase,
                    isPassing: state.isPassing,
                    consecutiveSuccesses: state.consecutiveSuccesses,
                    consecutiveFailures: state.consecutiveFailures,
                    attemptCount: state.attemptCount,
                    inFlightAttempt: state.inFlightAttempt,
                    nextAttemptAtMilliseconds: state.nextAttemptAtMilliseconds,
                    lastAttemptAtMilliseconds: state.lastAttemptAtMilliseconds,
                    lastOutcome: state.lastOutcome,
                    lastDiagnosticRedacted: bounded(
                        RuntimeRedactionPolicy.default.redact(state.lastDiagnosticRedacted),
                        maximumBytes: RuntimeProbeAttemptResult.maximumDiagnosticBytes
                    )
                )
            }
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encodeData(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LifecycleProbeCheckpointError.encodingFailed
        }
        return text
    }

    private static func encodeData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func stepKey(for resourceIdentifier: String) -> String {
        "probe-\(sha256(resourceIdentifier))"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }
        var byteCount = 0
        var end = value.startIndex
        while end < value.endIndex {
            let next = value.index(after: end)
            let scalarBytes = value[end..<next].utf8.count
            guard byteCount + scalarBytes <= maximumBytes else { break }
            byteCount += scalarBytes
            end = next
        }
        return String(value[..<end])
    }
}
