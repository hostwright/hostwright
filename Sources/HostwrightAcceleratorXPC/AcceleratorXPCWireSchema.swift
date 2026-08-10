import Foundation

internal enum AcceleratorXPCWireSchema {
    private static let empty = Set<String>()

    static func validateRequestPayload(_ data: Data) throws {
        let root = try jsonObject(data, field: "payload")
        let kind = try string(root, "kind", field: "payload.kind")
        switch kind {
        case AcceleratorXPCOperation.inventory.rawValue:
            try exact(root, required: ["kind", "inventory"], field: "payload")
            try inventoryQuery(try object(root, "inventory", field: "payload.inventory"), field: "payload.inventory")
        case AcceleratorXPCOperation.status.rawValue:
            try exact(root, required: ["kind", "status"], field: "payload")
            try statusQuery(try object(root, "status", field: "payload.status"), field: "payload.status")
        case AcceleratorXPCOperation.execute.rawValue:
            try exact(root, required: ["kind", "execute"], field: "payload")
            try executePayload(try object(root, "execute", field: "payload.execute"), field: "payload.execute")
        case AcceleratorXPCOperation.cancel.rawValue:
            try exact(root, required: ["kind", "cancel"], field: "payload")
            try cancelPayload(try object(root, "cancel", field: "payload.cancel"), field: "payload.cancel")
        case AcceleratorXPCOperation.revoke.rawValue:
            try exact(root, required: ["kind", "revoke"], field: "payload")
            try revokePayload(try object(root, "revoke", field: "payload.revoke"), field: "payload.revoke")
        default:
            throw failure(.invalidOperation, "payload.kind")
        }
    }

    static func validateResponsePayload(_ data: Data) throws {
        let root = try jsonObject(data, field: "response.payload")
        let kind = try string(root, "kind", field: "response.payload.kind")
        switch kind {
        case "inventory":
            try exact(root, required: ["kind", "inventory"], field: "response.payload")
            try inventory(try object(root, "inventory", field: "response.payload.inventory"), field: "response.payload.inventory")
        case "status":
            try exact(root, required: ["kind", "status"], field: "response.payload")
            try statusSnapshot(try object(root, "status", field: "response.payload.status"), field: "response.payload.status")
        case "execution":
            try exact(root, required: ["kind", "execution"], field: "response.payload")
            try executionResult(try object(root, "execution", field: "response.payload.execution"), field: "response.payload.execution")
        case "acknowledgement":
            try exact(root, required: ["kind", "acknowledgement"], field: "response.payload")
            try acknowledgement(try object(root, "acknowledgement", field: "response.payload.acknowledgement"), field: "response.payload.acknowledgement")
        default:
            throw failure(.invalidPayload, "response.payload.kind")
        }
    }

    static func validateResponse(_ data: Data) throws {
        let root = try jsonObject(data, field: "response")
        let statusValue = try string(root, "status", field: "response.status")
        guard let status = AcceleratorXPCResponseStatus(rawValue: statusValue) else {
            throw failure(.invalidPayload, "response.status")
        }
        let hasPayload = root["payload"] != nil && !(root["payload"] is NSNull)
        let hasError = root["error"] != nil && !(root["error"] is NSNull)
        var required: Set<String> = [
            "protocolVersion", "operation", "requestID", "status",
            "idempotencyDigest", "serviceProof", "replayed"
        ]
        if status == .completed {
            required.insert("payload")
            guard !hasError else {
                throw failure(.invalidPayload, "response.error")
            }
        } else {
            required.insert("error")
            guard !hasPayload else {
                throw failure(.invalidPayload, "response.payload")
            }
        }
        try exact(root, required: required, field: "response")
        try proof(try object(root, "serviceProof", field: "response.serviceProof"), field: "response.serviceProof")
        if hasPayload {
            try validateRequestOrResponsePayloadValue(
                try object(root, "payload", field: "response.payload"),
                response: true
            )
        }
        if hasError {
            let errorValue = try object(root, "error", field: "response.error")
            try error(errorValue, field: "response.error")
            let codeValue = try string(errorValue, "code", field: "response.error.code")
            guard let code = AcceleratorXPCErrorCode(rawValue: codeValue), status.accepts(code) else {
                throw failure(.invalidPayload, "response.error.code")
            }
        }
    }

    private static func validateRequestOrResponsePayloadValue(
        _ root: [String: Any],
        response: Bool
    ) throws {
        let kind = try string(root, "kind", field: response ? "response.payload.kind" : "payload.kind")
        if response {
            switch kind {
            case "inventory":
                try exact(root, required: ["kind", "inventory"], field: "response.payload")
                try inventory(try object(root, "inventory", field: "response.payload.inventory"), field: "response.payload.inventory")
            case "status":
                try exact(root, required: ["kind", "status"], field: "response.payload")
                try statusSnapshot(try object(root, "status", field: "response.payload.status"), field: "response.payload.status")
            case "execution":
                try exact(root, required: ["kind", "execution"], field: "response.payload")
                try executionResult(try object(root, "execution", field: "response.payload.execution"), field: "response.payload.execution")
            case "acknowledgement":
                try exact(root, required: ["kind", "acknowledgement"], field: "response.payload")
                try acknowledgement(try object(root, "acknowledgement", field: "response.payload.acknowledgement"), field: "response.payload.acknowledgement")
            default:
                throw failure(.invalidPayload, "response.payload.kind")
            }
        } else {
            switch kind {
            case AcceleratorXPCOperation.inventory.rawValue:
                try exact(root, required: ["kind", "inventory"], field: "payload")
                try inventoryQuery(try object(root, "inventory", field: "payload.inventory"), field: "payload.inventory")
            case AcceleratorXPCOperation.status.rawValue:
                try exact(root, required: ["kind", "status"], field: "payload")
                try statusQuery(try object(root, "status", field: "payload.status"), field: "payload.status")
            case AcceleratorXPCOperation.execute.rawValue:
                try exact(root, required: ["kind", "execute"], field: "payload")
                try executePayload(try object(root, "execute", field: "payload.execute"), field: "payload.execute")
            case AcceleratorXPCOperation.cancel.rawValue:
                try exact(root, required: ["kind", "cancel"], field: "payload")
                try cancelPayload(try object(root, "cancel", field: "payload.cancel"), field: "payload.cancel")
            case AcceleratorXPCOperation.revoke.rawValue:
                try exact(root, required: ["kind", "revoke"], field: "payload")
                try revokePayload(try object(root, "revoke", field: "payload.revoke"), field: "payload.revoke")
            default:
                throw failure(.invalidOperation, "payload.kind")
            }
        }
    }

    private static func inventoryQuery(_ value: [String: Any], field: String) throws {
        try exact(value, required: ["contractVersion", "hostID", "requester", "observedAt"], field: field)
        try authentication(try object(value, "requester", field: "\(field).requester"), field: "\(field).requester")
    }

    private static func statusQuery(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "hostID", "inventorySnapshotID", "inventoryGeneration",
            "requester", "observedAt"
        ], field: field)
        try authentication(try object(value, "requester", field: "\(field).requester"), field: "\(field).requester")
    }

    private static func executePayload(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "request", "claim", "grant", "reservation", "inventory",
            "inputPayload", "observedAt"
        ], field: field)
        try executionRequest(try object(value, "request", field: "\(field).request"), field: "\(field).request")
        try claim(try object(value, "claim", field: "\(field).claim"), field: "\(field).claim")
        try grant(try object(value, "grant", field: "\(field).grant"), field: "\(field).grant")
        try reservation(try object(value, "reservation", field: "\(field).reservation"), field: "\(field).reservation")
        try inventory(try object(value, "inventory", field: "\(field).inventory"), field: "\(field).inventory")
    }

    private static func cancelPayload(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "executionRequest", "cancellation", "claim", "grant",
            "reservation", "inventory", "observedAt"
        ], field: field)
        try executionRequest(try object(value, "executionRequest", field: "\(field).executionRequest"), field: "\(field).executionRequest")
        try cancellation(try object(value, "cancellation", field: "\(field).cancellation"), field: "\(field).cancellation")
        try claim(try object(value, "claim", field: "\(field).claim"), field: "\(field).claim")
        try grant(try object(value, "grant", field: "\(field).grant"), field: "\(field).grant")
        try reservation(try object(value, "reservation", field: "\(field).reservation"), field: "\(field).reservation")
        try inventory(try object(value, "inventory", field: "\(field).inventory"), field: "\(field).inventory")
    }

    private static func revokePayload(_ value: [String: Any], field: String) throws {
        try exact(value, required: ["contractVersion", "revocation", "observedAt"], optional: ["claim", "grant", "reservation"], field: field)
        try revocation(try object(value, "revocation", field: "\(field).revocation"), field: "\(field).revocation")
        if let claimValue = optionalObject(value, "claim") {
            try claim(claimValue, field: "\(field).claim")
        }
        if let grantValue = optionalObject(value, "grant") {
            try grant(grantValue, field: "\(field).grant")
        }
        if let reservationValue = optionalObject(value, "reservation") {
            try reservation(reservationValue, field: "\(field).reservation")
        }
    }

    private static func executionRequest(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "requestID", "grantID", "reservationID", "scope", "mode",
            "modelHash", "inputDigest", "inputBytes", "outputLimitBytes", "timeoutMilliseconds",
            "budget", "fence", "authentication", "requestedAt"
        ], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try budgetVector(try object(value, "budget", field: "\(field).budget"), field: "\(field).budget")
        try fence(try object(value, "fence", field: "\(field).fence"), field: "\(field).fence")
        try authentication(try object(value, "authentication", field: "\(field).authentication"), field: "\(field).authentication")
    }

    private static func claim(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "claimID", "scope", "allowedModes", "quota",
            "inventorySnapshotID", "inventoryGeneration", "issuer", "issuedAt", "expiresAt"
        ], optional: ["modelHash"], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try quota(try object(value, "quota", field: "\(field).quota"), field: "\(field).quota")
        try authentication(try object(value, "issuer", field: "\(field).issuer"), field: "\(field).issuer")
    }

    private static func grant(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "grantID", "claimID", "reservationID", "scope", "granteeSubjectID",
            "mode", "quota", "inventorySnapshotID", "inventoryGeneration", "fence", "issuer",
            "issuedAt", "expiresAt"
        ], optional: ["modelHash"], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try quota(try object(value, "quota", field: "\(field).quota"), field: "\(field).quota")
        try fence(try object(value, "fence", field: "\(field).fence"), field: "\(field).fence")
        try authentication(try object(value, "issuer", field: "\(field).issuer"), field: "\(field).issuer")
    }

    private static func reservation(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "reservationID", "claimID", "scope", "mode", "budget",
            "inventorySnapshotID", "inventoryGeneration", "fence", "owner", "createdAt",
            "expiresAt", "state", "lastTransitionAt"
        ], optional: ["modelHash"], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try budgetVector(try object(value, "budget", field: "\(field).budget"), field: "\(field).budget")
        try fence(try object(value, "fence", field: "\(field).fence"), field: "\(field).fence")
        try authentication(try object(value, "owner", field: "\(field).owner"), field: "\(field).owner")
    }

    private static func inventory(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "snapshotID", "hostID", "observedAt", "observedGeneration",
            "modeEvidence", "budgets"
        ], field: field)
        try array(value, "modeEvidence", field: "\(field).modeEvidence").enumerated().forEach { index, item in
            try modeEvidence(try object(item, field: "\(field).modeEvidence[\(index)]"), field: "\(field).modeEvidence[\(index)]")
        }
        try array(value, "budgets", field: "\(field).budgets").enumerated().forEach { index, item in
            try measuredBudget(try object(item, field: "\(field).budgets[\(index)]"), field: "\(field).budgets[\(index)]")
        }
    }

    private static func statusSnapshot(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "hostID", "inventorySnapshotID", "inventoryGeneration",
            "observedAt", "availability"
        ], field: field)
    }

    private static func modeEvidence(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "mode", "status", "evidenceDigest", "source", "observedGeneration"
        ], optional: ["reasonCode", "executionEvidence"], field: field)
        if let executionEvidence = optionalObject(value, "executionEvidence") {
            try exact(executionEvidence, required: [
                "contractVersion", "mode", "backendIdentifier", "frameworkIdentifier",
                "operatingSystem", "executionDigest", "provenanceDigest", "outcome",
                "observedGeneration", "observedAt", "completedAt"
            ], field: "\(field).executionEvidence")
        }
    }

    private static func measuredBudget(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "mode", "kind", "amount", "unit", "source", "observedGeneration",
            "measurementEvidence", "measurementEvidenceDigest"
        ], field: field)
        let measurementEvidence = try object(
            value,
            "measurementEvidence",
            field: "\(field).measurementEvidence"
        )
        try exact(
            measurementEvidence,
            required: ["executionDigest", "provenanceDigest", "observedGeneration"],
            field: "\(field).measurementEvidence"
        )
    }

    private static func budgetVector(_ value: [String: Any], field: String) throws {
        try exact(value, required: ["memoryBytes", "computeUnits", "concurrencyUnits"], field: field)
    }

    private static func quota(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "budget", "maxInputBytes", "maxOutputBytes", "maxTimeoutMilliseconds"
        ], field: field)
        try budgetVector(try object(value, "budget", field: "\(field).budget"), field: "\(field).budget")
    }

    private static func scope(_ value: [String: Any], field: String) throws {
        let kind = try string(value, "kind", field: "\(field).kind")
        switch kind {
        case "project":
            try exact(value, required: ["kind", "projectID"], field: field)
        case "workload":
            try exact(value, required: ["kind", "projectID", "workloadID"], field: field)
        default:
            throw failure(.invalidPayload, "\(field).kind")
        }
    }

    private static func fence(_ value: [String: Any], field: String) throws {
        try exact(value, required: ["nodeEpoch", "reservationSequence"], field: field)
    }

    private static func authentication(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "subjectID", "sessionID", "authenticationDigest",
            "authenticatedAt", "expiresAt"
        ], optional: ["credentialID"], field: field)
    }

    private static func cancellation(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "cancellationID", "requestID", "grantID", "reservationID",
            "scope", "fence", "actor", "reason", "requestedAt", "state"
        ], optional: ["effectiveAt"], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try fence(try object(value, "fence", field: "\(field).fence"), field: "\(field).fence")
        try authentication(try object(value, "actor", field: "\(field).actor"), field: "\(field).actor")
    }

    private static func revocation(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "revocationID", "targetKind", "targetIdentifier", "actor",
            "reason", "evidenceDigest", "revokedAt"
        ], optional: ["scope", "fence"], field: field)
        if let scopeValue = optionalObject(value, "scope") {
            try scope(scopeValue, field: "\(field).scope")
        }
        if let fenceValue = optionalObject(value, "fence") {
            try fence(fenceValue, field: "\(field).fence")
        }
        try authentication(try object(value, "actor", field: "\(field).actor"), field: "\(field).actor")
    }

    private static func executionResult(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "requestID", "grantID", "reservationID", "scope", "mode",
            "modelHash", "fence", "outcome", "outputBytes", "completedAt", "authenticatedBy"
        ], optional: ["outputDigest", "usage", "provenance", "errorCode"], field: field)
        try scope(try object(value, "scope", field: "\(field).scope"), field: "\(field).scope")
        try fence(try object(value, "fence", field: "\(field).fence"), field: "\(field).fence")
        try authentication(try object(value, "authenticatedBy", field: "\(field).authenticatedBy"), field: "\(field).authenticatedBy")
        if let usage = optionalObject(value, "usage") {
            try measuredUsage(usage, field: "\(field).usage")
        }
        if let provenanceValue = optionalObject(value, "provenance") {
            try provenance(provenanceValue, field: "\(field).provenance")
        }
    }

    private static func measuredUsage(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "budget", "source", "observedGeneration", "authenticatedBy", "observedAt"
        ], field: field)
        try budgetVector(try object(value, "budget", field: "\(field).budget"), field: "\(field).budget")
        try authentication(try object(value, "authenticatedBy", field: "\(field).authenticatedBy"), field: "\(field).authenticatedBy")
    }

    private static func provenance(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "requestID", "mode", "modelHash", "inventorySnapshotID",
            "inventoryGeneration", "evidenceDigest", "source", "authenticatedBy", "recordedAt"
        ], field: field)
        try authentication(try object(value, "authenticatedBy", field: "\(field).authenticatedBy"), field: "\(field).authenticatedBy")
    }

    private static func acknowledgement(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "contractVersion", "operation", "targetIdentifier", "observedAt"
        ], optional: ["fence"], field: field)
        if let fenceValue = optionalObject(value, "fence") {
            try fence(fenceValue, field: "\(field).fence")
        }
    }

    private static func proof(_ value: [String: Any], field: String) throws {
        try exact(value, required: [
            "teamIdentifier", "signingIdentifier", "codeDirectoryHash", "entitlementProjection"
        ], field: field)
        guard let entitlements = value["entitlementProjection"] as? [String: Any] else {
            throw failure(.invalidPayload, "\(field).entitlementProjection")
        }
        try exact(entitlements, required: ["com.apple.security.app-sandbox"], field: "\(field).entitlementProjection")
    }

    private static func error(_ value: [String: Any], field: String) throws {
        try exact(value, required: ["code", "message"], field: field)
    }

    private static func jsonObject(_ data: Data, field: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw failure(.invalidPayload, field)
        }
        return object
    }

    private static func object(
        _ parent: [String: Any],
        _ key: String,
        field: String
    ) throws -> [String: Any] {
        guard let value = parent[key], !(value is NSNull), let object = value as? [String: Any] else {
            throw failure(.invalidPayload, field)
        }
        return object
    }

    private static func object(_ value: Any, field: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw failure(.invalidPayload, field)
        }
        return object
    }

    private static func optionalObject(
        _ parent: [String: Any],
        _ key: String
    ) -> [String: Any]? {
        guard let value = parent[key], !(value is NSNull) else { return nil }
        return value as? [String: Any]
    }

    private static func array(
        _ parent: [String: Any],
        _ key: String,
        field: String
    ) throws -> [Any] {
        guard let values = parent[key] as? [Any] else {
            throw failure(.invalidPayload, field)
        }
        return values
    }

    private static func string(
        _ parent: [String: Any],
        _ key: String,
        field: String
    ) throws -> String {
        guard let value = parent[key] as? String else {
            throw failure(.invalidPayload, field)
        }
        return value
    }

    private static func exact(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = empty,
        field: String
    ) throws {
        let keys = Set(object.keys)
        let allowed = required.union(optional)
        guard required.isSubset(of: keys) else {
            throw failure(.invalidPayload, field)
        }
        guard keys.isSubset(of: allowed) else {
            throw failure(.unknownField, field)
        }
    }

    private static func exact(
        _ object: [String: Any],
        required: [String],
        optional: [String] = [],
        field: String
    ) throws {
        try exact(
            object,
            required: Set(required),
            optional: Set(optional),
            field: field
        )
    }

    private static func failure(
        _ code: AcceleratorXPCErrorCode,
        _ field: String
    ) -> AcceleratorXPCValidationError {
        AcceleratorXPCValidationError(code: code, field: field)
    }
}
