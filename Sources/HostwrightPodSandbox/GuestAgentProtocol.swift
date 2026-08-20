import Foundation

public enum GuestAgentProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedFrame
    case malformedJSON
    case duplicateField(String)
    case unknownField(String)
    case missingField(String)
    case nonCanonicalJSON
    case unsupportedVersion(Int)
    case invalidEnvelope(String)
    case frameTooLarge
    case invalidFrameLength
    case invalidDeadline
    case deadlineExceeded
    case cancelled
    case creditExhausted
    case unauthenticated
    case peerClosed
    case writeClosed
    case requestIDMismatch
    case transportFailure

    public var description: String {
        switch self {
        case .malformedFrame: "The guest-agent frame is malformed."
        case .malformedJSON: "The guest-agent payload is not valid JSON."
        case .duplicateField(let field): "The guest-agent payload repeats field \(field)."
        case .unknownField(let field): "The guest-agent payload contains unsupported field \(field)."
        case .missingField(let field): "The guest-agent payload is missing field \(field)."
        case .nonCanonicalJSON: "The guest-agent payload is not canonical JSON."
        case .unsupportedVersion(let version): "Guest-agent protocol version \(version) is unsupported."
        case .invalidEnvelope(let field): "The guest-agent envelope is invalid: \(field)."
        case .frameTooLarge: "The guest-agent frame exceeds its bounded size."
        case .invalidFrameLength: "The guest-agent frame length is invalid."
        case .invalidDeadline: "The guest-agent deadline is invalid."
        case .deadlineExceeded: "The guest-agent deadline expired."
        case .cancelled: "The guest-agent request was cancelled."
        case .creditExhausted: "The guest-agent stream has no available credit."
        case .unauthenticated: "The guest-agent authenticated session boundary is unavailable."
        case .peerClosed: "The guest-agent peer closed the transport."
        case .writeClosed: "The guest-agent transport closed while writing."
        case .requestIDMismatch: "The guest-agent response request ID does not match."
        case .transportFailure: "The guest-agent transport failed at a bounded I/O boundary."
        }
    }
}

public enum GuestAgentProtocolV1 {
    public static let version = 1
    public static let lengthPrefixBytes = 4
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumResponseOrFrameBytes = 1 * 1_024 * 1_024
    public static let maximumDeadlineMilliseconds = 30_000
    public static let maximumRequestIDBytes = 128
    public static let maximumOwnerIDBytes = 128
    public static let maximumCredit = 64
    public static let maximumCapabilities = 16
    public static let maximumErrorBytes = 512
}

public enum GuestAgentEnvelopeKind: String, Codable, CaseIterable, Sendable {
    case request
    case response
}

public enum GuestAgentResult: String, Codable, CaseIterable, Sendable {
    case accepted
    case replayed
    case recovered
    case cancelled
    case teardownComplete
}

public enum GuestAgentErrorCode: String, Codable, CaseIterable, Sendable {
    case malformed
    case unsupportedVersion
    case unauthenticated
    case invalidTransition
    case ownershipMismatch
    case generationMismatch
    case generationConflict
    case replayMismatch
    case deadlineExceeded
    case cancelled
    case creditExhausted
    case sandboxNotFound
    case cleanupIncomplete
    case internalFailure
}

public enum GuestAgentCapability: String, Codable, CaseIterable, Sendable {
    case podSandboxLifecycle = "pod-sandbox-lifecycle"
    case restartRecovery = "restart-recovery"
    case cancellation = "cancellation"
    case streamCredit = "stream-credit"
    case strictFraming = "strict-framing"
}

public struct GuestAgentEnvelope: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let kind: GuestAgentEnvelopeKind
    public let requestID: String
    public let operation: PodSandboxTransition
    public let sandboxID: PodSandboxID
    public let ownerID: String
    public let generation: UInt64
    public let deadlineMilliseconds: Int
    public let credit: Int
    public let cancellationOfRequestID: String?
    public let cpuCount: UInt16?
    public let memoryMiB: UInt32?
    public let state: PodSandboxState?
    public let result: GuestAgentResult?
    public let error: GuestAgentErrorCode?
    public let capabilities: [GuestAgentCapability]

    public init(
        apiVersion: Int = GuestAgentProtocolV1.version,
        kind: GuestAgentEnvelopeKind,
        requestID: String,
        operation: PodSandboxTransition,
        sandboxID: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        deadlineMilliseconds: Int,
        credit: Int = 1,
        cancellationOfRequestID: String? = nil,
        cpuCount: UInt16? = nil,
        memoryMiB: UInt32? = nil,
        state: PodSandboxState? = nil,
        result: GuestAgentResult? = nil,
        error: GuestAgentErrorCode? = nil,
        capabilities: [GuestAgentCapability] = []
    ) throws {
        self.apiVersion = apiVersion
        self.kind = kind
        self.requestID = requestID
        self.operation = operation
        self.sandboxID = sandboxID
        self.ownerID = ownerID
        self.generation = generation
        self.deadlineMilliseconds = deadlineMilliseconds
        self.credit = credit
        self.cancellationOfRequestID = cancellationOfRequestID
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.state = state
        self.result = result
        self.error = error
        self.capabilities = capabilities
        try validate()
    }

    public static func request(
        requestID: String,
        operation: PodSandboxTransition,
        sandboxID: PodSandboxID,
        ownerID: String,
        generation: UInt64,
        deadlineMilliseconds: Int = 5_000,
        credit: Int = 1,
        cancellationOfRequestID: String? = nil,
        spec: PodSandboxSpec? = nil
    ) throws -> GuestAgentEnvelope {
        try GuestAgentEnvelope(
            kind: .request,
            requestID: requestID,
            operation: operation,
            sandboxID: sandboxID,
            ownerID: ownerID,
            generation: generation,
            deadlineMilliseconds: deadlineMilliseconds,
            credit: credit,
            cancellationOfRequestID: cancellationOfRequestID,
            cpuCount: spec?.cpuCount,
            memoryMiB: spec?.memoryMiB
        )
    }

    public static func response(
        for request: GuestAgentEnvelope,
        state: PodSandboxState?,
        result: GuestAgentResult? = nil,
        error: GuestAgentErrorCode? = nil,
        credit: Int = 0,
        capabilities: [GuestAgentCapability] = []
    ) throws -> GuestAgentEnvelope {
        try GuestAgentEnvelope(
            kind: .response,
            requestID: request.requestID,
            operation: request.operation,
            sandboxID: request.sandboxID,
            ownerID: request.ownerID,
            generation: request.generation,
            deadlineMilliseconds: request.deadlineMilliseconds,
            credit: credit,
            cancellationOfRequestID: request.cancellationOfRequestID,
            state: state,
            result: result,
            error: error,
            capabilities: capabilities
        )
    }

    public func validate() throws {
        guard apiVersion == GuestAgentProtocolV1.version else {
            throw GuestAgentProtocolError.unsupportedVersion(apiVersion)
        }
        try PodSandboxValidation.safeIdentifier(
            requestID,
            maximumLength: GuestAgentProtocolV1.maximumRequestIDBytes,
            field: "requestID"
        )
        try PodSandboxValidation.safeIdentifier(
            ownerID,
            maximumLength: GuestAgentProtocolV1.maximumOwnerIDBytes,
            field: "ownerID"
        )
        try PodSandboxValidation.generation(generation)
        guard (1...GuestAgentProtocolV1.maximumDeadlineMilliseconds).contains(deadlineMilliseconds) else {
            throw GuestAgentProtocolError.invalidDeadline
        }
        guard (0...GuestAgentProtocolV1.maximumCredit).contains(credit) else {
            throw GuestAgentProtocolError.invalidEnvelope("credit")
        }
        guard capabilities.count <= GuestAgentProtocolV1.maximumCapabilities,
              Set(capabilities).count == capabilities.count else {
            throw GuestAgentProtocolError.invalidEnvelope("capabilities")
        }
        if let cancellationOfRequestID {
            try PodSandboxValidation.safeIdentifier(
                cancellationOfRequestID,
                maximumLength: GuestAgentProtocolV1.maximumRequestIDBytes,
                field: "cancellationOfRequestID"
            )
        }
        guard kind == .request || kind == .response else {
            throw GuestAgentProtocolError.invalidEnvelope("kind")
        }

        switch kind {
        case .request:
            guard state == nil, result == nil, error == nil, capabilities.isEmpty else {
                throw GuestAgentProtocolError.invalidEnvelope("request-only fields")
            }
            if operation == .create {
                guard let cpuCount, let memoryMiB else {
                    throw GuestAgentProtocolError.missingField("create spec")
                }
                guard (1...PodSandboxSpec.maximumCPUCount).contains(cpuCount),
                      (PodSandboxSpec.minimumMemoryMiB...PodSandboxSpec.maximumMemoryMiB).contains(memoryMiB)
                else {
                    throw GuestAgentProtocolError.invalidEnvelope("create spec")
                }
            } else {
                guard cpuCount == nil, memoryMiB == nil else {
                    throw GuestAgentProtocolError.invalidEnvelope("non-create spec")
                }
            }
            if operation == .cancel {
                guard let cancellationOfRequestID else {
                    throw GuestAgentProtocolError.missingField("cancellationOfRequestID")
                }
                guard cancellationOfRequestID != requestID else {
                    throw GuestAgentProtocolError.invalidEnvelope("self-cancellation")
                }
            } else {
                guard cancellationOfRequestID == nil else {
                    throw GuestAgentProtocolError.invalidEnvelope("cancellationOfRequestID")
                }
            }

        case .response:
            guard cpuCount == nil, memoryMiB == nil else {
                throw GuestAgentProtocolError.invalidEnvelope("response spec")
            }
            if error == nil {
                guard state != nil, result != nil else {
                    throw GuestAgentProtocolError.missingField("response result")
                }
            } else {
                guard result == nil else {
                    throw GuestAgentProtocolError.invalidEnvelope("response error result")
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case kind
        case requestID
        case operation
        case sandboxID
        case ownerID
        case generation
        case deadlineMilliseconds
        case credit
        case cancellationOfRequestID
        case cpuCount
        case memoryMiB
        case state
        case result
        case error
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            apiVersion: container.decode(Int.self, forKey: .apiVersion),
            kind: container.decode(GuestAgentEnvelopeKind.self, forKey: .kind),
            requestID: container.decode(String.self, forKey: .requestID),
            operation: container.decode(PodSandboxTransition.self, forKey: .operation),
            sandboxID: container.decode(PodSandboxID.self, forKey: .sandboxID),
            ownerID: container.decode(String.self, forKey: .ownerID),
            generation: container.decode(UInt64.self, forKey: .generation),
            deadlineMilliseconds: container.decode(Int.self, forKey: .deadlineMilliseconds),
            credit: container.decode(Int.self, forKey: .credit),
            cancellationOfRequestID: container.decodeIfPresent(String.self, forKey: .cancellationOfRequestID),
            cpuCount: container.decodeIfPresent(UInt16.self, forKey: .cpuCount),
            memoryMiB: container.decodeIfPresent(UInt32.self, forKey: .memoryMiB),
            state: container.decodeIfPresent(PodSandboxState.self, forKey: .state),
            result: container.decodeIfPresent(GuestAgentResult.self, forKey: .result),
            error: container.decodeIfPresent(GuestAgentErrorCode.self, forKey: .error),
            capabilities: container.decode([GuestAgentCapability].self, forKey: .capabilities)
        )
    }
}

public enum GuestAgentEnvelopeCodec {
    private static let allKeys: Set<String> = [
        "apiVersion", "kind", "requestID", "operation", "sandboxID", "ownerID",
        "generation", "deadlineMilliseconds", "credit", "cancellationOfRequestID",
        "cpuCount", "memoryMiB", "state", "result", "error", "capabilities"
    ]
    private static let requiredKeys: Set<String> = [
        "apiVersion", "kind", "requestID", "operation", "sandboxID", "ownerID",
        "generation", "deadlineMilliseconds", "credit", "capabilities"
    ]

    public static func encode(_ envelope: GuestAgentEnvelope) throws -> Data {
        try envelope.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        let maximum = envelope.kind == .request
            ? GuestAgentProtocolV1.maximumRequestBytes
            : GuestAgentProtocolV1.maximumResponseOrFrameBytes
        guard !data.isEmpty, data.count <= maximum else {
            throw GuestAgentProtocolError.frameTooLarge
        }
        return data
    }

    public static func decode(
        _ data: Data,
        expectedKind: GuestAgentEnvelopeKind? = nil
    ) throws -> GuestAgentEnvelope {
        guard !data.isEmpty, data.count <= GuestAgentProtocolV1.maximumResponseOrFrameBytes else {
            throw GuestAgentProtocolError.frameTooLarge
        }
        if data.count > GuestAgentProtocolV1.maximumRequestBytes {
            let kindHint = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard kindHint?["kind"] as? String == GuestAgentEnvelopeKind.response.rawValue else {
                throw GuestAgentProtocolError.frameTooLarge
            }
        }
        let keys = try JSONTopLevelObject.keys(in: data)
        var seen = Set<String>()
        for key in keys {
            guard seen.insert(key).inserted else {
                throw GuestAgentProtocolError.duplicateField(key)
            }
            guard allKeys.contains(key) else {
                throw GuestAgentProtocolError.unknownField(key)
            }
        }
        guard requiredKeys.isSubset(of: Set(keys)) else {
            throw GuestAgentProtocolError.missingField("envelope")
        }

        let decoder = JSONDecoder()
        let envelope: GuestAgentEnvelope
        do {
            envelope = try decoder.decode(GuestAgentEnvelope.self, from: data)
        } catch let error as GuestAgentProtocolError {
            throw error
        } catch {
            throw GuestAgentProtocolError.malformedJSON
        }
        let maximum = envelope.kind == .request
            ? GuestAgentProtocolV1.maximumRequestBytes
            : GuestAgentProtocolV1.maximumResponseOrFrameBytes
        guard data.count <= maximum else {
            throw GuestAgentProtocolError.frameTooLarge
        }
        if let expectedKind, envelope.kind != expectedKind {
            throw GuestAgentProtocolError.invalidEnvelope("kind")
        }
        let canonical = try encode(envelope)
        guard canonical == data else {
            throw GuestAgentProtocolError.nonCanonicalJSON
        }
        return envelope
    }
}

enum JSONTopLevelObject {
    static func keys(in data: Data) throws -> [String] {
        var scanner = Scanner(bytes: Array(data))
        return try scanner.parseTopLevelObject()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseTopLevelObject() throws -> [String] {
            skipWhitespace()
            guard consume(123) else { throw GuestAgentProtocolError.malformedJSON }
            let keys = try parseObjectBody(collectKeys: true)
            skipWhitespace()
            guard index == bytes.count else { throw GuestAgentProtocolError.malformedJSON }
            return keys
        }

        mutating func parseObjectBody(collectKeys: Bool) throws -> [String] {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 16 else { throw GuestAgentProtocolError.malformedJSON }
            var keys: [String] = []
            var seen = Set<String>()
            skipWhitespace()
            if consume(125) { return keys }

            while true {
                skipWhitespace()
                let key = try parseString()
                guard seen.insert(key).inserted else {
                    throw GuestAgentProtocolError.duplicateField(key)
                }
                keys.append(key)
                skipWhitespace()
                guard consume(58) else { throw GuestAgentProtocolError.malformedJSON }
                try parseValue()
                skipWhitespace()
                if consume(125) { return collectKeys ? keys : [] }
                guard consume(44) else { throw GuestAgentProtocolError.malformedJSON }
            }
        }

        mutating func parseArray() throws {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 16 else { throw GuestAgentProtocolError.malformedJSON }
            skipWhitespace()
            if consume(93) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(93) { return }
                guard consume(44) else { throw GuestAgentProtocolError.malformedJSON }
            }
        }

        mutating func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw GuestAgentProtocolError.malformedJSON }
            switch bytes[index] {
            case 34:
                _ = try parseString()
            case 123:
                index += 1
                _ = try parseObjectBody(collectKeys: false)
            case 91:
                index += 1
                try parseArray()
            default:
                let start = index
                while index < bytes.count && ![44, 93, 125, 9, 10, 13, 32].contains(bytes[index]) {
                    index += 1
                }
                guard index > start else { throw GuestAgentProtocolError.malformedJSON }
            }
        }

        mutating func parseString() throws -> String {
            let start = index
            guard consume(34) else { throw GuestAgentProtocolError.malformedJSON }
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    let literal = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                        throw GuestAgentProtocolError.malformedJSON
                    }
                    return value
                }
            }
            throw GuestAgentProtocolError.malformedJSON
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) {
                index += 1
            }
        }
    }
}

public protocol GuestAgentAuthenticationBoundary: Sendable {
    func authorize(_ request: GuestAgentEnvelope) throws
}

public struct UnavailableGuestAgentAuthenticationBoundary: GuestAgentAuthenticationBoundary {
    public init() {}

    public func authorize(_ request: GuestAgentEnvelope) throws {
        throw GuestAgentProtocolError.unauthenticated
    }
}
