import CryptoKit
import Foundation
import HostwrightCore

public enum OwnershipFinalizerState: String, Codable, Equatable, Sendable {
    case active
    case releasing
    case released
    case quarantined
}

public struct OwnershipFinalizerRecord: Codable, Equatable, Sendable {
    public let name: String
    public let state: OwnershipFinalizerState

    public init(name: String, state: OwnershipFinalizerState) {
        self.name = name
        self.state = state
    }
}

public struct OwnershipAuthorityRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let metadataKey = "hostwrightAuthority"
    public static let lifecycleController = "hostwright.lifecycle"

    public let schemaVersion: Int
    public let controllerID: String
    public let providerID: String
    public let ownershipProofSHA256: String
    public let resourceUUID: String
    public let resourceGeneration: Int
    public let projectResourceUUID: String?
    public let projectGeneration: Int
    public let providerGeneration: Int
    public let fencingToken: String
    public let finalizers: [OwnershipFinalizerRecord]
    public let deletionTimestamp: String?
    public let operationGroupID: String?
    public let leaseOwner: String?
    public let leaseExpiresAt: String?
    public let handoffGeneration: Int

    public init(
        controllerID: String,
        providerID: String,
        ownershipProofSHA256: String,
        resourceUUID: String,
        resourceGeneration: Int,
        projectResourceUUID: String?,
        projectGeneration: Int,
        providerGeneration: Int,
        fencingToken: String,
        finalizers: [OwnershipFinalizerRecord],
        deletionTimestamp: String?,
        operationGroupID: String?,
        leaseOwner: String?,
        leaseExpiresAt: String?,
        handoffGeneration: Int,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.controllerID = controllerID
        self.providerID = providerID
        self.ownershipProofSHA256 = ownershipProofSHA256
        self.resourceUUID = resourceUUID
        self.resourceGeneration = resourceGeneration
        self.projectResourceUUID = projectResourceUUID
        self.projectGeneration = projectGeneration
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
        self.finalizers = finalizers
        self.deletionTimestamp = deletionTimestamp
        self.operationGroupID = operationGroupID
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.handoffGeneration = handoffGeneration
    }

    public static func lifecycle(
        ownership: OwnershipRecord,
        operationGroup: OperationGroupRecord,
        finalizerState: OwnershipFinalizerState,
        deletionTimestamp: String? = nil,
        handoffGeneration: Int = 0
    ) throws -> OwnershipAuthorityRecord {
        let proof = proofSHA256(
            ownership: ownership,
            controllerID: lifecycleController,
            providerID: ownership.runtimeAdapter,
            fencingToken: ownership.fencingToken
        )
        let record = OwnershipAuthorityRecord(
            controllerID: lifecycleController,
            providerID: ownership.runtimeAdapter,
            ownershipProofSHA256: proof,
            resourceUUID: ownership.resourceUUID,
            resourceGeneration: ownership.resourceGeneration,
            projectResourceUUID: ownership.projectResourceUUID,
            projectGeneration: ownership.projectGeneration,
            providerGeneration: ownership.providerGeneration,
            fencingToken: ownership.fencingToken,
            finalizers: [
                OwnershipFinalizerRecord(
                    name: "dependent.resources",
                    state: finalizerState
                ),
                OwnershipFinalizerRecord(
                    name: "runtime.absence",
                    state: finalizerState
                )
            ],
            deletionTimestamp: deletionTimestamp,
            operationGroupID: operationGroup.id,
            leaseOwner: operationGroup.lockOwner,
            leaseExpiresAt: operationGroup.lockExpiresAt,
            handoffGeneration: handoffGeneration
        )
        try record.validate(for: ownership)
        return record
    }

    public func validate(for ownership: OwnershipRecord) throws {
        let finalizerNames = finalizers.map(\.name)
        guard schemaVersion == Self.currentSchemaVersion,
              controllerID.range(
                  of: "^[a-z0-9][a-z0-9.-]{0,127}$",
                  options: .regularExpression
              ) != nil,
              !providerID.isEmpty,
              providerID.utf8.count <= 128,
              ownershipProofSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              resourceUUID == ownership.resourceUUID,
              resourceGeneration == ownership.resourceGeneration,
              projectResourceUUID == ownership.projectResourceUUID,
              projectGeneration == ownership.projectGeneration,
              providerGeneration == ownership.providerGeneration,
              providerID == ownership.runtimeAdapter,
              fencingToken == ownership.fencingToken,
              HostwrightResourceUUID.isValid(fencingToken),
              finalizers.count == 2,
              finalizerNames == finalizerNames.sorted(),
              Set(finalizerNames).count == finalizerNames.count,
              finalizerNames == ["dependent.resources", "runtime.absence"],
              handoffGeneration >= 0,
              operationGroupID.map(HostwrightResourceUUID.isValid) ?? true,
              leaseOwner.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              leaseExpiresAt.map(Self.isTimestamp) ?? true,
              deletionTimestamp.map(Self.isTimestamp) ?? true,
              (leaseOwner == nil) == (leaseExpiresAt == nil),
              ownershipProofSHA256 == Self.proofSHA256(
                  ownership: ownership,
                  controllerID: controllerID,
                  providerID: providerID,
                  fencingToken: fencingToken
              ) else {
            throw StateStoreError.invalidRecord(
                "Ownership authority identity, proof, finalizer, lease, deletion, or fencing evidence is invalid."
            )
        }
        let states = Set(finalizers.map(\.state))
        if deletionTimestamp == nil {
            guard states == [.active] else {
                throw StateStoreError.invalidRecord(
                    "Live ownership authority requires active finalizers and no deletion timestamp."
                )
            }
        } else {
            guard states.count == 1,
                  let state = states.first,
                  [.releasing, .released, .quarantined].contains(state) else {
                throw StateStoreError.invalidRecord(
                    "Deleting ownership authority requires one consistent releasing, released, or quarantined finalizer state."
                )
            }
        }
    }

    public static func proofSHA256(
        ownership: OwnershipRecord,
        controllerID: String,
        providerID: String,
        fencingToken: String
    ) -> String {
        let canonical = [
            "ownership-authority-v1",
            ownership.resourceIdentifier,
            ownership.resourceType,
            ownership.projectID ?? "",
            ownership.serviceName ?? "",
            controllerID,
            providerID,
            ownership.resourceUUID,
            String(ownership.resourceGeneration),
            ownership.projectResourceUUID ?? "",
            String(ownership.projectGeneration),
            String(ownership.providerGeneration),
            fencingToken
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isTimestamp(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value) != nil
    }
}

public enum OwnershipAuthorityMetadata {
    public static func decode(
        from metadataJSON: String
    ) throws -> OwnershipAuthorityRecord? {
        guard metadataJSON.utf8.count <= 1_048_576,
              let data = metadataJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw StateStoreError.invalidRecord(
                "Ownership metadata must be one bounded JSON object."
            )
        }
        guard let authorityObject = object[OwnershipAuthorityRecord.metadataKey]
        else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(authorityObject) else {
            throw StateStoreError.invalidRecord(
                "Ownership authority metadata is not a JSON object."
            )
        }
        let authorityData = try JSONSerialization.data(
            withJSONObject: authorityObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        do {
            return try JSONDecoder().decode(
                OwnershipAuthorityRecord.self,
                from: authorityData
            )
        } catch {
            throw StateStoreError.invalidRecord(
                "Ownership authority metadata does not match contract v1."
            )
        }
    }

    public static func encode(
        _ authority: OwnershipAuthorityRecord,
        into metadataJSON: String
    ) throws -> String {
        guard let data = metadataJSON.data(using: .utf8),
              var object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw StateStoreError.invalidRecord(
                "Ownership metadata must be a JSON object."
            )
        }
        let authorityData = try JSONEncoder().encode(authority)
        let authorityObject = try JSONSerialization.jsonObject(
            with: authorityData
        )
        object[OwnershipAuthorityRecord.metadataKey] = authorityObject
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard encoded.count <= 1_048_576,
              let result = String(data: encoded, encoding: .utf8) else {
            throw StateStoreError.invalidRecord(
                "Ownership authority metadata exceeds its bounded JSON contract."
            )
        }
        return result
    }
}
