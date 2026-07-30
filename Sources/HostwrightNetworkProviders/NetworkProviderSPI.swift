import CryptoKit
import Foundation

public enum NetworkProviderKind: String, Codable, CaseIterable, Sendable {
    case certificateIssuer
    case tunnelProvider
}

public enum NetworkProviderOperation: String, Codable, CaseIterable, Sendable {
    case setup
    case status
    case routes
    case identity
    case renewal
    case reconnect
    case drain
    case teardown
}

public struct NetworkProviderDeclaration: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let identifier: String
    public let kind: NetworkProviderKind
    public let moduleSHA256: String
    public let signer: String

    public init(
        apiVersion: Int = 1,
        identifier: String,
        kind: NetworkProviderKind,
        moduleSHA256: String,
        signer: String
    ) {
        self.apiVersion = apiVersion
        self.identifier = identifier
        self.kind = kind
        self.moduleSHA256 = moduleSHA256
        self.signer = signer
    }
}

public struct NetworkProviderGrant: Codable, Equatable, Sendable {
    public let identifier: String
    public let kind: NetworkProviderKind
    public let allowedHTTPSOrigins: Set<String>
    public let secretReferences: Set<String>
    public let identityScopes: Set<String>
    public let routeScopes: Set<String>
    public let approvedBy: String
    public let expiresAt: Date

    public init(
        identifier: String,
        kind: NetworkProviderKind,
        allowedHTTPSOrigins: Set<String>,
        secretReferences: Set<String> = [],
        identityScopes: Set<String> = [],
        routeScopes: Set<String> = [],
        approvedBy: String,
        expiresAt: Date
    ) {
        self.identifier = identifier
        self.kind = kind
        self.allowedHTTPSOrigins = allowedHTTPSOrigins
        self.secretReferences = secretReferences
        self.identityScopes = identityScopes
        self.routeScopes = routeScopes
        self.approvedBy = approvedBy
        self.expiresAt = expiresAt
    }
}

public struct NetworkProviderSandbox: Equatable, Sendable {
    public static let maximumMemoryBytes = 64 * 1_024 * 1_024
    public static let maximumOutputBytes = 1 * 1_024 * 1_024
    public static let normalTimeoutMilliseconds = 5_000
    public static let longTimeoutMilliseconds = 30_000

    public let memoryLimitBytes: Int
    public let outputLimitBytes: Int
    public let timeoutMilliseconds: Int
    public let preopenedFilesystem = false
    public let inheritedEnvironment = false
    public let directSockets = false
    public let runtimeAccess = false
    public let sqliteAccess = false
    public let keychainAccess = false

    public init(longRunning: Bool = false) {
        memoryLimitBytes = Self.maximumMemoryBytes
        outputLimitBytes = Self.maximumOutputBytes
        timeoutMilliseconds = longRunning
            ? Self.longTimeoutMilliseconds
            : Self.normalTimeoutMilliseconds
    }

    init(
        memoryLimitBytes: Int,
        outputLimitBytes: Int,
        timeoutMilliseconds: Int
    ) {
        self.memoryLimitBytes = memoryLimitBytes
        self.outputLimitBytes = outputLimitBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public protocol DetachedCMSVerifier: Sendable {
    func verifyDetachedCMS(
        signature: Data,
        content: Data,
        trustedSigner: String
    ) throws
}

public protocol NetworkProviderWasmExecutor: Sendable {
    func execute(
        module: Data,
        stdin: Data,
        sandbox: NetworkProviderSandbox
    ) async throws -> Data
}

public protocol NetworkProviderRevocationStore: Sendable {
    func isRevoked(identifier: String, moduleSHA256: String) async throws -> Bool

    /// The implementation must durably persist the revocation before returning.
    func revoke(identifier: String, moduleSHA256: String, at: Date) async throws
}

public struct NetworkProviderSecretHandle: Equatable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public protocol NetworkProviderBroker: Sendable {
    func https(origin: String, request: Data) async throws -> Data
    func secretReference(_ reference: String) async throws -> NetworkProviderSecretHandle
    func identity(scope: String, request: Data) async throws -> Data
    func route(scope: String, request: Data) async throws -> Data
}

public enum NetworkProviderBrokerRequestKind: String, Codable, Sendable {
    case https
    case secretReference
    case identity
    case route
}

public struct NetworkProviderBrokerRequest: Codable, Equatable, Sendable {
    public let kind: NetworkProviderBrokerRequestKind
    public let scope: String
    public let request: Data

    public init(
        kind: NetworkProviderBrokerRequestKind,
        scope: String,
        request: Data = Data()
    ) {
        self.kind = kind
        self.scope = scope
        self.request = request
    }
}

public enum NetworkProviderError: String, Codable, Error, Equatable, Sendable {
    case invalidDeclaration
    case untrustedSignature
    case digestMismatch
    case revoked
    case expiredGrant
    case deniedGrant
    case invalidProtocol
    case outputLimitExceeded
    case executionFailed
    case replayDetected
}

public actor RestrictedNetworkProviderHost {
    public static let maximumDeclarationBytes = 128 * 1_024
    public static let maximumPayloadEntries = 256
    public static let maximumPayloadKeyBytes = 1_024
    public static let maximumPayloadValueBytes = 256 * 1_024
    public static let maximumBrokerRequests = 32
    public static let maximumBrokerRequestBytes = 256 * 1_024
    public static let maximumBrokerResponseBytes = 1 * 1_024 * 1_024

    private let verifier: any DetachedCMSVerifier
    private let executor: any NetworkProviderWasmExecutor
    private let revocations: any NetworkProviderRevocationStore
    private let broker: (any NetworkProviderBroker)?
    private var issuedNonces = Set<String>()
    private var nonceOrder: [String] = []

    public init(
        verifier: any DetachedCMSVerifier,
        executor: any NetworkProviderWasmExecutor,
        revocations: any NetworkProviderRevocationStore,
        broker: (any NetworkProviderBroker)? = nil
    ) {
        self.verifier = verifier
        self.executor = executor
        self.revocations = revocations
        self.broker = broker
    }

    public func invoke(
        declaration: Data,
        detachedCMS: Data,
        module: Data,
        grant: NetworkProviderGrant,
        operation: NetworkProviderOperation,
        payload: [String: String] = [:],
        longRunning: Bool = false,
        now: Date = .now
    ) async throws -> [String: String] {
        let declared = try parseDeclaration(declaration)
        try validateGrant(grant, for: declared, now: now)
        guard !(try await revocations.isRevoked(
            identifier: declared.identifier,
            moduleSHA256: declared.moduleSHA256
        )) else {
            throw NetworkProviderError.revoked
        }
        guard Self.digest(module) == declared.moduleSHA256 else {
            throw NetworkProviderError.digestMismatch
        }
        guard !detachedCMS.isEmpty else {
            throw NetworkProviderError.untrustedSignature
        }
        do {
            try verifier.verifyDetachedCMS(
                signature: detachedCMS,
                content: declaration,
                trustedSigner: declared.signer
            )
        } catch {
            throw NetworkProviderError.untrustedSignature
        }
        try Self.validatePayload(payload)

        let nonce = issueNonce()
        let request = ProviderRequest(
            version: 1,
            nonce: nonce,
            operation: operation,
            payload: payload
        )
        let input = try Self.encode(request)
        guard input.count <= WasmKitNetworkProviderExecutor.maximumInputBytes else {
            throw NetworkProviderError.invalidProtocol
        }

        let output: Data
        do {
            output = try await executor.execute(
                module: module,
                stdin: input,
                sandbox: NetworkProviderSandbox(longRunning: longRunning)
            )
        } catch let error as NetworkProviderError {
            throw error
        } catch {
            throw NetworkProviderError.executionFailed
        }
        guard output.count <= NetworkProviderSandbox.maximumOutputBytes else {
            throw NetworkProviderError.outputLimitExceeded
        }
        let response = try Self.decodeCanonicalResponse(output)
        guard response.version == 1,
              response.operation == operation,
              response.status == "ok"
        else {
            throw NetworkProviderError.invalidProtocol
        }
        guard response.nonce == nonce else {
            if issuedNonces.contains(response.nonce) {
                throw NetworkProviderError.replayDetected
            }
            throw NetworkProviderError.invalidProtocol
        }
        try Self.validatePayload(response.payload)

        let requests = try validatedBrokerRequests(
            from: response,
            grant: grant
        )
        try await executeBrokerRequests(requests)
        return response.payload
    }

    public func revokeThenStop(
        identifier: String,
        moduleSHA256: String,
        stop: @Sendable () async throws -> Void,
        at: Date = .now
    ) async throws {
        try await revocations.revoke(
            identifier: identifier,
            moduleSHA256: moduleSHA256,
            at: at
        )
        try await stop()
    }

    private func issueNonce() -> String {
        let nonce = UUID().uuidString.lowercased()
        issuedNonces.insert(nonce)
        nonceOrder.append(nonce)
        if nonceOrder.count > 4_096 {
            let expired = nonceOrder.removeFirst()
            issuedNonces.remove(expired)
        }
        return nonce
    }

    private func validateGrant(
        _ grant: NetworkProviderGrant,
        for declaration: NetworkProviderDeclaration,
        now: Date
    ) throws {
        guard declaration.identifier == grant.identifier,
              declaration.kind == grant.kind
        else {
            throw NetworkProviderError.deniedGrant
        }
        guard grant.expiresAt > now else {
            throw NetworkProviderError.expiredGrant
        }
        guard Self.isSafeName(grant.approvedBy),
              grant.allowedHTTPSOrigins.allSatisfy(Self.isCanonicalHTTPSOrigin),
              grant.secretReferences.allSatisfy({
                  Self.isScope($0, prefix: "secret:")
              }),
              grant.identityScopes.allSatisfy({
                  Self.isScope($0, prefix: "identity:")
              }),
              grant.routeScopes.allSatisfy({
                  Self.isScope($0, prefix: "route:")
              })
        else {
            throw NetworkProviderError.deniedGrant
        }
    }

    private func validatedBrokerRequests(
        from response: ProviderResponse,
        grant: NetworkProviderGrant
    ) throws -> [NetworkProviderBrokerRequest] {
        var requests = response.brokerRequests ?? []
        if let origin = response.httpsOrigin {
            requests.append(
                NetworkProviderBrokerRequest(
                    kind: .https,
                    scope: origin,
                    request: try Self.encode(response.payload)
                )
            )
        }
        if let reference = response.secretReference {
            requests.append(
                NetworkProviderBrokerRequest(
                    kind: .secretReference,
                    scope: reference
                )
            )
        }
        if let identity = response.identityScope {
            requests.append(
                NetworkProviderBrokerRequest(
                    kind: .identity,
                    scope: identity,
                    request: try Self.encode(response.payload)
                )
            )
        }
        if let route = response.routeScope {
            requests.append(
                NetworkProviderBrokerRequest(
                    kind: .route,
                    scope: route,
                    request: try Self.encode(response.payload)
                )
            )
        }
        guard requests.count <= Self.maximumBrokerRequests else {
            throw NetworkProviderError.deniedGrant
        }

        for request in requests {
            guard request.request.count <= Self.maximumBrokerRequestBytes else {
                throw NetworkProviderError.deniedGrant
            }
            switch request.kind {
            case .https:
                guard Self.isCanonicalHTTPSOrigin(request.scope),
                      grant.allowedHTTPSOrigins.contains(request.scope)
                else {
                    throw NetworkProviderError.deniedGrant
                }
            case .secretReference:
                guard request.request.isEmpty,
                      Self.isScope(request.scope, prefix: "secret:"),
                      grant.secretReferences.contains(request.scope)
                else {
                    throw NetworkProviderError.deniedGrant
                }
            case .identity:
                guard Self.isScope(request.scope, prefix: "identity:"),
                      grant.identityScopes.contains(request.scope)
                else {
                    throw NetworkProviderError.deniedGrant
                }
            case .route:
                guard Self.isScope(request.scope, prefix: "route:"),
                      grant.routeScopes.contains(request.scope)
                else {
                    throw NetworkProviderError.deniedGrant
                }
            }
        }
        guard requests.isEmpty || broker != nil else {
            throw NetworkProviderError.deniedGrant
        }
        return requests
    }

    private func executeBrokerRequests(
        _ requests: [NetworkProviderBrokerRequest]
    ) async throws {
        guard let broker else {
            return
        }
        var responseBytes = 0
        do {
            for request in requests {
                let response: Data
                switch request.kind {
                case .https:
                    response = try await broker.https(
                        origin: request.scope,
                        request: request.request
                    )
                case .secretReference:
                    let handle = try await broker.secretReference(request.scope)
                    guard Self.isSafeName(handle.identifier) else {
                        throw NetworkProviderError.deniedGrant
                    }
                    response = Data()
                case .identity:
                    response = try await broker.identity(
                        scope: request.scope,
                        request: request.request
                    )
                case .route:
                    response = try await broker.route(
                        scope: request.scope,
                        request: request.request
                    )
                }
                let (newCount, overflow) = responseBytes.addingReportingOverflow(
                    response.count
                )
                guard !overflow,
                      newCount <= Self.maximumBrokerResponseBytes
                else {
                    throw NetworkProviderError.outputLimitExceeded
                }
                responseBytes = newCount
            }
        } catch let error as NetworkProviderError {
            throw error
        } catch {
            throw NetworkProviderError.deniedGrant
        }
    }

    private func parseDeclaration(_ data: Data) throws -> NetworkProviderDeclaration {
        guard !data.isEmpty,
              data.count <= Self.maximumDeclarationBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "apiVersion",
                  "identifier",
                  "kind",
                  "moduleSHA256",
                  "signer"
              ],
              let value = try? JSONDecoder().decode(
                  NetworkProviderDeclaration.self,
                  from: data
              ),
              value.apiVersion == 1,
              Self.isProviderIdentifier(value.identifier),
              value.moduleSHA256.range(
                  of: "^[a-f0-9]{64}$",
                  options: .regularExpression
              ) != nil,
              Self.isSafeName(value.signer),
              (try? Self.encode(value)) == data
        else {
            throw NetworkProviderError.invalidDeclaration
        }
        return value
    }

    private static func validatePayload(_ payload: [String: String]) throws {
        guard payload.count <= maximumPayloadEntries,
              payload.allSatisfy({
                  !$0.key.isEmpty
                      && $0.key.utf8.count <= maximumPayloadKeyBytes
                      && $0.value.utf8.count <= maximumPayloadValueBytes
              })
        else {
            throw NetworkProviderError.invalidProtocol
        }
    }

    private static func isProviderIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$",
            options: .regularExpression
        ) != nil && !value.contains("..")
    }

    private static func isSafeName(_ value: String) -> Bool {
        value.utf8.count <= 128
            && value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$",
                options: .regularExpression
            ) != nil
            && !value.contains("..")
    }

    private static func isScope(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else {
            return false
        }
        let suffix = String(value.dropFirst(prefix.count))
        return suffix.utf8.count <= 256
            && suffix.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$",
                options: .regularExpression
            ) != nil
            && !suffix.contains("..")
    }

    private static func isCanonicalHTTPSOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              !value.contains(".."),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              host == host.lowercased(),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return false
        }
        var canonical = "https://"
        canonical += host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            canonical += ":\(port)"
        }
        return canonical == value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeCanonicalResponse(
        _ data: Data
    ) throws -> ProviderResponse {
        guard !data.isEmpty,
              data.count <= NetworkProviderSandbox.maximumOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw NetworkProviderError.invalidProtocol
        }
        let requiredKeys: Set<String> = [
            "nonce",
            "operation",
            "payload",
            "status",
            "version"
        ]
        let optionalKeys: Set<String> = [
            "brokerRequests",
            "httpsOrigin",
            "identityScope",
            "routeScope",
            "secretReference"
        ]
        let keys = Set(dictionary.keys)
        guard requiredKeys.isSubset(of: keys),
              keys.isSubset(of: requiredKeys.union(optionalKeys)),
              let response = try? JSONDecoder().decode(
                  ProviderResponse.self,
                  from: data
              ),
              (try? encode(response)) == data
        else {
            throw NetworkProviderError.invalidProtocol
        }
        return response
    }
}

private struct ProviderRequest: Codable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let payload: [String: String]
}

private struct ProviderResponse: Codable {
    let version: Int
    let nonce: String
    let operation: NetworkProviderOperation
    let status: String
    let payload: [String: String]
    let brokerRequests: [NetworkProviderBrokerRequest]?
    let httpsOrigin: String?
    let secretReference: String?
    let identityScope: String?
    let routeScope: String?
}
