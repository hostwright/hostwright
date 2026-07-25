import CryptoKit
import Foundation

public enum OCIReferrerLimits {
    public static let maximumDiscoveryPages = 16
    public static let maximumReferrerDescriptors = 512
    public static let maximumGraphDescriptors = 1_024
    public static let maximumGraphDepth = 8
    public static let maximumObjectBytes = 8 * 1_024 * 1_024
    public static let maximumGraphBytes = 64 * 1_024 * 1_024
    public static let maximumAnnotations = 128
    public static let maximumAnnotationKeyBytes = 256
    public static let maximumAnnotationValueBytes = 4_096
}

public enum OCIReferrerContractError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidDigest
    case digestMismatch
    case invalidRepository
    case invalidMediaType
    case invalidDescriptor
    case invalidIndex
    case limitExceeded

    public var description: String {
        switch self {
        case .invalidDigest:
            "OCI content digest is invalid or unsupported."
        case .digestMismatch:
            "OCI content does not match its declared digest."
        case .invalidRepository:
            "OCI repository name is invalid."
        case .invalidMediaType:
            "OCI media type is invalid or unsupported."
        case .invalidDescriptor:
            "OCI descriptor is invalid or internally inconsistent."
        case .invalidIndex:
            "OCI referrers index is malformed or unsupported."
        case .limitExceeded:
            "OCI referrer content exceeds a bounded Hostwright limit."
        }
    }
}

public struct OCIContentDigest:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let algorithm: String
    public let encoded: String

    public init(_ value: String) throws {
        let components = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2 else {
            throw OCIReferrerContractError.invalidDigest
        }
        let algorithm = String(components[0])
        let encoded = String(components[1])
        let expectedLength: Int
        switch algorithm {
        case "sha256":
            expectedLength = 64
        case "sha512":
            expectedLength = 128
        default:
            throw OCIReferrerContractError.invalidDigest
        }
        guard encoded.count == expectedLength,
              encoded.range(
                  of: "^[a-f0-9]{\(expectedLength)}$",
                  options: .regularExpression
              ) != nil else {
            throw OCIReferrerContractError.invalidDigest
        }
        self.algorithm = algorithm
        self.encoded = encoded
    }

    public static func sha256(of data: Data) throws -> OCIContentDigest {
        try OCIContentDigest(
            "sha256:" + SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    public static func sha512(of data: Data) throws -> OCIContentDigest {
        try OCIContentDigest(
            "sha512:" + SHA512.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    public func matches(_ data: Data) throws -> Bool {
        switch algorithm {
        case "sha256":
            return self == (try Self.sha256(of: data))
        case "sha512":
            return self == (try Self.sha512(of: data))
        default:
            throw OCIReferrerContractError.invalidDigest
        }
    }

    public var canonicalValue: String {
        "\(algorithm):\(encoded)"
    }

    public var referrersTag: String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        let raw = String(algorithm.prefix(32)) + "-" + String(encoded.prefix(64))
        return String(
            raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
    }

    public var exactReferrersTag: String? {
        algorithm == "sha256" ? referrersTag : nil
    }

    public var description: String {
        canonicalValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalValue)
    }
}

public struct OCIRepositoryName:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.range(
                  of: #"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$"#,
                  options: .regularExpression
              ) != nil else {
            throw OCIReferrerContractError.invalidRepository
        }
        self.value = value
    }

    public var description: String {
        value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct OCIArtifactType:
    Codable,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let value: String

    public init(_ value: String) throws {
        guard value.utf8.count <= 255,
              value.range(
                  of: #"^application/[a-z0-9][a-z0-9!#$&^_.+-]{0,242}$"#,
                  options: .regularExpression
              ) != nil else {
            throw OCIReferrerContractError.invalidMediaType
        }
        self.value = value
    }

    public var description: String {
        value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct OCIReferrerDescriptor:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public static let manifestMediaType =
        "application/vnd.oci.image.manifest.v1+json"
    public static let indexMediaType =
        "application/vnd.oci.image.index.v1+json"

    public let mediaType: String
    public let digest: OCIContentDigest
    public let size: Int
    public let artifactType: OCIArtifactType?
    public let annotations: [String: String]

    public init(
        mediaType: String,
        digest: OCIContentDigest,
        size: Int,
        artifactType: OCIArtifactType?,
        annotations: [String: String]
    ) throws {
        guard [Self.manifestMediaType, Self.indexMediaType].contains(mediaType),
              (0...OCIReferrerLimits.maximumObjectBytes).contains(size),
              try Self.validAnnotations(annotations) else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.artifactType = artifactType
        self.annotations = annotations
    }

    private static func validAnnotations(
        _ annotations: [String: String]
    ) throws -> Bool {
        guard annotations.count <= OCIReferrerLimits.maximumAnnotations else {
            throw OCIReferrerContractError.limitExceeded
        }
        return annotations.allSatisfy { key, value in
            !key.isEmpty &&
                key.utf8.count <= OCIReferrerLimits.maximumAnnotationKeyBytes &&
                value.utf8.count <=
                    OCIReferrerLimits.maximumAnnotationValueBytes &&
                !key.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                } &&
                !value.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                }
        }
    }
}

public struct OCIReferrerIndex: Equatable, Sendable {
    public static let mediaType = OCIReferrerDescriptor.indexMediaType

    public let schemaVersion: Int
    public let subjectDigest: OCIContentDigest
    public let descriptors: [OCIReferrerDescriptor]

    public static func parse(
        _ data: Data,
        subjectDigest: OCIContentDigest
    ) throws -> OCIReferrerIndex {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: OCIReferrerLimits.maximumObjectBytes,
                allowedKeys: [
                    "schemaVersion", "mediaType", "manifests",
                    "artifactType", "annotations", "subject"
                ],
                requiredKeys: ["schemaVersion", "mediaType", "manifests"]
            )
        } catch {
            throw OCIReferrerContractError.invalidIndex
        }
        guard RegistryStrictJSONObject.integer(object["schemaVersion"]) == 2,
              object["mediaType"] as? String == mediaType,
              let rawDescriptors = object["manifests"] as? [Any],
              rawDescriptors.count <=
                OCIReferrerLimits.maximumReferrerDescriptors else {
            throw OCIReferrerContractError.invalidIndex
        }
        if let rawSubject = object["subject"] {
            let declaredSubject = try parseDescriptor(rawSubject)
            guard declaredSubject.digest == subjectDigest else {
                throw OCIReferrerContractError.invalidIndex
            }
        }

        var descriptorsByDigest: [OCIContentDigest: OCIReferrerDescriptor] = [:]
        for raw in rawDescriptors {
            let descriptor = try parseDescriptor(raw)
            if let existing = descriptorsByDigest[descriptor.digest],
               existing != descriptor {
                throw OCIReferrerContractError.invalidDescriptor
            }
            descriptorsByDigest[descriptor.digest] = descriptor
        }

        return OCIReferrerIndex(
            schemaVersion: 2,
            subjectDigest: subjectDigest,
            descriptors: descriptorsByDigest.values.sorted {
                $0.digest.canonicalValue < $1.digest.canonicalValue
            }
        )
    }

    private static func parseDescriptor(
        _ raw: Any
    ) throws -> OCIReferrerDescriptor {
        guard let descriptorObject = raw as? [String: Any],
              Set(descriptorObject.keys).isSubset(
                  of: [
                      "mediaType", "digest", "size",
                      "artifactType", "annotations"
                  ]
              ),
              let mediaType = descriptorObject["mediaType"] as? String,
              let digestValue = descriptorObject["digest"] as? String,
              let size = RegistryStrictJSONObject.integer(
                  descriptorObject["size"]
              ) else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        let artifactType: OCIArtifactType?
        if let rawArtifactType = descriptorObject["artifactType"] {
            guard let value = rawArtifactType as? String else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            artifactType = try OCIArtifactType(value)
        } else {
            artifactType = nil
        }
        let annotations: [String: String]
        if let rawAnnotations = descriptorObject["annotations"] {
            guard let values = rawAnnotations as? [String: Any],
                  values.values.allSatisfy({ $0 is String }) else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            annotations = values.mapValues { $0 as! String }
        } else {
            annotations = [:]
        }
        return try OCIReferrerDescriptor(
            mediaType: mediaType,
            digest: OCIContentDigest(digestValue),
            size: size,
            artifactType: artifactType,
            annotations: annotations
        )
    }
}
