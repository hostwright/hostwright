import Darwin
import Foundation
import HostwrightRuntime
import Security

public enum StorageProviderTransportError: Error, Equatable, Sendable {
    case pathMustBeAbsolute
    case pathNotNormalized
    case pathTooLong
    case unsafeParent
    case unsafeRuntimeDirectory
    case runtimeDirectoryReplaced
    case socketPathOccupied
    case socketCreationFailed
    case socketConfigurationFailed
    case socketBindFailed
    case socketModeInvalid
    case socketListenFailed
    case socketPathReplaced
    case socketUnavailable
    case socketUnsafe
    case connectionFailed
    case peerAuthenticationFailed
    case truncatedFrame
    case frameTooLarge
    case timedOut
    case cancelled
    case providerCrashed
    case invalidProviderResponse
    case cleanupFailed
    case invalidTimeout
}

public enum StorageProviderFraming {
    public static let headerBytes = 4

    public static func frameRequest(_ payload: Data) throws -> Data {
        try frame(payload, maximumPayloadBytes: StorageProviderContract.maximumRequestBytes)
    }

    public static func frameResult(_ payload: Data) throws -> Data {
        try frame(payload, maximumPayloadBytes: StorageProviderContract.maximumResultBytes)
    }

    public static func decodeRequest(_ frame: Data) throws -> Data {
        try decodeSingleFrame(
            frame,
            maximumPayloadBytes: StorageProviderContract.maximumRequestBytes
        )
    }

    public static func decodeResult(_ frame: Data) throws -> Data {
        try decodeSingleFrame(
            frame,
            maximumPayloadBytes: StorageProviderContract.maximumResultBytes
        )
    }

    private static func frame(
        _ payload: Data,
        maximumPayloadBytes: Int
    ) throws -> Data {
        guard !payload.isEmpty else {
            throw StorageProviderProtocolError.emptyRequest
        }
        guard payload.count <= maximumPayloadBytes,
              payload.count <= Int(UInt32.max) else {
            throw StorageProviderTransportError.frameTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: headerBytes)
        result.append(payload)
        return result
    }

    private static func decodeSingleFrame(
        _ frame: Data,
        maximumPayloadBytes: Int
    ) throws -> Data {
        guard frame.count >= headerBytes else {
            throw StorageProviderTransportError.truncatedFrame
        }
        let length = frame.prefix(headerBytes).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0 else {
            throw StorageProviderTransportError.truncatedFrame
        }
        guard length <= UInt32(maximumPayloadBytes) else {
            throw StorageProviderTransportError.frameTooLarge
        }
        let expectedCount = headerBytes + Int(length)
        guard frame.count == expectedCount else {
            throw frame.count < expectedCount
                ? StorageProviderTransportError.truncatedFrame
                : StorageProviderProtocolError.nonCanonicalJSON
        }
        return Data(frame.dropFirst(headerBytes))
    }
}

public struct StorageProviderRuntimeDirectory: Sendable {
    public static let socketName = "storage-provider.sock"

    public let directoryURL: URL
    public let socketURL: URL
    public let createdDirectory: Bool

    private let backing: ContainerizationHelperRuntimeDirectory

    private init(backing: ContainerizationHelperRuntimeDirectory) {
        self.backing = backing
        directoryURL = backing.directoryURL
        socketURL = backing.socketURL
        createdDirectory = backing.createdDirectory
    }

    public static func prepare(
        at directoryURL: URL,
        owner: uid_t = geteuid()
    ) throws -> StorageProviderRuntimeDirectory {
        do {
            return StorageProviderRuntimeDirectory(
                backing: try ContainerizationHelperRuntimeDirectory.prepare(
                    at: directoryURL,
                    socketName: socketName,
                    owner: owner
                )
            )
        } catch {
            throw mapSocketError(error)
        }
    }

    public func makeListeningSocket(
        backlog: Int32 = 16
    ) throws -> StorageProviderSocketLease {
        do {
            return StorageProviderSocketLease(
                backing: try backing.makeListeningSocket(backlog: backlog)
            )
        } catch {
            throw Self.mapSocketError(error)
        }
    }

    public func validateCurrentDirectory() throws {
        do {
            try backing.validateCurrentDirectory()
        } catch {
            throw Self.mapSocketError(error)
        }
    }

    public func cleanupDirectoryIfCreated() throws {
        do {
            try backing.cleanupDirectoryIfCreated()
        } catch {
            throw Self.mapSocketError(error)
        }
    }

    private static func mapSocketError(_ error: Error) -> Error {
        guard let error = error as? ContainerizationHelperSocketError else {
            return error
        }
        switch error {
        case .pathMustBeAbsolute:
            return StorageProviderTransportError.pathMustBeAbsolute
        case .pathNotNormalized:
            return StorageProviderTransportError.pathNotNormalized
        case .pathTooLong:
            return StorageProviderTransportError.pathTooLong
        case .unsafeParent:
            return StorageProviderTransportError.unsafeParent
        case .unsafeRuntimeDirectory:
            return StorageProviderTransportError.unsafeRuntimeDirectory
        case .runtimeDirectoryReplaced:
            return StorageProviderTransportError.runtimeDirectoryReplaced
        case .socketPathOccupied:
            return StorageProviderTransportError.socketPathOccupied
        case .socketCreationFailed:
            return StorageProviderTransportError.socketCreationFailed
        case .socketConfigurationFailed:
            return StorageProviderTransportError.socketConfigurationFailed
        case .socketBindFailed:
            return StorageProviderTransportError.socketBindFailed
        case .socketModeInvalid:
            return StorageProviderTransportError.socketModeInvalid
        case .socketListenFailed:
            return StorageProviderTransportError.socketListenFailed
        case .socketPathReplaced:
            return StorageProviderTransportError.socketPathReplaced
        case .cleanupFailed:
            return StorageProviderTransportError.cleanupFailed
        }
    }
}

public final class StorageProviderSocketLease: @unchecked Sendable {
    public var descriptor: Int32 { backing.descriptor }
    public var socketURL: URL { backing.socketURL }

    private let backing: ContainerizationHelperSocketLease

    fileprivate init(backing: ContainerizationHelperSocketLease) {
        self.backing = backing
    }

    public func closeAndRemove() throws {
        do {
            try backing.closeAndRemove()
        } catch {
            if let error = error as? ContainerizationHelperSocketError,
               error == .socketPathReplaced {
                throw StorageProviderTransportError.socketPathReplaced
            }
            throw StorageProviderTransportError.cleanupFailed
        }
    }
}

public struct StorageProviderPeerIdentity: Equatable, Sendable {
    public let userID: uid_t
    public let processID: pid_t
    public let codeIdentifier: String
    public let teamIdentifier: String
    public let designatedRequirement: String

    public init(
        userID: uid_t,
        processID: pid_t,
        codeIdentifier: String,
        teamIdentifier: String,
        designatedRequirement: String
    ) {
        self.userID = userID
        self.processID = processID
        self.codeIdentifier = codeIdentifier
        self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement
    }
}

public enum StorageProviderPeerIdentityError: Error, Equatable, Sendable {
    case userIDMismatch
    case processIDInvalid
    case processIDMismatch
    case codeIdentifierMismatch
    case teamIdentifierMismatch
    case designatedRequirementMismatch
}

public struct StorageProviderPeerIdentityPolicy: Equatable, Sendable {
    public static let helperCodeIdentifier = "hostwright-storage-helper"
    public static let expectedTeamIdentifier = "993YC3JY4Q"
    public static let helperDesignatedRequirement = codeRequirementSource(
        identifier: helperCodeIdentifier
    )

    public let expectedUserID: uid_t
    public let expectedProcessID: pid_t?

    public init(
        expectedUserID: uid_t,
        expectedProcessID: pid_t? = nil
    ) {
        self.expectedUserID = expectedUserID
        self.expectedProcessID = expectedProcessID
    }

    public func validate(_ identity: StorageProviderPeerIdentity) throws {
        guard identity.userID == expectedUserID else {
            throw StorageProviderPeerIdentityError.userIDMismatch
        }
        guard identity.processID > 0 else {
            throw StorageProviderPeerIdentityError.processIDInvalid
        }
        if let expectedProcessID, identity.processID != expectedProcessID {
            throw StorageProviderPeerIdentityError.processIDMismatch
        }
        guard identity.codeIdentifier == Self.helperCodeIdentifier else {
            throw StorageProviderPeerIdentityError.codeIdentifierMismatch
        }
        guard identity.teamIdentifier == Self.expectedTeamIdentifier else {
            throw StorageProviderPeerIdentityError.teamIdentifierMismatch
        }
        guard identity.designatedRequirement == Self.helperDesignatedRequirement else {
            throw StorageProviderPeerIdentityError.designatedRequirementMismatch
        }
    }

    public static func codeRequirementSource(
        identifier: String,
        teamIdentifier: String = expectedTeamIdentifier
    ) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public struct StorageProviderServerPeerAuthenticator: Sendable {
    private let validation: @Sendable (Int32) throws -> Void

    public init(validation: @escaping @Sendable (Int32) throws -> Void) {
        self.validation = validation
    }

    public func validate(connectionDescriptor: Int32) throws {
        try validation(connectionDescriptor)
    }
}

public struct StorageProviderClientPeerAuthenticator: Sendable {
    private let validation: @Sendable (Int32, pid_t?) throws -> pid_t

    public init(
        validation: @escaping @Sendable (Int32, pid_t?) throws -> pid_t
    ) {
        self.validation = validation
    }

    public func validate(
        connectionDescriptor: Int32,
        expectedProcessID: pid_t?
    ) throws -> pid_t {
        try validation(connectionDescriptor, expectedProcessID)
    }

    public static func signedHelper(
        expectedUserID: uid_t = geteuid()
    ) -> StorageProviderClientPeerAuthenticator {
        StorageProviderClientPeerAuthenticator { descriptor, expectedProcessID in
            try StorageProviderLiveHelperAuthentication.validate(
                descriptor: descriptor,
                expectedUserID: expectedUserID,
                expectedProcessID: expectedProcessID
            )
        }
    }
}

private enum StorageProviderLiveHelperAuthentication {
    static func validate(
        descriptor: Int32,
        expectedUserID: uid_t,
        expectedProcessID: pid_t?
    ) throws -> pid_t {
        var peerUserID = uid_t.max
        var peerGroupID = gid_t.max
        guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
              peerUserID == expectedUserID else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }

        var peerProcessID = pid_t(0)
        var peerProcessIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerProcessID,
            &peerProcessIDSize
        ) == 0,
        peerProcessIDSize == MemoryLayout<pid_t>.size,
        peerProcessID > 0,
        expectedProcessID == nil || expectedProcessID == peerProcessID else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }

        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: peerProcessID)
        ] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }
        var signingInformation: CFDictionary?
        let signingFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            signingFlags,
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let identifier = information[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }

        let requirementText = StorageProviderPeerIdentityPolicy.codeRequirementSource(
            identifier: identifier
        )
        let identity = StorageProviderPeerIdentity(
            userID: peerUserID,
            processID: peerProcessID,
            codeIdentifier: identifier,
            teamIdentifier: teamIdentifier,
            designatedRequirement: requirementText
        )
        do {
            try StorageProviderPeerIdentityPolicy(
                expectedUserID: expectedUserID,
                expectedProcessID: expectedProcessID
            ).validate(identity)
        } catch {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(
            code,
            SecCSFlags(
                rawValue:
                    kSecCSStrictValidate |
                    storageCodeSigningRevocationFlag
            ),
            requirement
        ) == errSecSuccess else {
            throw StorageProviderTransportError.peerAuthenticationFailed
        }
        return peerProcessID
    }
}

struct StorageProviderRoutingRequest: Decodable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let operation: StorageProviderOperation
    let deadlineUnixMilliseconds: Int64
    let capabilitySHA256: String
    let idempotencyKey: String
    let mutationContext: StorageProviderMutationContext?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case deadlineUnixMilliseconds = "deadline"
        case capabilitySHA256
        case idempotencyKey
        case mutationContext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        let requestIDText = try values.decode(String.self, forKey: .requestID)
        guard let requestID = UUID(uuidString: requestIDText),
              requestID.uuidString.lowercased() == requestIDText else {
            throw StorageProviderProtocolError.invalidRequestID
        }
        self.requestID = requestID
        operation = try values.decode(StorageProviderOperation.self, forKey: .operation)
        deadlineUnixMilliseconds = try values.decode(Int64.self, forKey: .deadlineUnixMilliseconds)
        capabilitySHA256 = try values.decode(String.self, forKey: .capabilitySHA256)
        idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        mutationContext = try values.decodeIfPresent(
            StorageProviderMutationContext.self,
            forKey: .mutationContext
        )
    }
}

private struct StorageProviderRoutingResponse: Decodable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let operation: StorageProviderOperation

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        let requestIDText = try values.decode(String.self, forKey: .requestID)
        guard let requestID = UUID(uuidString: requestIDText),
              requestID.uuidString.lowercased() == requestIDText else {
            throw StorageProviderProtocolError.invalidRequestID
        }
        self.requestID = requestID
        operation = try values.decode(StorageProviderOperation.self, forKey: .operation)
    }
}

enum StorageProviderCanonicalTransportJSON {
    static let requiredRequestKeys: Set<String> = [
        "protocolVersion",
        "requestID",
        "operation",
        "deadline",
        "capabilitySHA256",
        "idempotencyKey",
        "payload"
    ]

    static func decodeRequest(_ data: Data) throws -> StorageProviderRoutingRequest {
        let object = try canonicalObject(data)
        let allowedKeys = requiredRequestKeys.union(["mutationContext"])
        let keys = Set(object.keys)
        guard requiredRequestKeys.isSubset(of: keys),
              keys.isSubset(of: allowedKeys) else {
            throw StorageProviderProtocolError.nonCanonicalJSON
        }
        do {
            return try JSONDecoder().decode(
                StorageProviderRoutingRequest.self,
                from: data
            )
        } catch let error as StorageProviderProtocolError {
            throw error
        } catch {
            throw StorageProviderProtocolError.invalidJSON
        }
    }

    static func validateResponse(
        _ data: Data,
        requestID: UUID,
        operation: StorageProviderOperation
    ) throws {
        let object = try canonicalObject(data)
        let common: Set<String> = ["protocolVersion", "requestID", "operation"]
        let resultKeys = common.union(["result"])
        let errorKeys = common.union(["failure"])
        guard Set(object.keys) == resultKeys || Set(object.keys) == errorKeys else {
            throw StorageProviderTransportError.invalidProviderResponse
        }
        let route: StorageProviderRoutingResponse
        do {
            route = try JSONDecoder().decode(
                StorageProviderRoutingResponse.self,
                from: data
            )
        } catch {
            throw StorageProviderTransportError.invalidProviderResponse
        }
        guard route.protocolVersion == StorageProviderContract.protocolVersion,
              route.requestID == requestID,
              route.operation == operation else {
            throw StorageProviderProtocolError.responseMismatch
        }
    }

    private static func canonicalObject(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StorageProviderProtocolError.invalidJSON
        }
        guard let object = value as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            throw StorageProviderProtocolError.invalidJSON
        }
        let canonical: Data
        do {
            canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw StorageProviderProtocolError.invalidJSON
        }
        guard canonical == data else {
            throw StorageProviderProtocolError.nonCanonicalJSON
        }
        return object
    }
}

private final class StorageProviderInvocationRace: @unchecked Sendable {
    private let provider: any StorageProviderSPI
    private let requestID: UUID
    private let canonicalRequest: Data
    private let timeoutNanoseconds: UInt64
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var providerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(
        provider: any StorageProviderSPI,
        requestID: UUID,
        canonicalRequest: Data,
        timeoutMilliseconds: Int64
    ) {
        self.provider = provider
        self.requestID = requestID
        self.canonicalRequest = canonicalRequest
        timeoutNanoseconds = UInt64(max(1, timeoutMilliseconds)) * 1_000_000
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let providerTask = providerTask
        lock.unlock()
        providerTask?.cancel()
        Task { [provider, requestID] in
            await provider.cancel(requestID: requestID)
        }
        finish(.failure(StorageProviderTransportError.cancelled))
    }

    private func start(continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let providerTask = Task { [provider, canonicalRequest] in
            do {
                finish(.success(try await provider.invoke(canonicalRequest: canonicalRequest)))
            } catch is CancellationError {
                finish(.failure(StorageProviderTransportError.cancelled))
            } catch {
                finish(.failure(StorageProviderTransportError.providerCrashed))
            }
        }
        let timeoutTask = Task { [provider, requestID, timeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            await provider.cancel(requestID: requestID)
            providerTask.cancel()
            finish(.failure(StorageProviderTransportError.timedOut))
        }

        lock.lock()
        if completed {
            lock.unlock()
            providerTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.providerTask = providerTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        if continuation == nil {
            pendingResult = result
        }
        let providerTask = providerTask
        let timeoutTask = timeoutTask
        lock.unlock()

        providerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

public actor StorageProviderTransportDispatcher {
    private let provider: any StorageProviderSPI
    private let descriptor: StorageProviderDescriptor
    private var requestValidator: StorageProviderRequestValidator
    private var activeInvocations: [UUID: StorageProviderInvocationRace] = [:]

    public static func make(
        provider: any StorageProviderSPI
    ) async throws -> StorageProviderTransportDispatcher {
        let descriptor = try await provider.descriptor()
        return try StorageProviderTransportDispatcher(
            provider: provider,
            descriptor: descriptor
        )
    }

    public init(
        provider: any StorageProviderSPI,
        descriptor: StorageProviderDescriptor
    ) throws {
        try StorageProviderDescriptorValidator.validate(descriptor)
        self.provider = provider
        self.descriptor = descriptor
        requestValidator = StorageProviderRequestValidator(
            expectedCapabilitySHA256: try descriptor.canonicalSHA256()
        )
    }

    public func dispatch(
        frame: Data,
        nowUnixMilliseconds: Int64 = Int64(
            Date().timeIntervalSince1970 * 1_000
        )
    ) async throws -> Data {
        let canonicalRequest = try StorageProviderFraming.decodeRequest(frame)
        let request = try StorageProviderCanonicalTransportJSON.decodeRequest(
            canonicalRequest
        )

        do {
            guard canonicalRequest.count <= descriptor.maximumRequestBytes else {
                throw StorageProviderProtocolError.requestTooLarge(
                    maximumBytes: descriptor.maximumRequestBytes
                )
            }
            try requestValidator.validate(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                operation: request.operation,
                deadlineUnixMilliseconds: request.deadlineUnixMilliseconds,
                capabilitySHA256: request.capabilitySHA256,
                idempotencyKey: request.idempotencyKey,
                mutationContext: request.mutationContext,
                nowUnixMilliseconds: nowUnixMilliseconds
            )
            try StorageProviderCapabilityNegotiator.requireAvailable(
                request.operation,
                in: descriptor
            )

            let timeout = request.deadlineUnixMilliseconds - nowUnixMilliseconds
            let invocation = StorageProviderInvocationRace(
                provider: provider,
                requestID: request.requestID,
                canonicalRequest: canonicalRequest,
                timeoutMilliseconds: timeout
            )
            activeInvocations[request.requestID] = invocation
            defer { activeInvocations.removeValue(forKey: request.requestID) }
            let response = try await invocation.run()
            guard !response.isEmpty else {
                throw StorageProviderTransportError.invalidProviderResponse
            }
            guard response.count <= descriptor.maximumResultBytes,
                  response.count <= StorageProviderContract.maximumResultBytes else {
                throw StorageProviderTransportError.frameTooLarge
            }
            try StorageProviderCanonicalTransportJSON.validateResponse(
                response,
                requestID: request.requestID,
                operation: request.operation
            )
            return try StorageProviderFraming.frameResult(response)
        } catch {
            let failure = Self.failure(
                for: error,
                operation: request.operation
            )
            let response = try StorageProviderCanonicalJSON.encodeError(
                StorageProviderErrorEnvelope(
                    requestID: request.requestID,
                    operation: request.operation,
                    failure: failure
                )
            )
            return try StorageProviderFraming.frameResult(response)
        }
    }

    public func cancel(requestID: UUID) {
        activeInvocations[requestID]?.cancel()
    }

    public func cancelAll() {
        for invocation in activeInvocations.values {
            invocation.cancel()
        }
    }

    private static func failure(
        for error: Error,
        operation: StorageProviderOperation
    ) -> StorageProviderFailure {
        if let protocolError = error as? StorageProviderProtocolError {
            return StorageProviderFailureNormalizer.normalize(protocolError)
        }
        if let capabilityError = error as? StorageProviderCapabilityError {
            return StorageProviderFailure(
                category: .rejected,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic: "The provider does not advertise the requested operation as available.",
                guidance: String(describing: capabilityError)
            )
        }
        guard let transportError = error as? StorageProviderTransportError else {
            return StorageProviderFailureNormalizer.normalize(
                .crashed,
                operation: operation
            )
        }
        switch transportError {
        case .timedOut:
            return StorageProviderFailureNormalizer.normalize(
                .hung,
                operation: operation
            )
        case .cancelled:
            return StorageProviderFailureNormalizer.normalize(
                .cancelled,
                operation: operation
            )
        case .frameTooLarge:
            return StorageProviderFailureNormalizer.normalize(
                .outputOverflow,
                operation: operation
            )
        case .providerCrashed, .invalidProviderResponse:
            return StorageProviderFailureNormalizer.normalize(
                .crashed,
                operation: operation
            )
        default:
            return StorageProviderFailure(
                category: .internalFailure,
                retryDisposition: operation.mutatesProviderState
                    ? .safeAfterObservation
                    : .never,
                recoveryDisposition: operation.mutatesProviderState
                    ? .reobserve
                    : .none,
                diagnostic: "The storage helper transport rejected the operation.",
                guidance: "Restore the signed helper boundary before retrying."
            )
        }
    }
}

public struct StorageProviderUnixServer: Sendable {
    public let runtimeDirectory: StorageProviderRuntimeDirectory
    public let dispatcher: StorageProviderTransportDispatcher
    public let authenticator: StorageProviderServerPeerAuthenticator
    public let connectionTimeoutMilliseconds: Int64

    public init(
        runtimeDirectory: StorageProviderRuntimeDirectory,
        dispatcher: StorageProviderTransportDispatcher,
        authenticator: StorageProviderServerPeerAuthenticator,
        connectionTimeoutMilliseconds: Int64 = 5_000
    ) throws {
        guard connectionTimeoutMilliseconds > 0 else {
            throw StorageProviderTransportError.invalidTimeout
        }
        self.runtimeDirectory = runtimeDirectory
        self.dispatcher = dispatcher
        self.authenticator = authenticator
        self.connectionTimeoutMilliseconds = connectionTimeoutMilliseconds
    }

    public func run() async throws {
        let lease = try runtimeDirectory.makeListeningSocket()
        await withTaskGroup(of: Void.self) { group in
            while !Task<Never, Never>.isCancelled {
                var pollDescriptor = pollfd(
                    fd: lease.descriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let result = Darwin.poll(&pollDescriptor, 1, 50)
                if result < 0 {
                    if errno == EINTR { continue }
                    break
                }
                guard result > 0,
                      pollDescriptor.revents & Int16(POLLIN) != 0 else {
                    continue
                }

                let connection = Darwin.accept(lease.descriptor, nil, nil)
                guard connection >= 0 else {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break
                }
                do {
                    let flags = fcntl(connection, F_GETFL)
                    guard flags >= 0,
                          fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                          fcntl(connection, F_SETFL, flags | O_NONBLOCK) == 0 else {
                        throw StorageProviderTransportError.socketConfigurationFailed
                    }
                    try authenticator.validate(connectionDescriptor: connection)
                } catch {
                    Darwin.close(connection)
                    continue
                }

                group.addTask {
                    await Self.handleConnection(
                        descriptor: connection,
                        dispatcher: dispatcher,
                        timeoutMilliseconds: connectionTimeoutMilliseconds
                    )
                    Darwin.close(connection)
                }
            }
            group.cancelAll()
            await dispatcher.cancelAll()
        }

        try lease.closeAndRemove()
        try runtimeDirectory.cleanupDirectoryIfCreated()
    }

    private static func handleConnection(
        descriptor: Int32,
        dispatcher: StorageProviderTransportDispatcher,
        timeoutMilliseconds: Int64
    ) async {
        do {
            let frame = try readFrame(
                descriptor: descriptor,
                maximumPayloadBytes: StorageProviderContract.maximumRequestBytes,
                deadlineMilliseconds: monotonicMilliseconds() + timeoutMilliseconds
            )
            let response = try await dispatcher.dispatch(frame: frame)
            try writeAll(
                descriptor: descriptor,
                data: response,
                deadlineMilliseconds: monotonicMilliseconds() + timeoutMilliseconds
            )
        } catch {
            return
        }
    }
}

public struct StorageProviderTransportResponse: Equatable, Sendable {
    public let frame: Data
    public let peerProcessID: pid_t
    public let socketDevice: UInt64
    public let socketInode: UInt64

    public init(
        frame: Data,
        peerProcessID: pid_t,
        socketDevice: UInt64,
        socketInode: UInt64
    ) {
        self.frame = frame
        self.peerProcessID = peerProcessID
        self.socketDevice = socketDevice
        self.socketInode = socketInode
    }
}

public struct StorageProviderClientTransport: Sendable {
    private let exchangeImplementation: @Sendable (
        Data,
        URL,
        Int64,
        pid_t?
    ) async throws -> StorageProviderTransportResponse

    public init(
        exchange: @escaping @Sendable (
            _ frame: Data,
            _ socketURL: URL,
            _ deadlineUnixMilliseconds: Int64,
            _ expectedProcessID: pid_t?
        ) async throws -> StorageProviderTransportResponse
    ) {
        exchangeImplementation = exchange
    }

    public func exchange(
        frame: Data,
        socketURL: URL,
        deadlineUnixMilliseconds: Int64,
        expectedProcessID: pid_t? = nil
    ) async throws -> StorageProviderTransportResponse {
        try await exchangeImplementation(
            frame,
            socketURL,
            deadlineUnixMilliseconds,
            expectedProcessID
        )
    }

    public static func unix(
        authenticator: StorageProviderClientPeerAuthenticator = .signedHelper()
    ) -> StorageProviderClientTransport {
        StorageProviderClientTransport { frame, socketURL, deadline, expectedProcessID in
            try StorageProviderUnixClient.exchange(
                frame: frame,
                socketURL: socketURL,
                deadlineUnixMilliseconds: deadline,
                expectedProcessID: expectedProcessID,
                authenticator: authenticator
            )
        }
    }
}

private enum StorageProviderUnixClient {
    static func exchange(
        frame: Data,
        socketURL: URL,
        deadlineUnixMilliseconds: Int64,
        expectedProcessID: pid_t?,
        authenticator: StorageProviderClientPeerAuthenticator
    ) throws -> StorageProviderTransportResponse {
        if Task<Never, Never>.isCancelled {
            throw StorageProviderTransportError.cancelled
        }
        let nowUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        guard deadlineUnixMilliseconds > nowUnixMilliseconds else {
            throw StorageProviderTransportError.timedOut
        }
        let remaining = deadlineUnixMilliseconds
            .subtractingReportingOverflow(nowUnixMilliseconds)
        guard !remaining.overflow,
              remaining.partialValue <=
                StorageProviderContract.maximumDeadlineWindowMilliseconds else {
            throw StorageProviderTransportError.timedOut
        }
        let deadlineMonotonicMilliseconds =
            monotonicMilliseconds() + remaining.partialValue
        guard frame.count <= StorageProviderContract.maximumRequestBytes
            + StorageProviderFraming.headerBytes else {
            throw StorageProviderTransportError.frameTooLarge
        }
        let socketIdentity = try requireSafeSocket(socketURL)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw StorageProviderTransportError.connectionFailed
        }
        defer { Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StorageProviderTransportError.connectionFailed
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw StorageProviderTransportError.pathTooLong
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in pathBytes.indices {
                    destination[index] = pathBytes[index]
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                throw StorageProviderTransportError.connectionFailed
            }
            try wait(
                descriptor,
                event: POLLOUT,
                deadlineMilliseconds: deadlineMonotonicMilliseconds
            )
            var socketError: Int32 = 0
            var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorSize
            ) == 0,
            socketError == 0 else {
                throw StorageProviderTransportError.connectionFailed
            }
        }

        let peerProcessID = try authenticator.validate(
            connectionDescriptor: descriptor,
            expectedProcessID: expectedProcessID
        )
        let currentSocketIdentity = try requireSafeSocket(socketURL)
        guard currentSocketIdentity.st_dev == socketIdentity.st_dev,
              currentSocketIdentity.st_ino == socketIdentity.st_ino else {
            throw StorageProviderTransportError.socketUnsafe
        }

        try writeAll(
            descriptor: descriptor,
            data: frame,
            deadlineMilliseconds: deadlineMonotonicMilliseconds
        )
        let response = try readFrame(
            descriptor: descriptor,
            maximumPayloadBytes: StorageProviderContract.maximumResultBytes,
            deadlineMilliseconds: deadlineMonotonicMilliseconds
        )
        return StorageProviderTransportResponse(
            frame: response,
            peerProcessID: peerProcessID,
            socketDevice: UInt64(socketIdentity.st_dev),
            socketInode: UInt64(socketIdentity.st_ino)
        )
    }

    private static func requireSafeSocket(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT {
                throw StorageProviderTransportError.socketUnavailable
            }
            throw StorageProviderTransportError.socketUnsafe
        }
        guard (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == 0o600 else {
            throw StorageProviderTransportError.socketUnsafe
        }
        return metadata
    }
}

private func readFrame(
    descriptor: Int32,
    maximumPayloadBytes: Int,
    deadlineMilliseconds: Int64
) throws -> Data {
    let header = try readExact(
        descriptor: descriptor,
        byteCount: StorageProviderFraming.headerBytes,
        deadlineMilliseconds: deadlineMilliseconds
    )
    let payloadLength = header.reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
    }
    guard payloadLength > 0 else {
        throw StorageProviderTransportError.truncatedFrame
    }
    guard payloadLength <= UInt32(maximumPayloadBytes) else {
        throw StorageProviderTransportError.frameTooLarge
    }
    let payload = try readExact(
        descriptor: descriptor,
        byteCount: Int(payloadLength),
        deadlineMilliseconds: deadlineMilliseconds
    )
    return header + payload
}

private func wait(
    _ descriptor: Int32,
    event: Int32,
    deadlineMilliseconds: Int64
) throws {
    while true {
        if Task<Never, Never>.isCancelled {
            throw StorageProviderTransportError.cancelled
        }
        let remaining = deadlineMilliseconds - monotonicMilliseconds()
        guard remaining > 0 else {
            throw StorageProviderTransportError.timedOut
        }
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(event),
            revents: 0
        )
        let result = Darwin.poll(
            &pollDescriptor,
            1,
            Int32(min(remaining, 50))
        )
        if result < 0, errno == EINTR { continue }
        guard result >= 0 else {
            throw StorageProviderTransportError.connectionFailed
        }
        if result == 0 { continue }
        guard pollDescriptor.revents & Int16(event) != 0 else {
            throw StorageProviderTransportError.connectionFailed
        }
        return
    }
}

private func readExact(
    descriptor: Int32,
    byteCount: Int,
    deadlineMilliseconds: Int64
) throws -> Data {
    var result = Data()
    result.reserveCapacity(byteCount)
    var buffer = [UInt8](
        repeating: 0,
        count: min(byteCount, 64 * 1_024)
    )
    while result.count < byteCount {
        if Task<Never, Never>.isCancelled {
            throw StorageProviderTransportError.cancelled
        }
        guard monotonicMilliseconds() < deadlineMilliseconds else {
            throw StorageProviderTransportError.timedOut
        }
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let ready = Darwin.poll(&pollDescriptor, 1, 50)
        if ready < 0 {
            if errno == EINTR { continue }
            throw StorageProviderTransportError.connectionFailed
        }
        guard ready > 0 else { continue }
        let requested = min(buffer.count, byteCount - result.count)
        let count = Darwin.read(descriptor, &buffer, requested)
        if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            continue
        }
        guard count > 0 else {
            throw StorageProviderTransportError.truncatedFrame
        }
        result.append(contentsOf: buffer[0..<count])
    }
    return result
}

private func writeAll(
    descriptor: Int32,
    data: Data,
    deadlineMilliseconds: Int64
) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            if Task<Never, Never>.isCancelled {
                throw StorageProviderTransportError.cancelled
            }
            guard monotonicMilliseconds() < deadlineMilliseconds else {
                throw StorageProviderTransportError.timedOut
            }
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let ready = Darwin.poll(&pollDescriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                throw StorageProviderTransportError.connectionFailed
            }
            guard ready > 0 else { continue }
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }
            guard count > 0 else {
                throw StorageProviderTransportError.connectionFailed
            }
            offset += count
        }
    }
}

private func monotonicMilliseconds() -> Int64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return Int64(time.tv_sec) * 1_000 + Int64(time.tv_nsec) / 1_000_000
}
