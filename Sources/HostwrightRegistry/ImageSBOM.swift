import CryptoKit
import Foundation

public enum ImageSBOMLimits {
    public static let maximumDocumentBytes = 8 * 1_024 * 1_024
    public static let maximumComponents = 10_000
    public static let maximumComponentDepth = 32
    public static let maximumStringBytes = 4_096
    public static let maximumLicensesPerComponent = 64
    public static let maximumHashesPerComponent = 32
}

public enum ImageSBOMFormat:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable
{
    case spdxJSON = "spdx-json"
    case cyclonedxJSON = "cyclonedx-json"

    public var artifactType: String {
        switch self {
        case .spdxJSON:
            "application/spdx+json"
        case .cyclonedxJSON:
            "application/vnd.cyclonedx+json"
        }
    }

    public var layerMediaType: String {
        artifactType
    }
}

public enum ImageSBOMError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidDocument
    case unsupportedFormat
    case limitExceeded
    case invalidComponent
    case duplicateComponent
    case subjectDigestMismatch
    case cancelled

    public var description: String {
        switch self {
        case .invalidDocument:
            "The SBOM document is malformed or internally inconsistent."
        case .unsupportedFormat:
            "The SBOM document format or version is unsupported."
        case .limitExceeded:
            "The SBOM document exceeds a bounded Hostwright limit."
        case .invalidComponent:
            "The SBOM contains an invalid component."
        case .duplicateComponent:
            "The SBOM contains a duplicate component identity."
        case .subjectDigestMismatch:
            "The SBOM does not bind the exact expected image digest."
        case .cancelled:
            "The SBOM operation was cancelled at a bounded checkpoint."
        }
    }
}

public struct ImageSBOMComponent:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let id: String
    public let name: String
    public let version: String?
    public let packageURL: String?
    public let licenses: [String]
    public let hashes: [String: String]

    public init(
        id: String,
        name: String,
        version: String?,
        packageURL: String?,
        licenses: [String],
        hashes: [String: String]
    ) throws {
        guard Self.valid(id, maximumBytes: 512),
              Self.valid(name, maximumBytes: 512),
              version.map({
                  Self.valid($0, maximumBytes: 512)
              }) ?? true,
              packageURL.map({
                  Self.valid($0, maximumBytes: 2_048) &&
                      $0.hasPrefix("pkg:")
              }) ?? true,
              licenses.count <=
                ImageSBOMLimits.maximumLicensesPerComponent,
              hashes.count <=
                ImageSBOMLimits.maximumHashesPerComponent,
              licenses.allSatisfy({
                  Self.valid($0, maximumBytes: 512)
              }),
              hashes.allSatisfy({ algorithm, value in
                  ["sha256", "sha512"].contains(algorithm) &&
                      value.range(
                          of: algorithm == "sha256"
                            ? "^[a-f0-9]{64}$"
                            : "^[a-f0-9]{128}$",
                          options: .regularExpression
                      ) != nil
              }) else {
            throw ImageSBOMError.invalidComponent
        }
        self.id = id
        self.name = name
        self.version = version
        self.packageURL = packageURL
        self.licenses = Array(Set(licenses)).sorted()
        self.hashes = hashes
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

public struct ImageSBOMDocument: Equatable, Sendable {
    public let format: ImageSBOMFormat
    public let specificationVersion: String
    public let documentDigest: OCIContentDigest
    public let subjectDigest: OCIContentDigest
    public let components: [ImageSBOMComponent]
    public let normalizedComponentsSHA256: String

    public static func parse(
        _ data: Data,
        expectedSubjectDigest: OCIContentDigest,
        expectedFormat: ImageSBOMFormat? = nil
    ) throws -> ImageSBOMDocument {
        guard !data.isEmpty else {
            throw ImageSBOMError.invalidDocument
        }
        guard data.count <= ImageSBOMLimits.maximumDocumentBytes else {
            throw ImageSBOMError.limitExceeded
        }
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: ImageSBOMLimits.maximumDocumentBytes
            )
        } catch {
            throw ImageSBOMError.invalidDocument
        }
        let parsed: (
            format: ImageSBOMFormat,
            version: String,
            components: [ImageSBOMComponent],
            subjectBound: Bool
        )
        if object["spdxVersion"] != nil {
            parsed = try parseSPDX(
                object,
                subjectDigest: expectedSubjectDigest
            )
        } else if object["bomFormat"] != nil {
            parsed = try parseCycloneDX(
                object,
                subjectDigest: expectedSubjectDigest
            )
        } else {
            throw ImageSBOMError.unsupportedFormat
        }
        guard expectedFormat == nil || expectedFormat == parsed.format else {
            throw ImageSBOMError.unsupportedFormat
        }
        guard parsed.subjectBound else {
            throw ImageSBOMError.subjectDigestMismatch
        }
        guard !parsed.components.isEmpty,
              parsed.components.count <=
                ImageSBOMLimits.maximumComponents else {
            throw ImageSBOMError.limitExceeded
        }
        let sorted = parsed.components.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.name < $1.name
        }
        guard Set(sorted.map(\.id)).count == sorted.count else {
            throw ImageSBOMError.duplicateComponent
        }
        let normalized: Data
        do {
            normalized = try JSONEncoder.sorted.encode(sorted)
        } catch {
            throw ImageSBOMError.invalidDocument
        }
        return ImageSBOMDocument(
            format: parsed.format,
            specificationVersion: parsed.version,
            documentDigest: try OCIContentDigest.sha256(of: data),
            subjectDigest: expectedSubjectDigest,
            components: sorted,
            normalizedComponentsSHA256: hexSHA256(normalized)
        )
    }

    private static func parseSPDX(
        _ object: [String: Any],
        subjectDigest: OCIContentDigest
    ) throws -> (
        format: ImageSBOMFormat,
        version: String,
        components: [ImageSBOMComponent],
        subjectBound: Bool
    ) {
        guard object["spdxVersion"] as? String == "SPDX-2.3",
              object["dataLicense"] as? String == "CC0-1.0",
              object["SPDXID"] as? String == "SPDXRef-DOCUMENT",
              validString(object["name"]),
              validString(object["documentNamespace"]),
              object["creationInfo"] is [String: Any],
              let packages = object["packages"] as? [Any] else {
            throw ImageSBOMError.unsupportedFormat
        }
        guard packages.count <= ImageSBOMLimits.maximumComponents else {
            throw ImageSBOMError.limitExceeded
        }
        var bound = false
        let components = try packages.map { raw -> ImageSBOMComponent in
            guard let package = raw as? [String: Any],
                  let id = package["SPDXID"] as? String,
                  let name = package["name"] as? String else {
                throw ImageSBOMError.invalidComponent
            }
            let hashes = try spdxHashes(package["checksums"])
            if hashes[subjectDigest.algorithm] == subjectDigest.encoded {
                bound = true
            }
            let external = package["externalRefs"] as? [Any] ?? []
            guard external.count <= 64 else {
                throw ImageSBOMError.limitExceeded
            }
            let packageURLs = try external.compactMap {
                raw -> String? in
                guard let value = raw as? [String: Any],
                      let type = value["referenceType"] as? String,
                      let locator = value["referenceLocator"] as? String else {
                    throw ImageSBOMError.invalidComponent
                }
                return type.lowercased().contains("purl")
                    ? locator : nil
            }
            guard packageURLs.count <= 1 else {
                throw ImageSBOMError.invalidComponent
            }
            let rawLicenses: [String?] = [
                package["licenseDeclared"] as? String,
                package["licenseConcluded"] as? String
            ]
            let licenses: [String] = rawLicenses.compactMap { value in
                guard let value,
                      value != "NONE",
                      value != "NOASSERTION"
                else {
                    return nil
                }
                return value
            }
            return try ImageSBOMComponent(
                id: id,
                name: name,
                version: package["versionInfo"] as? String,
                packageURL: packageURLs.first,
                licenses: licenses,
                hashes: hashes
            )
        }
        return (.spdxJSON, "2.3", components, bound)
    }

    private static func parseCycloneDX(
        _ object: [String: Any],
        subjectDigest: OCIContentDigest
    ) throws -> (
        format: ImageSBOMFormat,
        version: String,
        components: [ImageSBOMComponent],
        subjectBound: Bool
    ) {
        guard object["bomFormat"] as? String == "CycloneDX",
              let version = object["specVersion"] as? String,
              ["1.5", "1.6"].contains(version),
              RegistryStrictJSONObject.integer(object["version"]) != nil,
              let metadata = object["metadata"] as? [String: Any],
              let root = metadata["component"] as? [String: Any] else {
            throw ImageSBOMError.unsupportedFormat
        }
        var rawComponents: [[String: Any]] = [root]
        if let children = object["components"] as? [Any] {
            try flattenCycloneDX(
                children,
                depth: 0,
                into: &rawComponents
            )
        }
        guard rawComponents.count <=
                ImageSBOMLimits.maximumComponents else {
            throw ImageSBOMError.limitExceeded
        }
        var bound = false
        let components = try rawComponents.map {
            raw -> ImageSBOMComponent in
            guard let id = raw["bom-ref"] as? String,
                  let name = raw["name"] as? String else {
                throw ImageSBOMError.invalidComponent
            }
            let hashes = try cycloneDXHashes(raw["hashes"])
            if hashes[subjectDigest.algorithm] == subjectDigest.encoded {
                bound = true
            }
            return try ImageSBOMComponent(
                id: id,
                name: name,
                version: raw["version"] as? String,
                packageURL: raw["purl"] as? String,
                licenses: try cycloneDXLicenses(raw["licenses"]),
                hashes: hashes
            )
        }
        return (.cyclonedxJSON, version, components, bound)
    }

    private static func flattenCycloneDX(
        _ values: [Any],
        depth: Int,
        into result: inout [[String: Any]]
    ) throws {
        guard depth <= ImageSBOMLimits.maximumComponentDepth else {
            throw ImageSBOMError.limitExceeded
        }
        for value in values {
            guard let component = value as? [String: Any] else {
                throw ImageSBOMError.invalidComponent
            }
            result.append(component)
            guard result.count <=
                    ImageSBOMLimits.maximumComponents else {
                throw ImageSBOMError.limitExceeded
            }
            if let children = component["components"] as? [Any] {
                try flattenCycloneDX(
                    children,
                    depth: depth + 1,
                    into: &result
                )
            } else if component["components"] != nil {
                throw ImageSBOMError.invalidComponent
            }
        }
    }

    private static func spdxHashes(
        _ raw: Any?
    ) throws -> [String: String] {
        let values = raw as? [Any] ?? []
        guard values.count <=
                ImageSBOMLimits.maximumHashesPerComponent else {
            throw ImageSBOMError.limitExceeded
        }
        var result: [String: String] = [:]
        for value in values {
            guard let hash = value as? [String: Any],
                  let algorithm = hash["algorithm"] as? String,
                  let checksum = hash["checksumValue"] as? String else {
                throw ImageSBOMError.invalidComponent
            }
            let normalized: String
            switch algorithm.uppercased() {
            case "SHA256", "SHA-256":
                normalized = "sha256"
            case "SHA512", "SHA-512":
                normalized = "sha512"
            default:
                continue
            }
            guard result[normalized] == nil else {
                throw ImageSBOMError.invalidComponent
            }
            result[normalized] = checksum.lowercased()
        }
        return result
    }

    private static func cycloneDXHashes(
        _ raw: Any?
    ) throws -> [String: String] {
        let values = raw as? [Any] ?? []
        guard values.count <=
                ImageSBOMLimits.maximumHashesPerComponent else {
            throw ImageSBOMError.limitExceeded
        }
        var result: [String: String] = [:]
        for value in values {
            guard let hash = value as? [String: Any],
                  let algorithm = hash["alg"] as? String,
                  let content = hash["content"] as? String else {
                throw ImageSBOMError.invalidComponent
            }
            let normalized: String
            switch algorithm.uppercased() {
            case "SHA-256", "SHA256":
                normalized = "sha256"
            case "SHA-512", "SHA512":
                normalized = "sha512"
            default:
                continue
            }
            guard result[normalized] == nil else {
                throw ImageSBOMError.invalidComponent
            }
            result[normalized] = content.lowercased()
        }
        return result
    }

    private static func cycloneDXLicenses(
        _ raw: Any?
    ) throws -> [String] {
        let values = raw as? [Any] ?? []
        guard values.count <=
                ImageSBOMLimits.maximumLicensesPerComponent else {
            throw ImageSBOMError.limitExceeded
        }
        return try values.map { value in
            guard let item = value as? [String: Any] else {
                throw ImageSBOMError.invalidComponent
            }
            if let expression = item["expression"] as? String {
                return expression
            }
            guard let license = item["license"] as? [String: Any],
                  let identifier =
                    (license["id"] as? String) ??
                    (license["name"] as? String) else {
                throw ImageSBOMError.invalidComponent
            }
            return identifier
        }
    }

    private static func validString(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.isEmpty &&
            value.utf8.count <= ImageSBOMLimits.maximumStringBytes &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private func hexSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}
