import CryptoKit
import Foundation
import HostwrightCore
import HostwrightPolicy

public struct ExecutableExtensionDocument: Codable, Equatable, Sendable {
    public let kind: HostwrightExtensionKind
    public let apiVersion: Int
    public let protocolVersion: Int
    public let identifier: String
    public let trust: HostwrightExtensionTrust
    public let capability: HostwrightExtensionCapability
    public let purpose: String
    public let boundaries: [HostwrightExtensionBoundary]
    public let executableSHA256: String

    public init(
        kind: HostwrightExtensionKind,
        apiVersion: Int = HostwrightContractVersions.pluginABI,
        protocolVersion: Int = HostwrightContractVersions.pluginABI,
        identifier: String,
        trust: HostwrightExtensionTrust,
        capability: HostwrightExtensionCapability,
        purpose: String,
        boundaries: [HostwrightExtensionBoundary],
        executableSHA256: String
    ) {
        self.kind = kind
        self.apiVersion = apiVersion
        self.protocolVersion = protocolVersion
        self.identifier = identifier
        self.trust = trust
        self.capability = capability
        self.purpose = purpose
        self.boundaries = boundaries
        self.executableSHA256 = executableSHA256
    }

    public var policyDeclaration: HostwrightExtensionDeclaration {
        HostwrightExtensionDeclaration(
            identifier: identifier,
            kind: kind,
            apiVersion: apiVersion,
            trust: trust,
            capabilities: [
                HostwrightExtensionCapabilityDeclaration(
                    capability: capability,
                    purpose: purpose,
                    boundaries: boundaries
                )
            ]
        )
    }
}

public struct ExecutableExtensionArtifact: Equatable, Sendable {
    public let document: ExecutableExtensionDocument
    public let declarationSHA256: String

    public init(document: ExecutableExtensionDocument, declarationSHA256: String) {
        self.document = document
        self.declarationSHA256 = declarationSHA256
    }
}

public struct ExtensionHandshakeResult: Equatable, Sendable {
    public let identifier: String
    public let capability: HostwrightExtensionCapability
    public let protocolVersion: Int
    public let declarationSHA256: String
    public let executableSHA256: String
    public let durationMilliseconds: Int
    public let cleanupSucceeded: Bool

    public init(
        identifier: String,
        capability: HostwrightExtensionCapability,
        protocolVersion: Int,
        declarationSHA256: String,
        executableSHA256: String,
        durationMilliseconds: Int,
        cleanupSucceeded: Bool
    ) {
        self.identifier = identifier
        self.capability = capability
        self.protocolVersion = protocolVersion
        self.declarationSHA256 = declarationSHA256
        self.executableSHA256 = executableSHA256
        self.durationMilliseconds = durationMilliseconds
        self.cleanupSucceeded = cleanupSucceeded
    }
}

public enum ExecutableExtensionDocumentParser {
    public static let maximumDocumentBytes = 128 * 1_024

    private static let expectedKeys: Set<String> = [
        "kind",
        "apiVersion",
        "protocolVersion",
        "identifier",
        "trust",
        "capability",
        "purpose",
        "boundaries",
        "executableSHA256"
    ]

    public static func parse(_ data: Data) throws -> ExecutableExtensionArtifact {
        guard !data.isEmpty, data.count <= maximumDocumentBytes else {
            throw invalid("The executable extension declaration must be non-empty and no larger than 128 KiB.")
        }

        try StrictExtensionJSONObject.validate(data, expectedKeys: expectedKeys, role: "executable extension declaration")
        let document: ExecutableExtensionDocument
        do {
            document = try JSONDecoder().decode(ExecutableExtensionDocument.self, from: data)
        } catch {
            throw invalid("The executable extension declaration has invalid field types or values.")
        }
        try validate(document)
        return ExecutableExtensionArtifact(
            document: document,
            declarationSHA256: sha256(data)
        )
    }

    public static func parse(_ text: String) throws -> ExecutableExtensionArtifact {
        try parse(Data(text.utf8))
    }

    private static func validate(_ document: ExecutableExtensionDocument) throws {
        guard document.apiVersion == HostwrightContractVersions.pluginABI else {
            throw invalid("Executable extension declaration API version \(document.apiVersion) is not supported.")
        }
        guard document.protocolVersion == HostwrightContractVersions.pluginABI else {
            throw invalid("Executable extension protocol version \(document.protocolVersion) is not supported.")
        }
        guard document.trust == .reviewedLocal else {
            throw blocked("Executable extensions must use reviewedLocal trust after local review.")
        }
        guard validIdentifier(document.identifier) else {
            throw invalid("Executable extension identifiers must be lowercase reverse-DNS names between 3 and 128 characters.")
        }

        let purpose = document.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty,
              purpose.count <= 512,
              !purpose.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("Executable extension purpose must be non-empty, bounded text without control characters.")
        }
        guard document.executableSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw invalid("Executable extension executableSHA256 must contain 64 lowercase hexadecimal characters.")
        }
        guard !document.boundaries.isEmpty,
              Set(document.boundaries.map(\.rawValue)).count == document.boundaries.count else {
            throw invalid("Executable extension boundaries must be non-empty and contain no duplicates.")
        }
        guard allowedCapabilities(for: document.kind).contains(document.capability) else {
            throw blocked("Executable extension kind and capability do not form an approved read-only pairing.")
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard value.count >= 3,
              value.count <= 128,
              value.contains(".") else {
            return false
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            label.count <= 63 &&
                String(label).range(
                    of: "^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",
                    options: .regularExpression
                ) != nil
        }
    }

    private static func allowedCapabilities(
        for kind: HostwrightExtensionKind
    ) -> Set<HostwrightExtensionCapability> {
        switch kind {
        case .policyPack:
            [.policyEvaluation]
        case .controlSurfaceIntegration:
            [.controlSurfaceRead]
        case .diagnosticsIntegration:
            [.diagnosticsRead, .stateRead]
        case .runtimeAdapter:
            [.runtimeObservation]
        case .schedulerIntegration:
            [.schedulerAdvice]
        case .networkingProvider, .tunnelProvider, .future:
            []
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionInvalid, message: message)
    }

    private static func blocked(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionBlocked, message: message)
    }
}

enum StrictExtensionJSONObject {
    static func validate(_ data: Data, expectedKeys: Set<String>, role: String) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw invalid("Could not parse \(role) JSON.")
        }
        guard let object = value as? [String: Any] else {
            throw invalid("The \(role) must be one JSON object.")
        }

        let orderedKeys = try topLevelKeys(in: data, role: role)
        var seen = Set<String>()
        if let duplicate = orderedKeys.first(where: { !seen.insert($0).inserted }) {
            let field = expectedKeys.contains(duplicate) ? " '\(duplicate)'" : ""
            throw invalid("The \(role) contains a duplicate field\(field).")
        }

        let actualKeys = Set(object.keys)
        guard actualKeys == expectedKeys else {
            let problem = actualKeys.subtracting(expectedKeys).isEmpty ? "missing required fields" : "unsupported fields"
            throw invalid("The \(role) contains \(problem).")
        }
    }

    private static func topLevelKeys(in data: Data, role: String) throws -> [String] {
        let bytes = Array(data)
        var index = skipWhitespace(in: bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw invalid("The \(role) must be one JSON object.")
        }
        index += 1
        var keys: [String] = []

        while true {
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }

            let key = try parseJSONString(in: bytes, from: index, role: role)
            keys.append(key.value)
            index = skipWhitespace(in: bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index = try skipJSONValue(in: bytes, from: index + 1, role: role)
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw invalid("Could not parse \(role) JSON.")
        }

        guard skipWhitespace(in: bytes, from: index) == bytes.count else {
            throw invalid("Could not parse \(role) JSON.")
        }
        return keys
    }

    private static func parseJSONString(
        in bytes: [UInt8],
        from start: Int,
        role: String
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw invalid("Could not parse \(role) JSON object key.")
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == ascii("\\") {
                escaped = true
            } else if byte == ascii("\"") {
                let literal = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw invalid("Could not parse \(role) JSON object key.")
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON object key.")
    }

    private static func skipJSONValue(in bytes: [UInt8], from start: Int, role: String) throws -> Int {
        var index = skipWhitespace(in: bytes, from: start)
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    inString = false
                }
                index += 1
                continue
            }

            switch byte {
            case ascii("\""):
                inString = true
            case ascii("{"):
                objectDepth += 1
            case ascii("}"):
                if objectDepth == 0, arrayDepth == 0 { return index }
                objectDepth -= 1
            case ascii("["):
                arrayDepth += 1
            case ascii("]"):
                arrayDepth -= 1
            case ascii(",") where objectDepth == 0 && arrayDepth == 0:
                return index
            default:
                break
            }
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON.")
    }

    private static func skipWhitespace(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .extensionInvalid, message: message)
    }
}
