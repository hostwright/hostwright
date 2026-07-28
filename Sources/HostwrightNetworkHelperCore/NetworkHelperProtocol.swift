import Foundation
import HostwrightNetworking
import HostwrightRuntime

public enum NetworkHelperProtocolV1 {
    public static let version = 1
    public static let maximumFrameBytes =
        ContainerizationHelperProtocolV1.maximumPayloadBytes
    public static let maximumCorefileBytes = 1 * 1_024 * 1_024
}

enum NetworkHelperOperation: String, Codable, CaseIterable, Sendable {
    case apply
    case status
    case remove
}

enum NetworkHelperDisposition: String, Codable, Sendable {
    case absent
    case active
    case conflict
    case quarantined
}

public struct NetworkHelperDNSIdentity: Codable, Equatable, Sendable {
    public let projectUUID: String
    public let dnsUUID: String
    public let generation: Int
    public let fencingToken: String

    public init(
        projectUUID: String,
        dnsUUID: String,
        generation: Int,
        fencingToken: String
    ) {
        self.projectUUID = projectUUID
        self.dnsUUID = dnsUUID
        self.generation = generation
        self.fencingToken = fencingToken
    }

    func validated() throws -> Self {
        guard Self.isCanonicalUUID(projectUUID),
              Self.isCanonicalUUID(dnsUUID),
              generation > 0,
              Self.isCanonicalUUID(fencingToken) else {
            throw NetworkHelperError.invalidIdentity
        }
        return self
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

struct NetworkHelperRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: NetworkHelperOperation
    let identity: NetworkHelperDNSIdentity
    let corefile: String?
    let hostAccessBindings: [ProjectDNSHostAccessBinding]?
    let predecessorFencingToken: String?

    init(
        protocolVersion: Int = NetworkHelperProtocolV1.version,
        requestID: UUID = UUID(),
        operation: NetworkHelperOperation,
        identity: NetworkHelperDNSIdentity,
        corefile: String? = nil,
        hostAccessBindings: [ProjectDNSHostAccessBinding] = [],
        predecessorFencingToken: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID.uuidString.lowercased()
        self.operation = operation
        self.identity = identity
        self.corefile = corefile
        self.hostAccessBindings = hostAccessBindings.sorted(
            by: ProjectDNSHostAccessBinding.canonicalPrecedes
        )
        self.predecessorFencingToken = predecessorFencingToken
    }

    func validated() throws -> Self {
        guard protocolVersion == NetworkHelperProtocolV1.version else {
            throw NetworkHelperError.unsupportedProtocolVersion
        }
        guard let requestUUID = UUID(uuidString: requestID),
              requestUUID.uuidString.lowercased() == requestID else {
            throw NetworkHelperError.invalidRequest
        }
        _ = try identity.validated()
        if let predecessorFencingToken {
            guard let uuid = UUID(uuidString: predecessorFencingToken),
                  uuid.uuidString.lowercased() ==
                    predecessorFencingToken else {
                throw NetworkHelperError.invalidIdentity
            }
        }

        switch operation {
        case .apply:
            guard let corefile,
                  !corefile.isEmpty,
                  !corefile.utf8.contains(0),
                  corefile.lengthOfBytes(using: .utf8)
                    <= NetworkHelperProtocolV1.maximumCorefileBytes else {
                throw NetworkHelperError.invalidCorefile
            }
            _ = try NetworkHelperHostAccessValidation.validated(
                hostAccessBindings ?? []
            )
        case .status, .remove:
            guard corefile == nil,
                  hostAccessBindings == nil ||
                    hostAccessBindings?.isEmpty == true,
                  predecessorFencingToken == nil else {
                throw NetworkHelperError.invalidRequest
            }
        }
        return self
    }
}

struct NetworkHelperStatus: Codable, Equatable, Sendable {
    let disposition: NetworkHelperDisposition
    let identity: NetworkHelperDNSIdentity?
    let corefileSHA256: String?
    let hostAccessSHA256: String?
    let hostAccessActive: Bool?
    let reason: String?

    init(
        disposition: NetworkHelperDisposition,
        identity: NetworkHelperDNSIdentity?,
        corefileSHA256: String?,
        hostAccessSHA256: String? = nil,
        hostAccessActive: Bool? = nil,
        reason: String?
    ) {
        self.disposition = disposition
        self.identity = identity
        self.corefileSHA256 = corefileSHA256
        self.hostAccessSHA256 = hostAccessSHA256
        self.hostAccessActive = hostAccessActive
        self.reason = reason
    }
}

enum NetworkHelperErrorCode: String, Codable, Sendable {
    case invalidRequest
    case unsupportedProtocolVersion
    case invalidIdentity
    case invalidCorefile
    case invalidFrame
    case conflict
    case quarantined
    case unsafePath
    case ioFailure
    case permissionDenied
    case bindingUnavailable
}

struct NetworkHelperFailure: Codable, Equatable, Sendable {
    let code: NetworkHelperErrorCode
    let message: String
}

struct NetworkHelperResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let operation: NetworkHelperOperation
    let status: NetworkHelperStatus?
    let error: NetworkHelperFailure?

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        status: NetworkHelperStatus
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        self.status = status
        error = nil
    }

    init(
        requestID: String,
        operation: NetworkHelperOperation,
        error: NetworkHelperFailure
    ) {
        protocolVersion = NetworkHelperProtocolV1.version
        self.requestID = requestID
        self.operation = operation
        status = nil
        self.error = error
    }
}

enum NetworkHelperError: Error, Equatable, Sendable {
    case invalidRequest
    case unsupportedProtocolVersion
    case invalidIdentity
    case invalidCorefile
    case invalidFrame
    case conflict
    case quarantined
    case unsafePath
    case ioFailure
    case permissionDenied
    case bindingUnavailable

    var failure: NetworkHelperFailure {
        let code: NetworkHelperErrorCode
        let message: String
        switch self {
        case .invalidRequest:
            code = .invalidRequest
            message = "request is invalid"
        case .unsupportedProtocolVersion:
            code = .unsupportedProtocolVersion
            message = "protocol version is unsupported"
        case .invalidIdentity:
            code = .invalidIdentity
            message = "DNS ownership identity is invalid"
        case .invalidCorefile:
            code = .invalidCorefile
            message = "CoreDNS configuration is invalid"
        case .invalidFrame:
            code = .invalidFrame
            message = "request frame is invalid"
        case .conflict:
            code = .conflict
            message = "DNS ownership conflicts with the active generation"
        case .quarantined:
            code = .quarantined
            message = "DNS state is quarantined"
        case .unsafePath:
            code = .unsafePath
            message = "DNS state path is unsafe"
        case .ioFailure:
            code = .ioFailure
            message = "DNS state operation failed"
        case .permissionDenied:
            code = .permissionDenied
            message =
                "host-access listener permission is unavailable"
        case .bindingUnavailable:
            code = .bindingUnavailable
            message =
                "host-access listener or target is unavailable"
        }
        return NetworkHelperFailure(code: code, message: message)
    }
}

enum NetworkHelperCanonicalJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try ContainerizationHelperCanonicalJSON.encode(value)
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func decode<Value: Codable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try ContainerizationHelperCanonicalJSON.decode(
                type,
                from: data
            )
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func frame<Value: Encodable>(_ value: Value) throws -> Data {
        let payload = try encode(value)
        do {
            return try ContainerizationHelperFraming.frame(payload)
        } catch {
            throw NetworkHelperError.invalidFrame
        }
    }

    static func decodeFrame<Value: Codable>(
        _ type: Value.Type,
        from frame: Data
    ) throws -> Value {
        let payload: Data
        do {
            payload = try ContainerizationHelperFraming.decodeSingleFrame(
                frame
            )
        } catch {
            throw NetworkHelperError.invalidFrame
        }
        return try decode(type, from: payload)
    }
}
