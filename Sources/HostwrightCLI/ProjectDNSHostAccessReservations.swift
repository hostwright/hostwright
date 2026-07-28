import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import HostwrightState

struct ProjectDNSHostAccessReservationBatch: Sendable {
    let desired: [NetworkPortReservationRecord]
    let stale: [NetworkPortReservationRecord]
}

enum ProjectDNSHostAccessReservations {
    static func prepare(
        bindings: [ProjectDNSHostAccessBinding],
        dnsUUID: String,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws -> ProjectDNSHostAccessReservationBatch {
        let managed = try managedRecords(
            dnsUUID: dnsUUID,
            preparation: preparation,
            store: store
        )
        let live = managed.filter {
            $0.lifecycleState != .released
        }
        let desiredBindings = bindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
        let desiredEndpoints = Set(
            desiredBindings.map(endpointKey)
        )
        var desiredRecords: [NetworkPortReservationRecord] = []
        let now = hostwrightTimestamp()

        for binding in desiredBindings {
            let matches = live.filter {
                endpointKey($0) == endpointKey(binding)
            }
            guard matches.count <= 1 else {
                throw conflict(
                    "Guarded host access found ambiguous durable ownership for one listener."
                )
            }
            let desiredSHA256 = try digest(
                HostAccessReservationIntent(
                    projectUUID:
                        preparation.projectResourceUUID,
                    dnsUUID: dnsUUID,
                    providerID:
                        preparation.providerID.rawValue,
                    providerGeneration:
                        preparation.providerGeneration,
                    binding: binding
                )
            )
            if let existing = matches.first {
                try requireReusable(
                    existing,
                    binding: binding,
                    dnsUUID: dnsUUID,
                    currentGroupID: group.id,
                    preparation: preparation,
                    store: store
                )
                if existing.operationGroupID == group.id,
                   existing.fencingToken ==
                    group.fencingToken {
                    guard existing.desiredSHA256 ==
                            desiredSHA256 else {
                        throw conflict(
                            "Guarded host access operation identity was reused with different desired state."
                        )
                    }
                    desiredRecords.append(existing)
                    continue
                }
                let renewed = replacing(
                    existing,
                    generation: existing.generation + 1,
                    providerGeneration:
                        Int64(preparation.providerGeneration),
                    fencingToken: group.fencingToken,
                    desiredSHA256: desiredSHA256,
                    observedSHA256: nil,
                    lifecycleState: .reserved,
                    finalizerState: .active,
                    operationGroupID: group.id
                )
                desiredRecords.append(
                    try store.networkPorts.save(
                        renewed,
                        replacing: existing.expectedVersion
                    )
                )
                continue
            }

            let record = NetworkPortReservationRecord(
                id: HostwrightResourceUUID.legacy(
                    kind: "project-dns-host-access",
                    identifier: [
                        group.id,
                        endpointKey(binding),
                    ].joined(separator: ":")
                ),
                projectUUID:
                    preparation.projectResourceUUID,
                resourceUUID: dnsUUID,
                serviceName: serviceName(binding),
                generation: 1,
                providerID:
                    preparation.providerID.rawValue,
                providerGeneration:
                    Int64(preparation.providerGeneration),
                fencingToken: group.fencingToken,
                bindAddress: binding.listenAddress,
                hostPort: binding.port,
                containerPort: binding.port,
                protocolName:
                    reservationProtocol(
                        binding.protocolName
                    ),
                allocationKind: .fixed,
                desiredSHA256: desiredSHA256,
                observedSHA256: nil,
                lifecycleState: .reserved,
                finalizerState: .active,
                operationGroupID: group.id,
                createdAt: now,
                updatedAt: now
            )
            desiredRecords.append(
                try store.networkPorts.save(record)
            )
        }

        return ProjectDNSHostAccessReservationBatch(
            desired: desiredRecords.sorted(by: recordPrecedes),
            stale: live.filter {
                !desiredEndpoints.contains(endpointKey($0))
            }.sorted(by: recordPrecedes)
        )
    }

    static func commit(
        _ batch: ProjectDNSHostAccessReservationBatch,
        helperSHA256: String?,
        group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        if batch.desired.isEmpty {
            guard helperSHA256 == nil else {
                throw conflict(
                    "Guarded host access returned unexpected helper evidence for an empty plan."
                )
            }
        } else {
            guard let helperSHA256,
                  isSHA256(helperSHA256) else {
                throw conflict(
                    "Guarded host access omitted exact helper evidence."
                )
            }
        }
        for record in batch.desired {
            guard let current = try store.networkPorts.load(
                id: record.id
            ),
            current.operationGroupID == group.id,
            current.fencingToken == group.fencingToken else {
                throw conflict(
                    "Guarded host access lost its exact durable reservation before activation."
                )
            }
            if current.lifecycleState == .active {
                guard current.observedSHA256 ==
                        helperSHA256 else {
                    throw conflict(
                        "Guarded host access found conflicting active reservation evidence."
                    )
                }
                continue
            }
            guard current.lifecycleState == .reserved else {
                throw conflict(
                    "Guarded host access found a non-activatable reservation."
                )
            }
            _ = try store.networkPorts.save(
                replacing(
                    current,
                    generation: current.generation,
                    providerGeneration:
                        current.providerGeneration,
                    fencingToken: current.fencingToken,
                    desiredSHA256:
                        current.desiredSHA256,
                    observedSHA256: helperSHA256,
                    lifecycleState: .active,
                    finalizerState: .active,
                    operationGroupID: current.operationGroupID
                ),
                replacing: current.expectedVersion
            )
        }
        try release(
            batch.stale,
            group: group,
            store: store
        )
    }

    static func releaseAll(
        dnsUUID: String,
        group: OperationGroupRecord,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws {
        try release(
            try managedRecords(
                dnsUUID: dnsUUID,
                preparation: preparation,
                store: store
            ).filter {
                $0.lifecycleState != .released
            },
            group: group,
            store: store
        )
    }

    static func requireActive(
        bindings: [ProjectDNSHostAccessBinding],
        helperSHA256: String?,
        dnsUUID: String,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws {
        let live = try managedRecords(
            dnsUUID: dnsUUID,
            preparation: preparation,
            store: store
        ).filter {
            $0.lifecycleState != .released
        }
        let desired = bindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
        guard live.count == desired.count else {
            throw conflict(
                "Guarded host access durable reservations do not match the active helper plan."
            )
        }
        if desired.isEmpty {
            guard helperSHA256 == nil else {
                throw conflict(
                    "Guarded host access returned helper evidence without durable listeners."
                )
            }
            return
        }
        guard let helperSHA256,
              isSHA256(helperSHA256) else {
            throw conflict(
                "Guarded host access active listeners lack exact helper evidence."
            )
        }
        for binding in desired {
            let matches = live.filter {
                endpointKey($0) == endpointKey(binding)
            }
            guard matches.count == 1,
                  let record = matches.first,
                  record.lifecycleState == .active,
                  record.finalizerState == .active,
                  record.desiredSHA256 == (try? digest(
                      HostAccessReservationIntent(
                          projectUUID:
                            preparation.projectResourceUUID,
                          dnsUUID: dnsUUID,
                          providerID:
                            preparation.providerID.rawValue,
                          providerGeneration:
                            preparation.providerGeneration,
                          binding: binding
                      )
                  )),
                  record.observedSHA256 ==
                    helperSHA256 else {
                throw conflict(
                    "Guarded host access active reservation evidence is stale or conflicting."
                )
            }
        }
    }

    private static func release(
        _ records: [NetworkPortReservationRecord],
        group: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws {
        for record in records.sorted(by: recordPrecedes) {
            guard let current = try store.networkPorts.load(
                id: record.id
            ),
            current.lifecycleState != .released else {
                continue
            }
            let releasing: NetworkPortReservationRecord
            if current.lifecycleState == .releasing,
               current.operationGroupID == group.id,
               current.fencingToken == group.fencingToken {
                releasing = current
            } else {
                releasing = try store.networkPorts.save(
                    replacing(
                        current,
                        generation:
                            current.generation + 1,
                        providerGeneration:
                            current.providerGeneration,
                        fencingToken: group.fencingToken,
                        desiredSHA256:
                            current.desiredSHA256,
                        observedSHA256:
                            current.observedSHA256,
                        lifecycleState: .releasing,
                        finalizerState: .releasing,
                        operationGroupID: group.id
                    ),
                    replacing: current.expectedVersion
                )
            }
            _ = try store.networkPorts.save(
                replacing(
                    releasing,
                    generation: releasing.generation,
                    providerGeneration:
                        releasing.providerGeneration,
                    fencingToken: releasing.fencingToken,
                    desiredSHA256:
                        releasing.desiredSHA256,
                    observedSHA256: try digest(
                        "released:\(releasing.id):\(group.fencingToken)"
                    ),
                    lifecycleState: .released,
                    finalizerState: .released,
                    operationGroupID: group.id
                ),
                replacing: releasing.expectedVersion
            )
        }
    }

    private static func managedRecords(
        dnsUUID: String,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws -> [NetworkPortReservationRecord] {
        let candidates = try store.networkPorts.loadProject(
            projectUUID: preparation.projectResourceUUID,
            includeReleased: true
        ).filter {
            $0.resourceUUID == dnsUUID
        }
        guard candidates.allSatisfy({
            $0.serviceName.hasPrefix("host-access:") &&
                $0.providerID ==
                    preparation.providerID.rawValue &&
                $0.providerGeneration ==
                    Int64(preparation.providerGeneration)
        }) else {
            throw conflict(
                "Guarded host access found conflicting reservation ownership."
            )
        }
        return candidates
    }

    private static func requireReusable(
        _ record: NetworkPortReservationRecord,
        binding: ProjectDNSHostAccessBinding,
        dnsUUID: String,
        currentGroupID: String,
        preparation: LifecycleCommandPreparation,
        store: SQLiteStateStore
    ) throws {
        guard record.resourceUUID == dnsUUID,
              record.projectUUID ==
                preparation.projectResourceUUID,
              record.providerID ==
                preparation.providerID.rawValue,
              record.providerGeneration ==
                Int64(preparation.providerGeneration),
              record.serviceName == serviceName(binding),
              [.reserved, .active].contains(
                  record.lifecycleState
              ) else {
            throw conflict(
                "Guarded host access refused a stale or non-reusable reservation."
            )
        }
        if record.operationGroupID != "",
           record.operationGroupID != currentGroupID,
           let prior = try store.operationGroups.load(
               id: record.operationGroupID
           ),
           prior.status == .active {
            throw conflict(
                "Guarded host access refused to steal a reservation from an active operation."
            )
        }
    }

    private static func replacing(
        _ record: NetworkPortReservationRecord,
        generation: Int64,
        providerGeneration: Int64,
        fencingToken: String,
        desiredSHA256: String,
        observedSHA256: String?,
        lifecycleState: NetworkPortReservationLifecycle,
        finalizerState: NetworkStateFinalizer,
        operationGroupID: String
    ) -> NetworkPortReservationRecord {
        NetworkPortReservationRecord(
            id: record.id,
            projectUUID: record.projectUUID,
            resourceUUID: record.resourceUUID,
            serviceName: record.serviceName,
            generation: generation,
            providerID: record.providerID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken,
            bindAddress: record.bindAddress,
            hostPort: record.hostPort,
            containerPort: record.containerPort,
            protocolName: record.protocolName,
            allocationKind: record.allocationKind,
            desiredSHA256: desiredSHA256,
            observedSHA256: observedSHA256,
            lifecycleState: lifecycleState,
            finalizerState: finalizerState,
            operationGroupID: operationGroupID,
            createdAt: record.createdAt,
            updatedAt: hostwrightTimestamp()
        )
    }

    private static func endpointKey(
        _ binding: ProjectDNSHostAccessBinding
    ) -> String {
        [
            binding.listenAddress,
            String(binding.port),
            binding.protocolName.rawValue,
        ].joined(separator: "\u{1f}")
    }

    private static func endpointKey(
        _ record: NetworkPortReservationRecord
    ) -> String {
        [
            record.bindAddress,
            String(record.hostPort),
            record.protocolName.rawValue,
        ].joined(separator: "\u{1f}")
    }

    private static func serviceName(
        _ binding: ProjectDNSHostAccessBinding
    ) -> String {
        "host-access:\(binding.listenAddress):\(binding.port)/\(binding.protocolName.rawValue)"
    }

    private static func reservationProtocol(
        _ value: HostwrightHostAccessProtocol
    ) -> NetworkPortReservationProtocol {
        switch value {
        case .tcp: return .tcp
        case .udp: return .udp
        }
    }

    private static func recordPrecedes(
        _ lhs: NetworkPortReservationRecord,
        _ rhs: NetworkPortReservationRecord
    ) -> Bool {
        endpointKey(lhs) < endpointKey(rhs)
    }

    private static func digest<T: Encodable>(
        _ value: T
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digest(
        _ value: String
    ) throws -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSHA256(
        _ value: String
    ) -> Bool {
        value.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil
    }

    private static func conflict(
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .runtimeUnavailable,
            message: message
        )
    }
}

private struct HostAccessReservationIntent:
    Codable,
    Sendable
{
    let schemaVersion: Int
    let projectUUID: String
    let dnsUUID: String
    let providerID: String
    let providerGeneration: Int
    let binding: ProjectDNSHostAccessBinding

    init(
        projectUUID: String,
        dnsUUID: String,
        providerID: String,
        providerGeneration: Int,
        binding: ProjectDNSHostAccessBinding
    ) {
        schemaVersion = 1
        self.projectUUID = projectUUID
        self.dnsUUID = dnsUUID
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.binding = binding
    }
}
