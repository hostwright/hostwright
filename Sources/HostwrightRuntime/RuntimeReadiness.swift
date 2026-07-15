import Foundation

public enum RuntimeServiceReadinessState: String, Codable, Equatable, Sendable {
    case running
    case notRunning = "not-running"
    case unregistered
}

public struct RuntimeReadinessReport: Codable, Equatable, Sendable {
    public let runtimeName: String
    public let cliVersion: String
    public let serviceState: RuntimeServiceReadinessState
    public let serviceVersion: String?
    public let serviceBuild: String?

    public init(
        runtimeName: String,
        cliVersion: String,
        serviceState: RuntimeServiceReadinessState,
        serviceVersion: String?,
        serviceBuild: String?
    ) {
        self.runtimeName = runtimeName
        self.cliVersion = cliVersion
        self.serviceState = serviceState
        self.serviceVersion = serviceVersion
        self.serviceBuild = serviceBuild
    }
}

enum AppleContainerSystemStatusParser {
    static let maximumBytes = 64 * 1_024
    static let maximumCLIVersionBytes = 1_024
    static let maximumBuildBytes = 128

    static func parse(_ text: String, cliVersion: String) throws -> RuntimeReadinessReport {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container system status output must contain 1 through \(maximumBytes) UTF-8 bytes."
            )
        }

        do {
            try StrictRuntimeJSONObject.validateUniqueTopLevelKeys(data)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container system status output contained invalid or duplicate JSON fields."
            )
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container system status output was not the supported JSON object."
            )
        }

        let normalizedStatus = payload.status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let serviceState: RuntimeServiceReadinessState
        switch normalizedStatus {
        case "running":
            serviceState = .running
        case "not running":
            serviceState = .notRunning
        case "unregistered":
            serviceState = .unregistered
        default:
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container system status '\(normalizedStatus)' is unsupported."
            )
        }

        let cliVersionData = Data(cliVersion.utf8)
        guard !cliVersionData.isEmpty,
              cliVersionData.count <= maximumCLIVersionBytes,
              let normalizedCLIVersion = AppleContainerVersionParser.parse(cliVersion) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container CLI version output was not one bounded semantic version."
            )
        }
        let serviceVersion = payload.apiServerVersion.nilIfEmpty.flatMap(
            AppleContainerVersionParser.parse
        )
        let serviceBuild = normalizedBuild(payload.apiServerBuild)
        if serviceState == .running {
            guard serviceVersion != nil, serviceBuild != nil else {
                throw RuntimeAdapterError.outputParseFailed(
                    "A running Apple container service omitted its version or build identity."
                )
            }
        }

        return RuntimeReadinessReport(
            runtimeName: "Apple container CLI",
            cliVersion: normalizedCLIVersion,
            serviceState: serviceState,
            serviceVersion: serviceVersion,
            serviceBuild: serviceBuild
        )
    }

    private static func normalizedBuild(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumBuildBytes,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (
                      CharacterSet.alphanumerics.contains(scalar)
                          || [".", "_", "+", "-"].contains(Character(scalar))
                  )
              }) else {
            return nil
        }
        return normalized
    }

    private struct Payload: Decodable {
        let status: String
        let apiServerVersion: String
        let apiServerBuild: String
    }
}

private enum StrictRuntimeJSONObject {
    private enum ScanError: Error {
        case invalid
    }

    static func validateUniqueTopLevelKeys(_ data: Data) throws {
        let keys = try topLevelKeys(Array(data))
        var seen = Set<String>()
        guard keys.allSatisfy({ seen.insert($0).inserted }) else {
            throw ScanError.invalid
        }
    }

    private static func topLevelKeys(_ bytes: [UInt8]) throws -> [String] {
        var index = skipWhitespace(bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw ScanError.invalid
        }
        index += 1
        var keys: [String] = []
        while true {
            index = skipWhitespace(bytes, from: index)
            guard index < bytes.count else { throw ScanError.invalid }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            let key = try parseString(bytes, from: index)
            keys.append(key.value)
            index = skipWhitespace(bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw ScanError.invalid
            }
            index = try skipValue(bytes, from: index + 1)
            index = skipWhitespace(bytes, from: index)
            guard index < bytes.count else { throw ScanError.invalid }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw ScanError.invalid
        }
        guard skipWhitespace(bytes, from: index) == bytes.count else {
            throw ScanError.invalid
        }
        return keys
    }

    private static func parseString(
        _ bytes: [UInt8],
        from start: Int
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw ScanError.invalid
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            if escaped {
                escaped = false
            } else if bytes[index] == ascii("\\") {
                escaped = true
            } else if bytes[index] == ascii("\"") {
                let literal = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw ScanError.invalid
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw ScanError.invalid
    }

    private static func skipValue(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = skipWhitespace(bytes, from: start)
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
                throw ScanError.invalid
            }
            index += 1
        }
        throw ScanError.invalid
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
