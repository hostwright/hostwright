import Foundation

public enum ContainerizationHelperProtocolV1 {
    public static let version = 1
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let frameHeaderBytes = 4
}

public enum ContainerizationHelperOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case negotiate
    case observe
    case localImageEvidence
    case resourceUsage
    case logs
    case create
    case start
    case stop
    case restart
    case delete
    case cancel
    case shutdown
}

public enum ContainerizationHelperProtocolError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
    case zeroLengthFrame
    case frameTooLarge
    case truncatedFrame
    case trailingFrameBytes
    case invalidJSON
    case nonCanonicalJSON
    case unsupportedProtocolVersion(Int)
    case invalidRequestID
    case duplicateRequestID
    case expiredDeadline
    case invalidCapabilityDigest
    case capabilityDigestMismatch
    case invalidIdempotencyKey
    case invalidMutationContext
    case invalidResultEnvelope
    case invalidErrorEnvelope
}

extension RuntimeMutationContext: Codable {
    private enum CodingKeys: String, CodingKey {
        case providerAPIVersion
        case providerID
        case capabilitySHA256
        case operationID
        case resourceUUID
        case resourceGeneration
        case projectResourceUUID
        case projectGeneration
        case providerGeneration
        case fencingToken
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerAPIVersion: try values.decode(Int.self, forKey: .providerAPIVersion),
            providerID: try values.decode(RuntimeProviderID.self, forKey: .providerID),
            capabilitySHA256: try values.decode(String.self, forKey: .capabilitySHA256),
            operationID: try values.decode(String.self, forKey: .operationID),
            resourceUUID: try values.decode(String.self, forKey: .resourceUUID),
            resourceGeneration: try values.decode(Int.self, forKey: .resourceGeneration),
            projectResourceUUID: try values.decode(String.self, forKey: .projectResourceUUID),
            projectGeneration: try values.decode(Int.self, forKey: .projectGeneration),
            providerGeneration: try values.decode(Int.self, forKey: .providerGeneration),
            fencingToken: try values.decode(String.self, forKey: .fencingToken)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerAPIVersion, forKey: .providerAPIVersion)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(capabilitySHA256, forKey: .capabilitySHA256)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(resourceUUID, forKey: .resourceUUID)
        try values.encode(resourceGeneration, forKey: .resourceGeneration)
        try values.encode(projectResourceUUID, forKey: .projectResourceUUID)
        try values.encode(projectGeneration, forKey: .projectGeneration)
        try values.encode(providerGeneration, forKey: .providerGeneration)
        try values.encode(fencingToken, forKey: .fencingToken)
    }
}

public struct ContainerizationHelperRequest<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: ContainerizationHelperOperation
    public let deadlineUnixMilliseconds: Int64
    public let capabilityDigest: String
    public let mutationContext: RuntimeMutationContext?
    public let idempotencyKey: String
    public let payload: Payload

    public init(
        protocolVersion: Int = ContainerizationHelperProtocolV1.version,
        requestID: UUID = UUID(),
        operation: ContainerizationHelperOperation,
        deadlineUnixMilliseconds: Int64,
        capabilityDigest: String,
        mutationContext: RuntimeMutationContext? = nil,
        idempotencyKey: String,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.capabilityDigest = capabilityDigest
        self.mutationContext = mutationContext
        self.idempotencyKey = idempotencyKey
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case deadlineUnixMilliseconds = "deadline"
        case capabilityDigest
        case mutationContext
        case idempotencyKey
        case payload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        requestID = try Self.decodeCanonicalUUID(from: values, forKey: .requestID)
        operation = try values.decode(ContainerizationHelperOperation.self, forKey: .operation)
        deadlineUnixMilliseconds = try values.decode(Int64.self, forKey: .deadlineUnixMilliseconds)
        capabilityDigest = try values.decode(String.self, forKey: .capabilityDigest)
        mutationContext = try values.decodeIfPresent(RuntimeMutationContext.self, forKey: .mutationContext)
        idempotencyKey = try values.decode(String.self, forKey: .idempotencyKey)
        payload = try values.decode(Payload.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(deadlineUnixMilliseconds, forKey: .deadlineUnixMilliseconds)
        try values.encode(capabilityDigest, forKey: .capabilityDigest)
        try values.encodeIfPresent(mutationContext, forKey: .mutationContext)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(payload, forKey: .payload)
    }

    private static func decodeCanonicalUUID(
        from values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> UUID {
        let text = try values.decode(String.self, forKey: key)
        guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
            throw ContainerizationHelperProtocolError.invalidRequestID
        }
        return value
    }
}

extension ContainerizationHelperRequest: Equatable where Payload: Equatable {}

public struct ContainerizationHelperResultEnvelope<ResultPayload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: ContainerizationHelperOperation
    public let result: ResultPayload

    public init(
        protocolVersion: Int = ContainerizationHelperProtocolV1.version,
        requestID: UUID,
        operation: ContainerizationHelperOperation,
        result: ResultPayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case result
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        let requestIDText = try values.decode(String.self, forKey: .requestID)
        guard let requestID = UUID(uuidString: requestIDText),
              requestID.uuidString.lowercased() == requestIDText else {
            throw ContainerizationHelperProtocolError.invalidRequestID
        }
        self.requestID = requestID
        operation = try values.decode(ContainerizationHelperOperation.self, forKey: .operation)
        result = try values.decode(ResultPayload.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(result, forKey: .result)
    }
}

extension ContainerizationHelperResultEnvelope: Equatable where ResultPayload: Equatable {}

public enum ContainerizationHelperErrorCode: String, Codable, CaseIterable, Equatable, Sendable {
    case invalidRequest
    case unsupportedVersion
    case authenticationFailed
    case deadlineExceeded
    case capabilityMismatch
    case conflict
    case cancelled
    case unavailable
    case executionFailed
    case internalFailure
}

public struct ContainerizationHelperErrorPayload: Codable, Equatable, Sendable {
    public let code: ContainerizationHelperErrorCode
    public let message: String
    public let retryable: Bool

    public init(
        code: ContainerizationHelperErrorCode,
        message: String,
        retryable: Bool = false,
        sensitiveValues: [String] = []
    ) {
        self.code = code
        self.message = RuntimeRedactionPolicy.default.redact(message, exactValues: sensitiveValues)
        self.retryable = retryable
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(ContainerizationHelperErrorCode.self, forKey: .code)
        message = RuntimeRedactionPolicy.default.redact(try values.decode(String.self, forKey: .message))
        retryable = try values.decode(Bool.self, forKey: .retryable)
    }
}

public struct ContainerizationHelperErrorEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: ContainerizationHelperOperation
    public let error: ContainerizationHelperErrorPayload

    public init(
        protocolVersion: Int = ContainerizationHelperProtocolV1.version,
        requestID: UUID,
        operation: ContainerizationHelperOperation,
        error: ContainerizationHelperErrorPayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case operation
        case error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        let requestIDText = try values.decode(String.self, forKey: .requestID)
        guard let requestID = UUID(uuidString: requestIDText),
              requestID.uuidString.lowercased() == requestIDText else {
            throw ContainerizationHelperProtocolError.invalidRequestID
        }
        self.requestID = requestID
        operation = try values.decode(ContainerizationHelperOperation.self, forKey: .operation)
        error = try values.decode(ContainerizationHelperErrorPayload.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(error, forKey: .error)
    }
}

public enum ContainerizationHelperCanonicalJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch let error as ContainerizationHelperProtocolError {
            throw error
        } catch {
            throw ContainerizationHelperProtocolError.invalidJSON
        }
        guard !data.isEmpty else {
            throw ContainerizationHelperProtocolError.emptyPayload
        }
        guard data.count <= ContainerizationHelperProtocolV1.maximumPayloadBytes else {
            throw ContainerizationHelperProtocolError.payloadTooLarge
        }
        return data
    }

    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard !data.isEmpty else {
            throw ContainerizationHelperProtocolError.emptyPayload
        }
        guard data.count <= ContainerizationHelperProtocolV1.maximumPayloadBytes else {
            throw ContainerizationHelperProtocolError.payloadTooLarge
        }

        let value: Value
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch let error as ContainerizationHelperProtocolError {
            throw error
        } catch {
            throw ContainerizationHelperProtocolError.invalidJSON
        }
        guard try encode(value) == data else {
            throw ContainerizationHelperProtocolError.nonCanonicalJSON
        }
        return value
    }

    public static func decodeRequest<Payload: Codable & Sendable>(
        _ payloadType: Payload.Type,
        from data: Data
    ) throws -> ContainerizationHelperRequest<Payload> {
        let request = try decode(ContainerizationHelperRequest<Payload>.self, from: data)
        guard request.protocolVersion == ContainerizationHelperProtocolV1.version else {
            throw ContainerizationHelperProtocolError.unsupportedProtocolVersion(request.protocolVersion)
        }
        return request
    }

    public static func decodeResult<ResultPayload: Codable & Sendable>(
        _ resultType: ResultPayload.Type,
        from data: Data
    ) throws -> ContainerizationHelperResultEnvelope<ResultPayload> {
        let envelope = try decode(ContainerizationHelperResultEnvelope<ResultPayload>.self, from: data)
        guard envelope.protocolVersion == ContainerizationHelperProtocolV1.version else {
            throw ContainerizationHelperProtocolError.unsupportedProtocolVersion(envelope.protocolVersion)
        }
        return envelope
    }

    public static func decodeError(from data: Data) throws -> ContainerizationHelperErrorEnvelope {
        let envelope = try decode(ContainerizationHelperErrorEnvelope.self, from: data)
        guard envelope.protocolVersion == ContainerizationHelperProtocolV1.version else {
            throw ContainerizationHelperProtocolError.unsupportedProtocolVersion(envelope.protocolVersion)
        }
        return envelope
    }
}

public enum ContainerizationHelperFraming {
    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw ContainerizationHelperProtocolError.zeroLengthFrame
        }
        guard payload.count <= ContainerizationHelperProtocolV1.maximumPayloadBytes else {
            throw ContainerizationHelperProtocolError.frameTooLarge
        }

        let length = UInt32(payload.count)
        let header: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ]
        return Data(header) + payload
    }

    public static func decodeSingleFrame(_ data: Data) throws -> Data {
        var decoder = ContainerizationHelperFrameDecoder()
        _ = try decoder.append(data)
        return try decoder.finish()
    }
}

public struct ContainerizationHelperFrameDecoder: Sendable {
    private var buffer = Data()
    private var expectedPayloadBytes: Int?
    private var decodedPayload: Data?

    public init() {}

    public mutating func append(_ data: Data) throws -> Data? {
        guard !data.isEmpty else {
            return decodedPayload
        }
        guard decodedPayload == nil else {
            throw ContainerizationHelperProtocolError.trailingFrameBytes
        }

        buffer.append(data)
        if expectedPayloadBytes == nil, buffer.count >= ContainerizationHelperProtocolV1.frameHeaderBytes {
            let header = buffer.prefix(ContainerizationHelperProtocolV1.frameHeaderBytes)
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else {
                throw ContainerizationHelperProtocolError.zeroLengthFrame
            }
            guard length <= UInt32(ContainerizationHelperProtocolV1.maximumPayloadBytes) else {
                throw ContainerizationHelperProtocolError.frameTooLarge
            }
            expectedPayloadBytes = Int(length)
        }

        guard let expectedPayloadBytes else {
            return nil
        }
        let expectedFrameBytes = ContainerizationHelperProtocolV1.frameHeaderBytes + expectedPayloadBytes
        guard buffer.count <= expectedFrameBytes else {
            throw ContainerizationHelperProtocolError.trailingFrameBytes
        }
        guard buffer.count == expectedFrameBytes else {
            return nil
        }

        let payload = Data(buffer.dropFirst(ContainerizationHelperProtocolV1.frameHeaderBytes))
        decodedPayload = payload
        return payload
    }

    public mutating func finish() throws -> Data {
        guard let decodedPayload else {
            throw ContainerizationHelperProtocolError.truncatedFrame
        }
        return decodedPayload
    }
}

public struct ContainerizationHelperRequestValidator: Sendable {
    private var acceptedRequestIDs: Set<UUID>
    private let expectedCapabilityDigest: String?

    public init(expectedCapabilityDigest: String? = nil) {
        self.acceptedRequestIDs = []
        self.expectedCapabilityDigest = expectedCapabilityDigest
    }

    public mutating func validate<Payload: Codable & Sendable>(
        _ request: ContainerizationHelperRequest<Payload>,
        nowUnixMilliseconds: Int64
    ) throws {
        guard request.protocolVersion == ContainerizationHelperProtocolV1.version else {
            throw ContainerizationHelperProtocolError.unsupportedProtocolVersion(request.protocolVersion)
        }
        guard request.deadlineUnixMilliseconds > nowUnixMilliseconds else {
            throw ContainerizationHelperProtocolError.expiredDeadline
        }
        guard request.capabilityDigest.range(
            of: "^[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw ContainerizationHelperProtocolError.invalidCapabilityDigest
        }
        if let expectedCapabilityDigest, request.capabilityDigest != expectedCapabilityDigest {
            throw ContainerizationHelperProtocolError.capabilityDigestMismatch
        }
        guard Self.validIdempotencyKey(request.idempotencyKey) else {
            throw ContainerizationHelperProtocolError.invalidIdempotencyKey
        }
        if let mutationContext = request.mutationContext {
            guard mutationContext.validationIssue == nil,
                  mutationContext.providerID == .appleContainerization,
                  mutationContext.capabilitySHA256 == request.capabilityDigest else {
                throw ContainerizationHelperProtocolError.invalidMutationContext
            }
        }
        guard acceptedRequestIDs.insert(request.requestID).inserted else {
            throw ContainerizationHelperProtocolError.duplicateRequestID
        }
    }

    private static func validIdempotencyKey(_ value: String) -> Bool {
        value.utf8.count <= 256 &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$",
                options: .regularExpression
            ) != nil
    }
}

public struct ContainerizationHelperPeerIdentity: Equatable, Sendable {
    public let userID: UInt32
    public let processID: Int32
    public let teamIdentifier: String
    public let designatedRequirement: String

    public init(
        userID: UInt32,
        processID: Int32,
        teamIdentifier: String,
        designatedRequirement: String
    ) {
        self.userID = userID
        self.processID = processID
        self.teamIdentifier = teamIdentifier
        self.designatedRequirement = designatedRequirement
    }
}

public enum ContainerizationHelperPeerIdentityError: Error, Equatable, Sendable {
    case userIDMismatch
    case invalidProcessID
    case teamIdentifierMismatch
    case designatedRequirementMismatch
}

public struct ContainerizationHelperPeerIdentityPolicy: Equatable, Sendable {
    public static let expectedTeamIdentifier = "993YC3JY4Q"
    public static let expectedDesignatedRequirement =
        #"identifier "hostwright-containerization-helper" and anchor apple generic and certificate leaf[subject.OU] = "993YC3JY4Q""#

    package static func codeRequirementSource(
        identifier: String,
        teamIdentifier: String = expectedTeamIdentifier
    ) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    public let expectedUserID: UInt32

    public init(expectedUserID: UInt32) {
        self.expectedUserID = expectedUserID
    }

    public func validate(_ identity: ContainerizationHelperPeerIdentity) throws {
        guard identity.userID == expectedUserID else {
            throw ContainerizationHelperPeerIdentityError.userIDMismatch
        }
        guard identity.processID > 0 else {
            throw ContainerizationHelperPeerIdentityError.invalidProcessID
        }
        guard identity.teamIdentifier == Self.expectedTeamIdentifier else {
            throw ContainerizationHelperPeerIdentityError.teamIdentifierMismatch
        }
        guard identity.designatedRequirement == Self.expectedDesignatedRequirement else {
            throw ContainerizationHelperPeerIdentityError.designatedRequirementMismatch
        }
    }
}
