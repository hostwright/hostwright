import Foundation

public struct AppleContainerCLIIdentity: Equatable, Sendable {
    public let version: String
    public let build: String
    public let commit: String

    public init(version: String, build: String, commit: String) {
        self.version = version
        self.build = build
        self.commit = commit
    }
}

public enum AppleContainerCLICodec: String, CaseIterable, Equatable, Sendable {
    case v1_0_0 = "1.0.0"
    case v1_1_0 = "1.1.0"

    public static let maximumLogBytes = 1 * 1_024 * 1_024
    public static let maximumMutationOutputBytes = 64 * 1_024

    public static func select(
        fromVersionOutput output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> AppleContainerCLICodec {
        guard let identity = AppleContainerVersionParser.parseCLIIdentity(output) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container CLI version output did not match the exact bounded version grammar."
            )
        }
        guard let codec = AppleContainerCLICodec(rawValue: identity.version) else {
            throw RuntimeAdapterError.unsupportedRuntime(
                redactionPolicy.redact(
                    "Apple container CLI version \(identity.version) is unsupported; supported versions are \(supportedVersionList)."
                )
            )
        }
        return codec
    }

    public static func selectForMutation(
        fromVersionOutput output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> AppleContainerCLICodec {
        try select(fromVersionOutput: output, redactionPolicy: redactionPolicy)
    }

    public func decodeObservation(
        _ output: String,
        desiredState: DesiredRuntimeState,
        metadata: RuntimeAdapterMetadata,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> ObservedRuntimeState {
        try AppleContainerObservationParser.parse(
            output,
            desiredState: desiredState,
            metadata: metadata,
            redactionPolicy: redactionPolicy
        )
    }

    public func decodeSystemStatus(
        _ output: String,
        versionOutput: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> RuntimeReadinessReport {
        let selected = try Self.select(
            fromVersionOutput: versionOutput,
            redactionPolicy: redactionPolicy
        )
        guard selected == self else {
            throw RuntimeAdapterError.unsupportedRuntime(
                "Apple container CLI response codec did not match the selected runtime version."
            )
        }
        try validateSystemStatusIdentity(output)
        return try AppleContainerSystemStatusParser.parse(output, cliVersion: versionOutput)
    }

    public func containsLocalImage(
        _ image: String,
        in output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> Bool {
        try AppleContainerImageListOutputParser.contains(
            image,
            in: output,
            redactionPolicy: redactionPolicy
        )
    }

    public func decodeLocalImageEvidence(
        _ output: String,
        expectedReference: String,
        preferredArchitecture: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> RuntimeLocalImageEvidence {
        try AppleContainerImageEvidenceParser.parse(
            output,
            expectedReference: expectedReference,
            preferredArchitecture: preferredArchitecture,
            redactionPolicy: redactionPolicy
        )
    }

    public func decodeResourceUsage(
        _ output: String,
        expectedResourceIdentifier: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> RuntimeResourceUsageSnapshot {
        try AppleContainerStatsParser.parse(
            output,
            expectedResourceIdentifier: expectedResourceIdentifier,
            redactionPolicy: redactionPolicy
        )
    }

    public func decodeNetworks(
        _ output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerNetworkEvidence] {
        switch self {
        case .v1_0_0, .v1_1_0:
            return try AppleContainerNetworkListParser.parse(
                output,
                redactionPolicy: redactionPolicy
            )
        }
    }

    public func decodeVolumes(
        _ output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerVolumeEvidence] {
        switch self {
        case .v1_0_0, .v1_1_0:
            return try AppleContainerVolumeListParser.parse(
                output,
                redactionPolicy: redactionPolicy
            )
        }
    }

    public func decodeMachines(
        _ output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerMachineEvidence] {
        switch self {
        case .v1_0_0, .v1_1_0:
            return try AppleContainerMachineListParser.parse(
                output,
                redactionPolicy: redactionPolicy
            )
        }
    }

    public func decodeOpaqueLogs(
        _ output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> String {
        let byteCount = output.utf8.count
        guard byteCount <= Self.maximumLogBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container log output exceeded the \(Self.maximumLogBytes)-byte codec limit."
            )
        }
        return redactionPolicy.redact(output)
    }

    public func discardMutationOutput(_ output: String) throws {
        guard output.utf8.count <= Self.maximumMutationOutputBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container mutation output exceeded the \(Self.maximumMutationOutputBytes)-byte codec limit."
            )
        }
    }

    private static var supportedVersionList: String {
        allCases.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private func validateSystemStatusIdentity(_ output: String) throws {
        let data = try AppleContainerStructuredOutput.validatedJSONData(
            output,
            operation: "Apple container system status",
            maximumBytes: AppleContainerSystemStatusParser.maximumBytes
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container system status output contained a partial status identity."
            )
        }
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running" else {
            return
        }
        guard let versionOutput = object["apiServerVersion"] as? String,
              let serviceIdentity = AppleContainerVersionParser.parseServiceIdentity(versionOutput),
              serviceIdentity.version == rawValue,
              let build = object["apiServerBuild"] as? String,
              build == serviceIdentity.build,
              let commit = object["apiServerCommit"] as? String,
              commit == "unspecified" || (
                  commit.range(of: #"\A[0-9a-f]{7,40}\z"#, options: .regularExpression) != nil
                      && commit.hasPrefix(serviceIdentity.commit)
              ),
              let appName = object["apiServerAppName"] as? String,
              appName == "container-apiserver" else {
            throw RuntimeAdapterError.outputParseFailed(
                "Running Apple container system status contained an ambiguous service identity."
            )
        }
    }
}

public enum AppleContainerImageListOutputParser {
    public static let maximumBytes = 4 * 1_024 * 1_024

    public static func contains(
        _ image: String,
        in output: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> Bool {
        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                output,
                operation: "Apple container image list",
                maximumBytes: maximumBytes
            )
            guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container image list output was not a JSON array."
                )
            }

            var seenReferences = Set<String>()
            for item in list {
                guard let object = item as? [String: Any],
                      let configuration = object["configuration"] as? [String: Any],
                      let reference = configuration["name"] as? String,
                      !reference.isEmpty else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container image list output contained a partial image entry."
                    )
                }
                guard seenReferences.insert(reference).inserted else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container image list output contained an ambiguous duplicate image reference."
                    )
                }
            }
            return seenReferences.contains(image)
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container image list output was not supported JSON."
            )
        }
    }
}

enum AppleContainerStructuredOutput {
    static func validatedJSONData(
        _ output: String,
        operation: String,
        maximumBytes: Int
    ) throws -> Data {
        let data = Data(output.utf8)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "\(operation) output must contain 1 through \(maximumBytes) UTF-8 bytes."
            )
        }

        do {
            try StrictJSONScanner.validate(Array(data))
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "\(operation) output contained malformed or duplicate JSON fields."
            )
        }
        return data
    }
}

private enum StrictJSONScanner {
    private enum ScanError: Error {
        case invalid
    }

    static func validate(_ bytes: [UInt8]) throws {
        let start = skipWhitespace(bytes, from: 0)
        let end = try parseValue(bytes, from: start)
        guard skipWhitespace(bytes, from: end) == bytes.count else {
            throw ScanError.invalid
        }
    }

    private static func parseValue(_ bytes: [UInt8], from start: Int) throws -> Int {
        let index = skipWhitespace(bytes, from: start)
        guard index < bytes.count else { throw ScanError.invalid }
        switch bytes[index] {
        case ascii("{"):
            return try parseObject(bytes, from: index)
        case ascii("["):
            return try parseArray(bytes, from: index)
        case ascii("\""):
            return try parseString(bytes, from: index).nextIndex
        default:
            var end = index
            while end < bytes.count,
                  ![ascii(","), ascii("]"), ascii("}")].contains(bytes[end]),
                  !isWhitespace(bytes[end]) {
                end += 1
            }
            guard end > index else { throw ScanError.invalid }
            return end
        }
    }

    private static func parseObject(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = skipWhitespace(bytes, from: start + 1)
        if index < bytes.count, bytes[index] == ascii("}") {
            return index + 1
        }

        var seen = Set<String>()
        while true {
            let key = try parseString(bytes, from: index)
            guard seen.insert(key.value).inserted else { throw ScanError.invalid }
            index = skipWhitespace(bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw ScanError.invalid
            }
            index = skipWhitespace(bytes, from: try parseValue(bytes, from: index + 1))
            guard index < bytes.count else { throw ScanError.invalid }
            if bytes[index] == ascii("}") {
                return index + 1
            }
            guard bytes[index] == ascii(",") else { throw ScanError.invalid }
            index = skipWhitespace(bytes, from: index + 1)
            guard index < bytes.count, bytes[index] != ascii("}") else {
                throw ScanError.invalid
            }
        }
    }

    private static func parseArray(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = skipWhitespace(bytes, from: start + 1)
        if index < bytes.count, bytes[index] == ascii("]") {
            return index + 1
        }

        while true {
            index = skipWhitespace(bytes, from: try parseValue(bytes, from: index))
            guard index < bytes.count else { throw ScanError.invalid }
            if bytes[index] == ascii("]") {
                return index + 1
            }
            guard bytes[index] == ascii(",") else { throw ScanError.invalid }
            index = skipWhitespace(bytes, from: index + 1)
            guard index < bytes.count, bytes[index] != ascii("]") else {
                throw ScanError.invalid
            }
        }
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

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        [9, 10, 13, 32].contains(byte)
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
