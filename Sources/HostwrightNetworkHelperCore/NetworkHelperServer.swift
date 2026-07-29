import Darwin
import Foundation
import HostwrightNetworking
import HostwrightRuntime

struct NetworkHelperDispatcher: @unchecked Sendable {
    let store: NetworkHelperStateStore
    let hostAccessBroker: NetworkHelperHostAccessBroker
    let ingressBroker: NetworkHelperIngressBroker
    let certificateCoordinator: NetworkHelperCertificateCoordinator
    let policyBroker: NetworkHelperPolicyBroker

    init(
        store: NetworkHelperStateStore,
        hostAccessBroker: NetworkHelperHostAccessBroker =
            NetworkHelperHostAccessBroker(),
        ingressBroker: NetworkHelperIngressBroker =
            NetworkHelperIngressBroker(),
        certificateCoordinator: NetworkHelperCertificateCoordinator =
            NetworkHelperCertificateCoordinator(),
        policyBroker: NetworkHelperPolicyBroker = NetworkHelperPolicyBroker()
    ) {
        self.store = store
        self.hostAccessBroker = hostAccessBroker
        self.ingressBroker = ingressBroker
        self.certificateCoordinator = certificateCoordinator
        self.policyBroker = policyBroker
    }

    var hasActiveBindings: Bool {
        hostAccessBroker.hasActiveBindings ||
            ingressBroker.hasActiveBindings ||
            certificateCoordinator.hasActiveCertificates ||
            policyBroker.hasActivePolicies
    }

    func dispatch(frame: Data) throws -> Data {
        let request = try NetworkHelperCanonicalJSON.decodeFrame(
            NetworkHelperRequest.self,
            from: frame
        )
        do {
            _ = try request.validated()
            let status: NetworkHelperStatus
            switch request.operation {
            case .apply:
                let persisted = try store.apply(
                    identity: request.identity,
                    corefile: request.corefile!,
                    hostAccessBindings:
                        request.hostAccessBindings ?? [],
                    ingressBindings:
                        request.ingressBindings ?? [],
                    certificateBindings:
                        request.certificateBindings ?? [],
                    policyPlan: request.policyPlan,
                    predecessorFencingToken:
                        request.predecessorFencingToken
                )
                status = try activatingStatus(
                    persisted,
                    identity: request.identity,
                    hostAccessBindings:
                        request.hostAccessBindings ?? [],
                    ingressBindings:
                        request.ingressBindings ?? [],
                    certificateBindings:
                        request.certificateBindings ?? [],
                    policyPlan: request.policyPlan
                )
            case .status:
                let persisted = try store.status(
                    identity: request.identity
                )
                if persisted.disposition == .active {
                    let hostAccessBindings = try store
                        .activeHostAccessConfigurations()
                        .first(where: {
                            $0.identity == request.identity
                        })?.bindings ?? []
                    let ingressBindings = try store
                        .activeIngressConfigurations()
                        .first(where: {
                            $0.identity == request.identity
                        })?.bindings ?? []
                    let certificateBindings = try store
                        .activeCertificateConfigurations()
                        .first(where: {
                            $0.identity == request.identity
                        })?.bindings ?? []
                    let policyPlan = try store
                        .activePolicyConfigurations()
                        .first(where: {
                            $0.identity == request.identity
                        })?.plan
                    status = try activatingStatus(
                        persisted,
                        identity: request.identity,
                        hostAccessBindings: hostAccessBindings,
                        ingressBindings: ingressBindings,
                        certificateBindings: certificateBindings,
                        policyPlan: policyPlan
                    )
                } else {
                    status = withActivity(
                        persisted,
                        hostAccessActive: false,
                        ingressActive: false,
                        certificateActive: false,
                        policyActive: false
                    )
                }
            case .remove:
                let persisted = try store.status(
                    identity: request.identity
                )
                guard persisted.disposition == .active else {
                    if persisted.disposition == .quarantined {
                        throw NetworkHelperError.quarantined
                    }
                    throw NetworkHelperError.conflict
                }
                let evidence = try store.certificateEvidence(
                    identity: request.identity
                )
                let retired = try store.retiredCertificateEvidence(
                    identity: request.identity
                )
                let certificateBindings = try store
                    .activeCertificateConfigurations()
                    .first(where: {
                        $0.identity == request.identity
                    })?.bindings ?? []
                ingressBroker.remove(identity: request.identity)
                policyBroker.remove(identity: request.identity)
                if let evidence {
                    try certificateCoordinator.cleanup(
                        identity: request.identity,
                        evidence: evidence
                    )
                } else {
                    try certificateCoordinator
                        .cleanupUnrecordedManagedIdentities(
                            identity: request.identity,
                            bindings: certificateBindings
                        )
                }
                if let retired {
                    try certificateCoordinator.cleanup(
                        identity: retired.identity,
                        evidence: retired
                    )
                    try store.clearRetiredCertificateEvidence(
                        identity: request.identity,
                        expected: retired
                    )
                }
                let removed = try store.remove(
                    identity: request.identity
                )
                hostAccessBroker.remove(identity: request.identity)
                status = withActivity(
                    removed,
                    hostAccessActive: false,
                    ingressActive: false,
                    certificateActive: false,
                    policyActive: false
                )
            }
            return try NetworkHelperCanonicalJSON.frame(
                NetworkHelperResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    status: status
                )
            )
        } catch let error as NetworkHelperError {
            return try NetworkHelperCanonicalJSON.frame(
                NetworkHelperResponse(
                    requestID: request.requestID,
                    operation: request.operation,
                    error: error.failure
                )
            )
        }
    }

    private func activatingStatus(
        _ persisted: NetworkHelperStatus,
        identity: NetworkHelperDNSIdentity,
        hostAccessBindings: [ProjectDNSHostAccessBinding],
        ingressBindings: [ProjectIngressListenerBinding],
        certificateBindings: [ProjectCertificateRequestBinding],
        policyPlan: NetworkPolicyPlan?
    ) throws -> NetworkHelperStatus {
        guard persisted.disposition == .active else {
            return withActivity(
                persisted,
                hostAccessActive: false,
                ingressActive: false,
                certificateActive: false,
                policyActive: false
            )
        }
        let hostAccessActive: Bool
        if let expected = persisted.hostAccessSHA256 {
            if hostAccessBroker.sha256(identity: identity) == expected {
                hostAccessActive = true
            } else {
                do {
                    hostAccessActive = try hostAccessBroker.apply(
                        identity: identity,
                        bindings: hostAccessBindings
                    ) == expected
                } catch NetworkHelperError.bindingUnavailable {
                    hostAccessActive = false
                }
            }
        } else {
            hostAccessBroker.remove(identity: identity)
            hostAccessActive = true
        }
        let certificateActive: Bool
        let activation: NetworkHelperCertificateActivation
        if let expected = persisted.certificateSHA256 {
            let priorEvidence = try store.certificateEvidence(
                identity: identity
            )
            activation = try certificateCoordinator.apply(
                identity: identity,
                bindings: certificateBindings,
                persistedEvidence: priorEvidence,
                overlapEvidence:
                    try store.retiredCertificateEvidence(
                        identity: identity
                    )
            )
            let recorded = try store.recordCertificateEvidence(
                identity: identity,
                certificates: activation.evidence
            )
            certificateActive =
                recorded?.requestSHA256 == expected &&
                activation.identities.count ==
                    certificateBindings.count
        } else {
            certificateCoordinator.deactivate(identity: identity)
            _ = try store.recordCertificateEvidence(
                identity: identity,
                certificates: []
            )
            activation = NetworkHelperCertificateActivation(
                identities: [:],
                peerIdentities: [:],
                mutualTLSPolicies: [:],
                currentMutualTLSPolicies: [:],
                evidence: [],
                evidenceSHA256: nil
            )
            certificateActive = true
        }
        let policyActive: Bool
        if let expected = persisted.policySHA256 {
            guard let policyPlan else {
                policyBroker.remove(identity: identity)
                ingressBroker.remove(identity: identity)
                return withActivity(
                    persisted,
                    hostAccessActive: hostAccessActive,
                    ingressActive: false,
                    certificateActive: certificateActive,
                    policyActive: false,
                    certificateActivation: activation,
                    certificateBindings: certificateBindings
                )
            }
            do {
                policyActive = try policyBroker.apply(
                    identity: identity,
                    plan: policyPlan
                ) == expected
            } catch {
                policyBroker.remove(identity: identity)
                ingressBroker.remove(identity: identity)
                return withActivity(
                    persisted,
                    hostAccessActive: hostAccessActive,
                    ingressActive: false,
                    certificateActive: certificateActive,
                    policyActive: false,
                    certificateActivation: activation,
                    certificateBindings: certificateBindings
                )
            }
        } else {
            policyBroker.remove(identity: identity)
            policyActive = true
        }
        let policyDigest = policyActive ? persisted.policySHA256 : nil
        let policyAuthorizer =
            policyDigest.map {
                makePolicyAuthorizer(
                    identity: identity,
                    expectedSHA256: $0
                )
            }
        let ingressActive: Bool
        if let expected = persisted.ingressSHA256 {
            if ingressBroker.sha256(identity: identity) == expected,
               certificateBindings.isEmpty,
               policyDigest == nil {
                ingressActive = true
            } else {
                do {
                    ingressActive = try ingressBroker.apply(
                        identity: identity,
                        bindings: ingressBindings,
                        certificateIdentities:
                            activation.identities,
                        policySHA256: policyDigest,
                        policyAuthorizer: policyAuthorizer,
                        mutualTLSPolicies:
                            activation.mutualTLSPolicies
                    ) == expected
                } catch NetworkHelperError.bindingUnavailable {
                    ingressActive = false
                }
            }
        } else {
            ingressBroker.remove(identity: identity)
            ingressActive = true
        }
        if ingressActive,
           let retired = try store.retiredCertificateEvidence(
                identity: identity
            ) {
            if !ingressBindings.isEmpty {
                guard try ingressBroker.apply(
                    identity: identity,
                    bindings: ingressBindings,
                    certificateIdentities:
                        activation.identities,
                    policySHA256: policyDigest,
                    policyAuthorizer: policyAuthorizer,
                    mutualTLSPolicies:
                        activation.currentMutualTLSPolicies
                ) == persisted.ingressSHA256 else {
                    throw NetworkHelperError.bindingUnavailable
                }
            }
            try certificateCoordinator.cleanup(
                identity: retired.identity,
                evidence: retired
            )
            try store.clearRetiredCertificateEvidence(
                identity: identity,
                expected: retired
            )
        }
        return withActivity(
            persisted,
            hostAccessActive: hostAccessActive,
            ingressActive: ingressActive,
            certificateActive: certificateActive,
            policyActive: policyActive,
            certificateActivation: activation,
            certificateBindings: certificateBindings
        )
    }

    private func makePolicyAuthorizer(
        identity: NetworkHelperDNSIdentity,
        expectedSHA256: String
    ) -> @Sendable (NetworkPolicyFlow) -> Bool {
        { [policyBroker] flow in
            policyBroker.allows(
                identity: identity,
                expectedSHA256: expectedSHA256,
                flow: flow
            )
        }
    }

    private func withActivity(
        _ status: NetworkHelperStatus,
        hostAccessActive: Bool,
        ingressActive: Bool,
        certificateActive: Bool,
        policyActive: Bool,
        certificateActivation:
            NetworkHelperCertificateActivation? = nil,
        certificateBindings:
            [ProjectCertificateRequestBinding] = []
    ) -> NetworkHelperStatus {
        NetworkHelperStatus(
            disposition: status.disposition,
            identity: status.identity,
            corefileSHA256: status.corefileSHA256,
            hostAccessSHA256: status.hostAccessSHA256,
            hostAccessActive: hostAccessActive,
            ingressSHA256: status.ingressSHA256,
            ingressActive: ingressActive,
            ingressAccessLog: status.identity.map {
                ingressBroker.accessLog(identity: $0)
            },
            mutualTLSAudit: status.identity.map {
                ingressBroker.mutualTLSAudit(identity: $0)
            },
            certificateSHA256: status.certificateSHA256,
            certificateActive: certificateActive,
            certificateEvidenceSHA256:
                certificateActivation?.evidenceSHA256,
            certificateSummaries: certificateSummaries(
                activation: certificateActivation,
                bindings: certificateBindings
            ),
            policySHA256: status.policySHA256,
            policyActive: policyActive,
            reason: status.reason
        )
    }

    private func certificateSummaries(
        activation: NetworkHelperCertificateActivation?,
        bindings: [ProjectCertificateRequestBinding]
    ) -> [NetworkHelperCertificateSummary]? {
        guard let activation, !activation.evidence.isEmpty else {
            return nil
        }
        let bindingsByName = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.name, $0) }
        )
        let currentTime = Date()
        return activation.evidence.map { evidence in
            let renewalNeeded = bindingsByName[evidence.name].map {
                evidence.notValidAfter.timeIntervalSince(currentTime)
                    <= TimeInterval($0.renewBeforeSeconds)
            } ?? true
            return NetworkHelperCertificateSummary(
                name: evidence.name,
                certificateUUID: evidence.certificateUUID,
                source: evidence.source,
                certificateSHA256: evidence.certificateSHA256,
                issuerCertificateSHA256:
                    evidence.issuerCertificateSHA256,
                dnsNames: evidence.dnsNames,
                notValidBefore: evidence.notValidBefore,
                notValidAfter: evidence.notValidAfter,
                revocationStatus: evidence.revocationStatus,
                renewalNeeded: renewalNeeded
            )
        }
    }
}

enum NetworkHelperConnectionHandler {
    static func handle(
        descriptor: Int32,
        dispatcher: NetworkHelperDispatcher,
        timeoutMilliseconds: Int64 = 5_000
    ) throws {
        precondition(timeoutMilliseconds > 0)
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        let header = try readExact(
            descriptor: descriptor,
            byteCount: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadlineMilliseconds: deadline
        )
        let payloadLength = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard payloadLength > 0,
              payloadLength <= UInt32(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.invalidFrame
        }
        let payload = try readExact(
            descriptor: descriptor,
            byteCount: Int(payloadLength),
            deadlineMilliseconds: deadline
        )
        let response = try dispatcher.dispatch(frame: header + payload)
        try writeAll(
            descriptor: descriptor,
            data: response,
            deadlineMilliseconds: deadline
        )
    }

    static func readFrame(
        descriptor: Int32,
        timeoutMilliseconds: Int64 = 5_000
    ) throws -> Data {
        let deadline = monotonicMilliseconds() + timeoutMilliseconds
        let header = try readExact(
            descriptor: descriptor,
            byteCount: ContainerizationHelperProtocolV1.frameHeaderBytes,
            deadlineMilliseconds: deadline
        )
        let payloadLength = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard payloadLength > 0,
              payloadLength <= UInt32(
                NetworkHelperProtocolV1.maximumFrameBytes
              ) else {
            throw NetworkHelperError.invalidFrame
        }
        return header + (try readExact(
            descriptor: descriptor,
            byteCount: Int(payloadLength),
            deadlineMilliseconds: deadline
        ))
    }

    private static func readExact(
        descriptor: Int32,
        byteCount: Int,
        deadlineMilliseconds: Int64
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(byteCount)
        var buffer = [UInt8](
            repeating: 0,
            count: min(max(byteCount, 1), 64 * 1_024)
        )
        while result.count < byteCount {
            guard monotonicMilliseconds() < deadlineMilliseconds else {
                throw NetworkHelperError.ioFailure
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            guard ready > 0 else { continue }
            let requested = min(buffer.count, byteCount - result.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR || errno == EAGAIN
                || errno == EWOULDBLOCK {
                continue
            }
            guard count > 0 else {
                throw NetworkHelperError.invalidFrame
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private static func writeAll(
        descriptor: Int32,
        data: Data,
        deadlineMilliseconds: Int64
    ) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard monotonicMilliseconds() < deadlineMilliseconds else {
                    throw NetworkHelperError.ioFailure
                }
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let ready = Darwin.poll(&pollDescriptor, 1, 100)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else {
                    throw NetworkHelperError.ioFailure
                }
                guard ready > 0 else { continue }
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR || errno == EAGAIN
                    || errno == EWOULDBLOCK {
                    continue
                }
                guard count > 0 else {
                    throw NetworkHelperError.ioFailure
                }
                offset += count
            }
        }
    }

    private static func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}

struct NetworkHelperUnixServer: Sendable {
    let runtimeDirectory: ContainerizationHelperRuntimeDirectory
    let dispatcher: NetworkHelperDispatcher
    let authenticator: NetworkHelperPeerAuthenticator
    let idleTimeoutMilliseconds: Int64

    init(
        runtimeDirectory: ContainerizationHelperRuntimeDirectory,
        dispatcher: NetworkHelperDispatcher,
        authenticator: NetworkHelperPeerAuthenticator,
        idleTimeoutMilliseconds: Int64 = 30_000
    ) {
        precondition(idleTimeoutMilliseconds > 0)
        self.runtimeDirectory = runtimeDirectory
        self.dispatcher = dispatcher
        self.authenticator = authenticator
        self.idleTimeoutMilliseconds = idleTimeoutMilliseconds
    }

    func run() throws {
        let lease = try runtimeDirectory.makeListeningSocket()
        defer { try? lease.closeAndRemove() }
        var lastActivity = monotonicMilliseconds()

        while dispatcher.hasActiveBindings
            || monotonicMilliseconds() - lastActivity
                < idleTimeoutMilliseconds {
            var pollDescriptor = pollfd(
                fd: lease.descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let ready = Darwin.poll(&pollDescriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            guard ready > 0,
                  pollDescriptor.revents & Int16(POLLIN) != 0 else {
                continue
            }

            let connection = Darwin.accept(lease.descriptor, nil, nil)
            if connection < 0, errno == EINTR || errno == EAGAIN {
                continue
            }
            guard connection >= 0 else {
                throw NetworkHelperError.ioFailure
            }
            defer { Darwin.close(connection) }

            let flags = fcntl(connection, F_GETFL)
            guard flags >= 0,
                  fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(connection, F_SETFL, flags | O_NONBLOCK) == 0 else {
                continue
            }
            do {
                try authenticator.validate(
                    connectionDescriptor: connection
                )
                try NetworkHelperConnectionHandler.handle(
                    descriptor: connection,
                    dispatcher: dispatcher
                )
                lastActivity = monotonicMilliseconds()
            } catch {
                continue
            }
        }
    }

    private func monotonicMilliseconds() -> Int64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Int64(time.tv_sec) * 1_000
            + Int64(time.tv_nsec) / 1_000_000
    }
}
