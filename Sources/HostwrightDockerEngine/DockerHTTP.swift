import Foundation

public enum DockerAPIVersionError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupported(String)
}

public struct DockerAPIVersion: RawRepresentable, Codable, Comparable, Hashable, Sendable,
    CustomStringConvertible
{
    public static let minimum = DockerAPIVersion(uncheckedMajor: 1, minor: 52)
    public static let maximum = DockerAPIVersion(uncheckedMajor: 1, minor: 55)
    public static let v1_52 = DockerAPIVersion(uncheckedMajor: 1, minor: 52)
    public static let v1_53 = DockerAPIVersion(uncheckedMajor: 1, minor: 53)
    public static let v1_54 = DockerAPIVersion(uncheckedMajor: 1, minor: 54)
    public static let v1_55 = DockerAPIVersion(uncheckedMajor: 1, minor: 55)
    public static let supported = [v1_52, v1_53, v1_54, v1_55]

    public let major: Int
    public let minor: Int

    public init?(rawValue: String) {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].allSatisfy({ $0.isNumber }),
              components[1].allSatisfy({ $0.isNumber }),
              !components[0].isEmpty,
              !components[1].isEmpty,
              (components[0].count == 1 || components[0].first != "0"),
              (components[1].count == 1 || components[1].first != "0"),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              (0...99).contains(major),
              (0...999).contains(minor) else {
            return nil
        }
        self.major = major
        self.minor = minor
    }

    public init(_ rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw DockerAPIVersionError.invalid(rawValue)
        }
        self = value
    }

    public init(major: Int, minor: Int) throws {
        guard (0...99).contains(major), (0...999).contains(minor) else {
            throw DockerAPIVersionError.invalid("\(major).\(minor)")
        }
        self.major = major
        self.minor = minor
    }

    private init(uncheckedMajor major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public var rawValue: String { "\(major).\(minor)" }
    public var description: String { rawValue }
    public var isSupported: Bool { Self.minimum...Self.maximum ~= self }

    public static func negotiate(requested: String?) throws -> DockerAPIVersion {
        guard let requested else { return maximum }
        let version = try DockerAPIVersion(requested)
        guard version.isSupported else {
            throw DockerAPIVersionError.unsupported(requested)
        }
        return version
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: DockerAPIVersion, rhs: DockerAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public enum DockerHTTPMethod: String, Codable, CaseIterable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"
}

public enum DockerHTTPProtocolError: Error, Equatable, Sendable {
    case cancelled
    case incompleteRequest
    case requestLineTooLarge
    case headersTooLarge
    case headerLineTooLarge
    case headerCountExceeded
    case invalidRequestLine
    case invalidHeader
    case invalidHeaderName
    case invalidHeaderValue
    case conflictingContentLength
    case invalidContentLength
    case conflictingFramingHeaders
    case unsupportedTransferEncoding
    case invalidChunk
    case bodyTooLarge
    case trailingBytes
    case unsupportedHTTPVersion
    case unsupportedUpgrade
    case responseTooLarge
}

public struct DockerHTTPRequest: Equatable, Sendable {
    public let method: DockerHTTPMethod
    public let target: String
    public let version: String
    public let headers: [String: String]
    public let body: Data
    public let keepAlive: Bool

    public init(
        method: DockerHTTPMethod,
        target: String,
        headers: [String: String] = [:],
        body: Data = Data(),
        version: String = "HTTP/1.1",
        keepAlive: Bool? = nil
    ) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = Self.normalized(headers)
        self.body = body
        self.keepAlive = keepAlive ?? Self.defaultKeepAlive(
            version: version,
            headers: self.headers
        )
    }

    public init(
        method: String,
        target: String,
        headers: [String: String] = [:],
        body: Data = Data(),
        version: String = "HTTP/1.1",
        keepAlive: Bool? = nil
    ) throws {
        guard let method = DockerHTTPMethod(rawValue: method) else {
            throw DockerHTTPProtocolError.invalidRequestLine
        }
        self.init(
            method: method,
            target: target,
            headers: headers,
            body: body,
            version: version,
            keepAlive: keepAlive
        )
    }

    public var path: String { target }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var isUpgradeRequest: Bool {
        header("upgrade") != nil || connectionTokens.contains("upgrade")
    }

    public var connectionTokens: Set<String> {
        Set(
            (header("connection") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
    }

    private static func normalized(_ headers: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }

    private static func defaultKeepAlive(version: String, headers: [String: String]) -> Bool {
        let connection = headers["connection"]?.lowercased() ?? ""
        if connection.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "close" }) {
            return false
        }
        return version == "HTTP/1.1"
    }
}

public struct DockerHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let reasonPhrase: String
    public let headers: [String: String]
    public let body: Data
    public let closeConnection: Bool

    public init(
        statusCode: Int,
        reasonPhrase: String? = nil,
        headers: [String: String] = [:],
        body: Data = Data(),
        closeConnection: Bool = false
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase ?? DockerHTTPStatus.reason(for: statusCode)
        self.headers = headers
        self.body = body
        self.closeConnection = closeConnection
    }

    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }
}

public enum DockerHTTPError: Error, Equatable, Sendable {
    case badRequest
    case unsupportedAPIVersion
    case endpointNotFound
    case methodNotAllowed
    case unsupportedOperation
    case unsupportedUpgrade
    case controlUnavailable
    case controlRejected
    case cancelled
    case internalError

    public var statusCode: Int {
        switch self {
        case .badRequest, .unsupportedAPIVersion: return 400
        case .methodNotAllowed: return 405
        case .endpointNotFound, .unsupportedOperation: return 404
        case .unsupportedUpgrade: return 426
        case .controlUnavailable: return 503
        case .controlRejected: return 500
        case .cancelled: return 499
        case .internalError: return 500
        }
    }

    public var message: String {
        switch self {
        case .badRequest: return "The Docker request target is invalid."
        case .unsupportedAPIVersion: return "Unsupported Docker API version."
        case .endpointNotFound: return "The requested Docker endpoint was not found."
        case .methodNotAllowed: return "The requested Docker method is not supported."
        case .unsupportedOperation:
            return "The requested Docker operation is not supported by Hostwright."
        case .unsupportedUpgrade: return "Docker protocol upgrades are not supported."
        case .controlUnavailable: return "The Hostwright Control API is unavailable."
        case .controlRejected: return "The Hostwright Control API rejected the request."
        case .cancelled: return "The Docker request was cancelled."
        case .internalError: return "The Docker proxy failed safely."
        }
    }
}

public enum DockerHTTPStatus {
    public static func reason(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 426: return "Upgrade Required"
        case 499: return "Client Closed Request"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "HTTP Response"
        }
    }
}

public enum DockerHTTPCodec {
    public static let maximumRequestLineBytes = 8 * 1_024
    public static let maximumHeaderBytes = 32 * 1_024
    public static let maximumHeaderLineBytes = 8 * 1_024
    public static let maximumHeaderCount = 100
    public static let maximumBodyBytes = 1 * 1_024 * 1_024
    public static let maximumResponseBytes = 1 * 1_024 * 1_024
    public static let maximumChunkLineBytes = 128

    public static func parseRequest(
        _ data: Data,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> DockerHTTPRequest {
        try checkCancellation(isCancelled)
        guard !data.isEmpty else { throw DockerHTTPProtocolError.incompleteRequest }
        guard let headerEnd = find(data, bytes: [13, 10, 13, 10]) else {
            guard data.count <= maximumHeaderBytes else {
                throw DockerHTTPProtocolError.headersTooLarge
            }
            throw DockerHTTPProtocolError.incompleteRequest
        }
        guard headerEnd <= maximumHeaderBytes else {
            throw DockerHTTPProtocolError.headersTooLarge
        }

        let headerData = data.prefix(headerEnd)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw DockerHTTPProtocolError.invalidHeader
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw DockerHTTPProtocolError.invalidRequestLine
        }
        guard requestLine.utf8.count <= maximumRequestLineBytes else {
            throw DockerHTTPProtocolError.requestLineTooLarge
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              let method = DockerHTTPMethod(rawValue: String(requestParts[0])),
              !requestParts[1].isEmpty,
              String(requestParts[2]) == "HTTP/1.1",
              isSafeTarget(String(requestParts[1])) else {
            if requestParts.count == 3, String(requestParts[2]) != "HTTP/1.1" {
                throw DockerHTTPProtocolError.unsupportedHTTPVersion
            }
            throw DockerHTTPProtocolError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        var contentLength: Int?
        var transferEncoding: String?
        for line in lines.dropFirst() {
            try checkCancellation(isCancelled)
            guard !line.isEmpty else { throw DockerHTTPProtocolError.invalidHeader }
            guard line.utf8.count <= maximumHeaderLineBytes,
                  let separator = line.firstIndex(of: ":") else {
                throw line.utf8.count > maximumHeaderLineBytes
                    ? DockerHTTPProtocolError.headerLineTooLarge
                    : DockerHTTPProtocolError.invalidHeader
            }
            let rawName = String(line[..<separator])
            let rawValue = String(line[line.index(after: separator)...])
            guard isValidHeaderName(rawName) else {
                throw DockerHTTPProtocolError.invalidHeaderName
            }
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard isValidHeaderValue(value) else {
                throw DockerHTTPProtocolError.invalidHeaderValue
            }
            let name = rawName.lowercased()
            guard headers[name] == nil else {
                if name == "content-length" {
                    throw DockerHTTPProtocolError.conflictingContentLength
                }
                throw DockerHTTPProtocolError.invalidHeader
            }
            headers[name] = value
            if name == "content-length" {
                guard let parsed = parseDecimal(value) else {
                    throw DockerHTTPProtocolError.invalidContentLength
                }
                guard parsed <= maximumBodyBytes else {
                    throw DockerHTTPProtocolError.bodyTooLarge
                }
                contentLength = parsed
            } else if name == "transfer-encoding" {
                transferEncoding = value.lowercased()
            }
        }
        guard headers.count <= maximumHeaderCount else {
            throw DockerHTTPProtocolError.headerCountExceeded
        }
        if let transferEncoding {
            guard transferEncoding == "chunked" else {
                throw DockerHTTPProtocolError.unsupportedTransferEncoding
            }
            guard contentLength == nil else {
                throw DockerHTTPProtocolError.conflictingFramingHeaders
            }
        }

        let payloadStart = headerEnd + 4
        let payload = data[payloadStart...]
        let body: Data
        if transferEncoding == "chunked" {
            body = try decodeChunked(
                payload,
                isCancelled: isCancelled
            )
        } else if let contentLength {
            guard payload.count >= contentLength else {
                throw DockerHTTPProtocolError.incompleteRequest
            }
            guard payload.count == contentLength else {
                throw DockerHTTPProtocolError.trailingBytes
            }
            body = Data(payload)
        } else {
            guard payload.isEmpty else { throw DockerHTTPProtocolError.trailingBytes }
            body = Data()
        }

        let request = DockerHTTPRequest(
            method: method,
            target: String(requestParts[1]),
            headers: headers,
            body: body,
            version: "HTTP/1.1"
        )
        if request.isUpgradeRequest {
            throw DockerHTTPProtocolError.unsupportedUpgrade
        }
        return request
    }

    public static func encodeResponse(
        _ response: DockerHTTPResponse,
        suppressBody: Bool = false,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> Data {
        try checkCancellation(isCancelled)
        guard (100...599).contains(response.statusCode) else {
            throw DockerHTTPProtocolError.invalidRequestLine
        }
        guard response.body.count <= maximumResponseBytes else {
            throw DockerHTTPProtocolError.responseTooLarge
        }
        guard response.reasonPhrase.utf8.count <= maximumRequestLineBytes,
              isValidHeaderValue(response.reasonPhrase) else {
            throw DockerHTTPProtocolError.invalidHeader
        }
        var headers: [String: String] = [:]
        for (rawName, value) in response.headers {
            let name = rawName.lowercased()
            guard headers[name] == nil, isValidHeaderName(rawName), isValidHeaderValue(value) else {
                throw DockerHTTPProtocolError.invalidHeader
            }
            guard name != "content-length", name != "transfer-encoding" else {
                throw DockerHTTPProtocolError.invalidHeader
            }
            headers[name] = value
        }
        if response.closeConnection {
            headers["connection"] = "close"
        }
        guard headers.count <= maximumHeaderCount else {
            throw DockerHTTPProtocolError.headerCountExceeded
        }
        headers["content-length"] = String(response.body.count)
        let renderedHeaders = headers.keys.sorted().map { key in
            "\(displayHeaderName(key)): \(headers[key]!)\r\n"
        }.joined()
        let prefix = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        guard prefix.utf8.count + renderedHeaders.utf8.count + 2 <= maximumHeaderBytes else {
            throw DockerHTTPProtocolError.headersTooLarge
        }
        var encoded = Data((prefix + renderedHeaders + "\r\n").utf8)
        if !suppressBody {
            encoded.append(response.body)
        }
        guard encoded.count <= maximumResponseBytes + maximumHeaderBytes else {
            throw DockerHTTPProtocolError.responseTooLarge
        }
        return encoded
    }

    public static func errorResponse(
        _ error: DockerHTTPError,
        closeConnection: Bool = true,
        apiVersion: DockerAPIVersion? = nil
    ) -> DockerHTTPResponse {
        struct ErrorBody: Encodable {
            let message: String
        }
        let body: Data
        if let encoded = try? JSONEncoder().encode(ErrorBody(message: error.message)) {
            body = encoded
        } else {
            body = Data("{\"message\":\"The Docker proxy failed safely.\"}".utf8)
        }
        var headers = ["Content-Type": "application/json"]
        if let apiVersion { headers["Api-Version"] = apiVersion.rawValue }
        return DockerHTTPResponse(
            statusCode: error.statusCode,
            headers: headers,
            body: body,
            closeConnection: closeConnection
        )
    }

    private static func decodeChunked(
        _ payload: Data.SubSequence,
        isCancelled: @Sendable () -> Bool
    ) throws -> Data {
        var offset = payload.startIndex
        var body = Data()
        while true {
            try checkCancellation(isCancelled)
            guard let lineEnd = find(payload, bytes: [13, 10], from: offset) else {
                throw DockerHTTPProtocolError.incompleteRequest
            }
            let line = payload[offset..<lineEnd]
            guard line.count <= maximumChunkLineBytes,
                  let lineValue = String(data: Data(line), encoding: .utf8),
                  !lineValue.isEmpty else {
                throw DockerHTTPProtocolError.invalidChunk
            }
            let sizeText = lineValue.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard !sizeText.isEmpty,
                  sizeText.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70)
                          || ($0 >= 97 && $0 <= 102)
                  }),
                  let size = Int(sizeText, radix: 16) else {
                throw DockerHTTPProtocolError.invalidChunk
            }
            offset = lineEnd + 2
            if size == 0 {
                guard let trailerEnd = find(payload, bytes: [13, 10], from: offset) else {
                    throw DockerHTTPProtocolError.incompleteRequest
                }
                // Docker requests in this bounded subset do not advertise or
                // consume trailers. Requiring the empty terminal line avoids
                // request-smuggling ambiguity while retaining chunked input.
                guard trailerEnd == offset else {
                    throw DockerHTTPProtocolError.invalidHeader
                }
                let terminal = trailerEnd + 2
                guard terminal == payload.endIndex else {
                    throw DockerHTTPProtocolError.trailingBytes
                }
                return body
            }
            guard size <= maximumBodyBytes - body.count,
                  payload.distance(from: offset, to: payload.endIndex) >= size + 2 else {
                if size > maximumBodyBytes - body.count {
                    throw DockerHTTPProtocolError.bodyTooLarge
                }
                throw DockerHTTPProtocolError.incompleteRequest
            }
            body.append(contentsOf: payload[offset..<offset + size])
            guard payload[offset + size] == 13, payload[offset + size + 1] == 10 else {
                throw DockerHTTPProtocolError.invalidChunk
            }
            offset += size + 2
        }
    }

    private static func checkCancellation(_ isCancelled: @Sendable () -> Bool) throws {
        if isCancelled() { throw DockerHTTPProtocolError.cancelled }
    }

    private static func find<C: Collection>(
        _ data: C,
        bytes: [UInt8],
        from start: C.Index? = nil
    ) -> C.Index? where C.Element == UInt8 {
        guard !bytes.isEmpty, data.count >= bytes.count else { return nil }
        var index = start ?? data.startIndex
        while index != data.endIndex {
            var cursor = index
            var matched = true
            for byte in bytes {
                guard cursor != data.endIndex, data[cursor] == byte else {
                    matched = false
                    break
                }
                cursor = data.index(after: cursor)
            }
            if matched { return index }
            index = data.index(after: index)
        }
        return nil
    }

    private static func isSafeTarget(_ target: String) -> Bool {
        guard target.hasPrefix("/"), target.utf8.count <= maximumRequestLineBytes else { return false }
        return !target.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f || $0 == 0x20 })
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || $0 < 32 || $0 == 127 })
    }

    private static func parseDecimal(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(value)
    }

    private static func displayHeaderName(_ name: String) -> String {
        switch name {
        case "connection": return "Connection"
        case "content-length": return "Content-Length"
        case "content-type": return "Content-Type"
        case "api-version": return "Api-Version"
        case "docker-experimental": return "Docker-Experimental"
        default:
            return name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }
    }
}
