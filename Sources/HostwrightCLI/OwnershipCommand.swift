import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct OwnershipCommandRunner {
    let options: OwnershipCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration

    func run() throws -> CLIRunResult {
        let store = SQLiteStateStore(configuration: stateStoreConfiguration)
        switch options.action {
        case .status(let projectID):
            do {
                let ownership = try store.ownership.loadAll().filter {
                    projectID == nil || $0.projectID == projectID
                }
                let leases = try store.operationGroups.loadAll().filter {
                    ($0.status == .active || $0.status == .interrupted) &&
                        (projectID == nil || $0.projectID == projectID)
                }
                return CLIRunResult(
                    standardOutput: options.output == .json
                        ? try renderJSON(
                            ownership: ownership,
                            leases: leases,
                            handoff: nil
                        )
                        : renderText(
                            ownership: ownership,
                            leases: leases,
                            handoff: nil
                        )
                )
            } catch {
                throw HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message: RuntimeRedactionPolicy.default.redact(
                        String(describing: error)
                    )
                )
            }
        case let .handoff(
            groupID,
            planSHA256,
            fencingToken,
            priorControllerID,
            priorExpiry,
            targetControllerID,
            leaseSeconds
        ):
            let formatter = ISO8601DateFormatter()
            let now = Date()
            let timestamp = formatter.string(from: now)
            let replacementExpiry = formatter.string(
                from: now.addingTimeInterval(TimeInterval(leaseSeconds))
            )
            do {
                let handedOff = try store.operationGroups.handoffExpiredActive(
                    groupID: groupID,
                    expectedPlanHash: planSHA256,
                    expectedFencingToken: fencingToken,
                    expectedLockOwner: priorControllerID,
                    expectedLockExpiresAt: priorExpiry,
                    newLockOwner: targetControllerID,
                    newLockExpiresAt: replacementExpiry,
                    currentTimestamp: timestamp
                )
                return CLIRunResult(
                    standardOutput: options.output == .json
                        ? try renderJSON(
                            ownership: [],
                            leases: [handedOff],
                            handoff: handedOff
                        )
                        : renderText(
                            ownership: [],
                            leases: [handedOff],
                            handoff: handedOff
                        )
                )
            } catch {
                throw HostwrightDiagnostic(
                    code: .confirmationMismatch,
                    message: "Ownership handoff refused the stale, live, malformed, or mismatched lease tuple. " +
                        RuntimeRedactionPolicy.default.redact(
                            String(describing: error)
                        )
                )
            }
        }
    }

    private func renderText(
        ownership: [OwnershipRecord],
        leases: [OperationGroupRecord],
        handoff: OperationGroupRecord?
    ) -> String {
        var lines = [
            handoff == nil ? "Hostwright ownership authority" :
                "Hostwright ownership lease handed off",
            "State DB: \(stateStoreConfiguration.databasePath)",
            ""
        ]
        if handoff == nil {
            lines.append("Ownership:")
            if ownership.isEmpty {
                lines.append("- none")
            } else {
                for record in ownership {
                    let status = authorityStatus(record)
                    lines.append(
                        "- \(record.resourceIdentifier): \(status.classification) " +
                            "uuid=\(record.resourceUUID) generation=\(record.resourceGeneration) " +
                            "fence=\(record.fencingToken) finalizers=\(status.finalizers) " +
                            "handoffGeneration=\(status.handoffGeneration)"
                    )
                }
            }
            lines.append("")
            lines.append("Mutation leases:")
        }
        if leases.isEmpty {
            lines.append("- none")
        } else {
            for lease in leases.sorted(by: { $0.id < $1.id }) {
                lines.append(
                    "- \(lease.id): \(lease.status.rawValue) " +
                        "plan=\(lease.planHash) fence=\(lease.fencingToken) " +
                        "owner=\(lease.lockOwner ?? "none") " +
                        "expires=\(lease.lockExpiresAt ?? "none") " +
                        "checkpoint=\(lease.checkpoint)"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func renderJSON(
        ownership: [OwnershipRecord],
        leases: [OperationGroupRecord],
        handoff: OperationGroupRecord?
    ) throws -> String {
        let ownershipObjects: [[String: Any]] = ownership.map { record in
            let status = authorityStatus(record)
            var object: [String: Any] = [
                "authorityClassification": status.classification,
                "fencingToken": record.fencingToken,
                "finalizers": status.finalizers,
                "handoffGeneration": status.handoffGeneration,
                "projectGeneration": record.projectGeneration,
                "providerGeneration": record.providerGeneration,
                "providerID": record.runtimeAdapter,
                "resourceGeneration": record.resourceGeneration,
                "resourceIdentifier": record.resourceIdentifier,
                "resourceUUID": record.resourceUUID
            ]
            if let projectID = record.projectID {
                object["projectID"] = projectID
            }
            if let serviceName = record.serviceName {
                object["serviceName"] = serviceName
            }
            if let proof = status.proof {
                object["ownershipProofSHA256"] = proof
            }
            if let deletionTimestamp = status.deletionTimestamp {
                object["deletionTimestamp"] = deletionTimestamp
            }
            if let operationGroupID = status.operationGroupID {
                object["operationGroupID"] = operationGroupID
            }
            if let leaseOwner = status.leaseOwner {
                object["leaseOwner"] = leaseOwner
            }
            if let leaseExpiry = status.leaseExpiry {
                object["leaseExpiresAt"] = leaseExpiry
            }
            if let invalidReason = status.invalidReason {
                object["invalidReason"] = invalidReason
            }
            return object
        }
        let leaseObjects: [[String: Any]] = leases.sorted(by: {
            $0.id < $1.id
        }).map { lease in
            var object: [String: Any] = [
                "checkpoint": lease.checkpoint,
                "fencingToken": lease.fencingToken,
                "groupID": lease.id,
                "groupKind": lease.groupKind,
                "operationID": lease.operationID,
                "planSHA256": lease.planHash,
                "status": lease.status.rawValue
            ]
            if let projectID = lease.projectID {
                object["projectID"] = projectID
            }
            if let serviceName = lease.serviceName {
                object["serviceName"] = serviceName
            }
            if let lockOwner = lease.lockOwner {
                object["lockOwner"] = lockOwner
            }
            if let lockExpiresAt = lease.lockExpiresAt {
                object["lockExpiresAt"] = lockExpiresAt
            }
            return object
        }
        let object: [String: Any] = [
            "handoffCompleted": handoff != nil,
            "mutationLeases": leaseObjects,
            "ownership": ownershipObjects,
            "schemaVersion": 1,
            "stateDatabasePath": stateStoreConfiguration.databasePath
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "Ownership JSON encoding failed."
            )
        }
        return text + "\n"
    }

    private func authorityStatus(
        _ ownership: OwnershipRecord
    ) -> OwnershipAuthorityStatus {
        do {
            guard let authority = try OwnershipAuthorityMetadata.decode(
                from: ownership.metadataJSONRedacted
            ) else {
                return OwnershipAuthorityStatus(classification: "legacy")
            }
            try authority.validate(for: ownership)
            let states = Set(authority.finalizers.map(\.state))
            let classification: String
            if states == [.active] {
                classification = "active"
            } else if states == [.releasing] {
                classification = "deleting"
            } else if states == [.released] {
                classification = "released"
            } else {
                classification = "quarantined"
            }
            return OwnershipAuthorityStatus(
                classification: classification,
                proof: authority.ownershipProofSHA256,
                finalizers: authority.finalizers.map {
                    "\($0.name):\($0.state.rawValue)"
                }.joined(separator: ","),
                deletionTimestamp: authority.deletionTimestamp,
                operationGroupID: authority.operationGroupID,
                leaseOwner: authority.leaseOwner,
                leaseExpiry: authority.leaseExpiresAt,
                handoffGeneration: authority.handoffGeneration
            )
        } catch {
            return OwnershipAuthorityStatus(
                classification: "invalid",
                invalidReason: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        }
    }
}

private struct OwnershipAuthorityStatus {
    let classification: String
    let proof: String?
    let finalizers: String
    let deletionTimestamp: String?
    let operationGroupID: String?
    let leaseOwner: String?
    let leaseExpiry: String?
    let handoffGeneration: Int
    let invalidReason: String?

    init(
        classification: String,
        proof: String? = nil,
        finalizers: String = "none",
        deletionTimestamp: String? = nil,
        operationGroupID: String? = nil,
        leaseOwner: String? = nil,
        leaseExpiry: String? = nil,
        handoffGeneration: Int = 0,
        invalidReason: String? = nil
    ) {
        self.classification = classification
        self.proof = proof
        self.finalizers = finalizers
        self.deletionTimestamp = deletionTimestamp
        self.operationGroupID = operationGroupID
        self.leaseOwner = leaseOwner
        self.leaseExpiry = leaseExpiry
        self.handoffGeneration = handoffGeneration
        self.invalidReason = invalidReason
    }
}
