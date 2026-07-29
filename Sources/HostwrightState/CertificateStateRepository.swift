import Foundation
import HostwrightCore
import HostwrightRuntime

public struct CertificateStateRepository: Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    static func invalidStoredRecordCount(on connection: SQLiteConnection) throws -> Int {
        var invalid = 0
        for row in try connection.query(select + " ORDER BY id") {
            do {
                let value = try record(row)
                try validateStoredBinding(value, on: connection)
            } catch {
                invalid += 1
            }
        }
        return invalid
    }

    @discardableResult public func save(
        _ record: CertificateStateRecord,
        replacing expected: NetworkStateExpectedVersion? = nil,
        authority: NetworkStateMutationAuthority
    ) throws -> CertificateStateRecord {
        try Self.validate(record)
        try Self.validate(authority)
        guard authority.providerID == record.providerID, authority.providerGeneration == record.providerGeneration,
            authority.operationGroupID == record.operationGroupID, authority.fencingToken == record.fencingToken
        else {
            throw StateStoreError.invalidRecord(
                "Certificate mutation authority must exactly match provider, generation, operation group, and fence."
            )
        }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                try Self.validateBinding(record, authority: authority, on: connection)
                if let old = try Self.load(id: record.id, on: connection) {
                    guard let expected, expected.generation == old.generation,
                        expected.fencingToken == old.fencingToken, record.generation == old.generation + 1,
                        record.id == old.id, record.projectUUID == old.projectUUID,
                        record.manifestName == old.manifestName, record.sourceKind == old.sourceKind,
                        record.ownershipKind == old.ownershipKind,
                        Self.transition(old.lifecycleState, record.lifecycleState)
                    else {
                        throw StateStoreError.invalidRecord(
                            "Certificate replacement lost immutable identity, exact fence, or legal lifecycle order."
                        )
                    }
                    try connection.run(
                        "UPDATE network_certificates SET generation=?,provider_generation=?,fencing_token=?,leaf_sha256=?,issuer_sha256=?,san_json=?,eku_json=?,not_before=?,not_after=?,status=?,revocation_status=?,status_checked_at=?,desired_sha256=?,observed_sha256=?,lifecycle_state=?,finalizer_state=?,prior_leaf_sha256=?,operation_group_id=?,updated_at=? WHERE id=? AND generation=? AND fencing_token=?",
                        bindings: Self.updateBindings(record) + [
                            .text(record.id), .int64(expected.generation), .text(expected.fencingToken),
                        ]
                    )
                } else {
                    guard expected == nil, record.generation == 1, record.lifecycleState == .creating,
                        record.finalizerState == .pending, record.status == .creating, record.observedSHA256 == nil
                    else {
                        throw StateStoreError.invalidRecord(
                            "New certificates require generation-one durable create intent."
                        )
                    }
                    try connection.run(
                        "INSERT INTO network_certificates (id,project_uuid,manifest_name,generation,provider_id,provider_generation,fencing_token,source_kind,ownership_kind,leaf_sha256,issuer_sha256,san_json,eku_json,not_before,not_after,status,revocation_status,status_checked_at,desired_sha256,observed_sha256,lifecycle_state,finalizer_state,prior_leaf_sha256,operation_group_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        bindings: Self.insertBindings(record)
                    )
                }
                guard try Self.load(id: record.id, on: connection) == record else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Certificate compare-and-swap did not persist the exact record."
                    )
                }
                return record
            }
        }
    }
    public func load(id: String) throws -> CertificateStateRecord? {
        try store.withValidatedConnection(readOnly: true) { try Self.load(id: id, on: $0) }
    }
    public func list(projectUUID: String) throws -> [CertificateStateRecord] {
        try store.withValidatedConnection(readOnly: true) {
            try $0.query(
                Self.select + " WHERE project_uuid=? ORDER BY manifest_name,id",
                bindings: [.text(projectUUID)]
            ).map(Self.record)
        }
    }
    public func purge(
        id: String,
        expected: NetworkStateExpectedVersion,
        authority: NetworkStateMutationAuthority
    ) throws {
        try Self.validateUUID(id, label: "certificate id")
        try Self.validate(expected)
        try Self.validate(authority)

        try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let record = try Self.load(id: id, on: connection) else {
                    throw StateStoreError.notFound("Certificate does not exist.")
                }
                guard record.generation == expected.generation,
                    record.fencingToken == expected.fencingToken,
                    record.isStatePurgeable,
                    record.lifecycleState == .deleted,
                    record.finalizerState == .released
                else {
                    throw StateStoreError.invalidRecord(
                        "Only exact released certificate state records can be purged."
                    )
                }
                guard authority.providerID == record.providerID,
                    authority.providerGeneration == record.providerGeneration,
                    authority.operationGroupID == record.operationGroupID,
                    authority.fencingToken == record.fencingToken
                else {
                    throw StateStoreError.invalidRecord(
                        "Certificate purge authority does not match the exact stored ownership fence."
                    )
                }
                try Self.validateBinding(record, authority: authority, on: connection)
                try connection.run(
                    """
                    DELETE FROM network_certificates
                    WHERE id = ? AND generation = ? AND fencing_token = ?
                      AND lifecycle_state = 'deleted'
                      AND finalizer_state = 'released'
                    """,
                    bindings: [
                        .text(id),
                        .int64(expected.generation),
                        .text(expected.fencingToken),
                    ]
                )
                guard try Self.load(id: id, on: connection) == nil else {
                    throw StateStoreError.transactionInvariantViolation(
                        message: "Certificate exact owned purge did not remove the terminal record."
                    )
                }
            }
        }
    }
    private static let select =
        "SELECT id,project_uuid,manifest_name,generation,provider_id,provider_generation,fencing_token,source_kind,ownership_kind,leaf_sha256,issuer_sha256,san_json,eku_json,not_before,not_after,status,revocation_status,status_checked_at,desired_sha256,observed_sha256,lifecycle_state,finalizer_state,prior_leaf_sha256,operation_group_id,created_at,updated_at FROM network_certificates"
    private static func load(id: String, on c: SQLiteConnection) throws -> CertificateStateRecord? {
        try c.query(select + " WHERE id=? LIMIT 1", bindings: [.text(id)]).first.map(record)
    }
    private static func record(_ r: [String?]) throws -> CertificateStateRecord {
        guard r.count == 26, let id = r[0], let p = r[1], let n = r[2], let g = r[3].flatMap(Int64.init), let pi = r[4],
            let pg = r[5].flatMap(Int64.init), let f = r[6], let s = r[7].flatMap(CertificateSourceKind.init),
            let o = r[8].flatMap(CertificateOwnershipKind.init), let l = r[9], let san = r[11], let eku = r[12],
            let nb = r[13], let na = r[14], let st = r[15].flatMap(CertificateStatus.init),
            let rv = r[16].flatMap(CertificateRevocationStatus.init), let d = r[18],
            let lc = r[20].flatMap(NetworkStateResourceLifecycle.init),
            let fi = r[21].flatMap(NetworkStateFinalizer.init), let op = r[23], let ca = r[24], let ua = r[25]
        else { throw StateStoreError.invalidRecord("Could not decode certificate state.") }
        let value = CertificateStateRecord(
            id: id,
            projectUUID: p,
            manifestName: n,
            generation: g,
            providerID: pi,
            providerGeneration: pg,
            fencingToken: f,
            sourceKind: s,
            ownershipKind: o,
            leafSHA256: l,
            issuerSHA256: r[10],
            sanJSON: san,
            ekuJSON: eku,
            notBefore: nb,
            notAfter: na,
            status: st,
            revocationStatus: rv,
            statusCheckedAt: r[17],
            desiredSHA256: d,
            observedSHA256: r[19],
            lifecycleState: lc,
            finalizerState: fi,
            priorLeafSHA256: r[22],
            operationGroupID: op,
            createdAt: ca,
            updatedAt: ua
        )
        try validate(value)
        return value
    }
    private static func insertBindings(_ x: CertificateStateRecord) -> [SQLiteValue] {
        [
            .text(x.id),
            .text(x.projectUUID),
            .text(x.manifestName),
            .int64(x.generation),
            .text(x.providerID),
            .int64(x.providerGeneration),
            .text(x.fencingToken),
            .text(x.sourceKind.rawValue),
            .text(x.ownershipKind.rawValue),
            .text(x.leafSHA256),
            optionalText(x.issuerSHA256),
            .text(x.sanJSON),
            .text(x.ekuJSON),
            .text(x.notBefore),
            .text(x.notAfter),
            .text(x.status.rawValue),
            .text(x.revocationStatus.rawValue),
            optionalText(x.statusCheckedAt),
            .text(x.desiredSHA256),
            optionalText(x.observedSHA256),
            .text(x.lifecycleState.rawValue),
            .text(x.finalizerState.rawValue),
            optionalText(x.priorLeafSHA256),
            .text(x.operationGroupID),
            .text(x.createdAt),
            .text(x.updatedAt),
        ]
    }

    private static func updateBindings(_ x: CertificateStateRecord) -> [SQLiteValue] {
        [
            .int64(x.generation),
            .int64(x.providerGeneration),
            .text(x.fencingToken),
            .text(x.leafSHA256),
            optionalText(x.issuerSHA256),
            .text(x.sanJSON),
            .text(x.ekuJSON),
            .text(x.notBefore),
            .text(x.notAfter),
            .text(x.status.rawValue),
            .text(x.revocationStatus.rawValue),
            optionalText(x.statusCheckedAt),
            .text(x.desiredSHA256),
            optionalText(x.observedSHA256),
            .text(x.lifecycleState.rawValue),
            .text(x.finalizerState.rawValue),
            optionalText(x.priorLeafSHA256),
            .text(x.operationGroupID),
            .text(x.updatedAt),
        ]
    }
    private static func validate(_ x: CertificateStateRecord) throws {
        try validateUUID(x.id, label: "certificate id")
        try validateUUID(x.projectUUID, label: "certificate project UUID")
        try validateUUID(x.fencingToken, label: "certificate fence")
        try validateUUID(x.operationGroupID, label: "certificate operation group")
        try validate(
            NetworkStateExpectedVersion(
                generation: x.generation,
                fencingToken: x.fencingToken
            )
        )
        guard x.providerGeneration >= 1,
            RuntimeProviderBinding.stableID(for: x.providerID)?.rawValue == x.providerID,
            x.manifestName.range(
                of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$",
                options: .regularExpression
            ) != nil
        else {
            throw StateStoreError.invalidRecord("Certificate metadata is not bounded canonical data.")
        }
        for digest in [x.leafSHA256, x.desiredSHA256]
            + [x.issuerSHA256].compactMap({ $0 })
            + [x.observedSHA256, x.priorLeafSHA256].compactMap({ $0 })
        {
            try validateSHA256(digest)
        }
        for json in [x.sanJSON, x.ekuJSON] {
            try validateJSONArray(json)
        }
        guard (x.sourceKind == .imported) == (x.ownershipKind == .external),
            x.ownershipKind != .managed || x.issuerSHA256 != nil,
            legal(x)
        else {
            throw StateStoreError.invalidRecord("Certificate ownership or lifecycle is inconsistent.")
        }
    }

    private static func validateUUID(_ value: String, label: String) throws {
        guard HostwrightResourceUUID.isValid(value) else {
            throw StateStoreError.invalidRecord("\(label) must be a canonical UUID.")
        }
    }

    private static func validate(_ expected: NetworkStateExpectedVersion) throws {
        guard expected.generation >= 1 else {
            throw StateStoreError.invalidRecord("Certificate generation must be positive.")
        }
        try validateUUID(expected.fencingToken, label: "certificate expected fence")
    }

    private static func validateSHA256(_ value: String) throws {
        guard value.count == 64,
            value.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
        else {
            throw StateStoreError.invalidRecord("Certificate digest must be lowercase SHA256.")
        }
    }

    private static func validateJSONArray(_ value: String) throws {
        guard value.utf8.count <= 16_384,
            let data = value.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data),
            array is [Any],
            let canonical = try? JSONSerialization.data(
                withJSONObject: array,
                options: [.sortedKeys]
            ),
            String(data: canonical, encoding: .utf8) == value
        else {
            throw StateStoreError.invalidRecord(
                "Certificate JSON must be bounded canonical arrays."
            )
        }
    }
    private static func legal(_ x: CertificateStateRecord) -> Bool {
        switch x.lifecycleState {
        case .creating: return x.finalizerState == .pending && x.status == .creating && x.observedSHA256 == nil
        case .available: return x.finalizerState == .active && x.status == .available && x.observedSHA256 != nil
        case .deleting:
            return x.finalizerState == .releasing
                && (x.ownershipKind == .external ? x.status == .available : x.status == .revoking)
        case .deleted:
            return x.finalizerState == .released
                && (x.ownershipKind == .external ? x.status == .released : x.status == .revoked)
        case .faulted: return [.active, .releasing, .quarantined].contains(x.finalizerState) && x.status == .faulted
        }
    }
    private static func transition(_ a: NetworkStateResourceLifecycle, _ b: NetworkStateResourceLifecycle) -> Bool {
        switch a {
        case .creating: return [.available, .deleting, .faulted].contains(b)
        case .available: return [.available, .deleting, .faulted].contains(b)
        case .deleting: return [.deleted, .faulted].contains(b)
        case .faulted: return [.available, .deleting, .faulted].contains(b)
        case .deleted: return false
        }
    }
    private static func validate(_ a: NetworkStateMutationAuthority) throws {
        guard a.plannedCapabilitySHA256 == a.currentCapabilitySHA256,
            HostwrightResourceUUID.isValid(a.operationGroupID), HostwrightResourceUUID.isValid(a.fencingToken)
        else { throw StateStoreError.invalidRecord("Certificate authority is stale or malformed.") }
    }
    private static func validateBinding(
        _ x: CertificateStateRecord,
        authority a: NetworkStateMutationAuthority,
        on c: SQLiteConnection
    ) throws {
        let rows = try c.query(
            "SELECT p.mutation_provider,p.provider_generation,o.fencing_token,o.intent_json_redacted FROM projects p JOIN operation_groups o ON o.project_id=p.id WHERE p.resource_uuid=? AND o.id=? AND o.status='active'",
            bindings: [.text(x.projectUUID), .text(a.operationGroupID)]
        )
        guard let r = rows.first, r.count == 4,
            RuntimeProviderBinding.stableID(for: r[0] ?? "")?.rawValue == x.providerID,
            Int64(r[1] ?? "") == x.providerGeneration, r[2] == x.fencingToken, let j = r[3],
            let d = j.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            o["capabilitySHA256"] as? String == a.plannedCapabilitySHA256
        else {
            throw StateStoreError.invalidRecord(
                "Certificate requires exact active project provider and operation fence."
            )
        }
    }
    private static func validateStoredBinding(
        _ record: CertificateStateRecord,
        on connection: SQLiteConnection
    ) throws {
        let rows = try connection.query(
            """
            SELECT p.mutation_provider, p.provider_generation, o.fencing_token
            FROM projects p
            JOIN operation_groups o ON o.project_id = p.id
            WHERE p.resource_uuid = ? AND o.id = ?
            """,
            bindings: [.text(record.projectUUID), .text(record.operationGroupID)]
        )
        guard let row = rows.first,
            row.count == 3,
            RuntimeProviderBinding.stableID(for: row[0] ?? "")?.rawValue == record.providerID,
            Int64(row[1] ?? "") == record.providerGeneration,
            row[2] == record.fencingToken
        else {
            throw StateStoreError.invalidRecord(
                "Certificate stored provider and operation ownership is inconsistent."
            )
        }
    }
}
extension SQLiteStateStore {
    public var certificates: CertificateStateRepository { CertificateStateRepository(store: self) }
}
