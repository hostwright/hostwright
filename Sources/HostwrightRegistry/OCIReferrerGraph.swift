import Foundation

public enum OCIMediaTypePolicy {
    public static func validate(_ value: String) throws {
        guard value.utf8.count <= 255,
              value.range(
                  of: #"^application/[a-z0-9][a-z0-9!#$&^_.+-]{0,242}$"#,
                  options: .regularExpression
              ) != nil else {
            throw OCIReferrerContractError.invalidMediaType
        }
    }

    static func validateAnnotations(
        _ values: [String: String]
    ) throws {
        guard values.count <= OCIReferrerLimits.maximumAnnotations,
              values.allSatisfy({ key, value in
                  !key.isEmpty &&
                      key.utf8.count <=
                        OCIReferrerLimits.maximumAnnotationKeyBytes &&
                      value.utf8.count <=
                        OCIReferrerLimits.maximumAnnotationValueBytes &&
                      !key.unicodeScalars.contains {
                          CharacterSet.controlCharacters.contains($0)
                      } &&
                      !value.unicodeScalars.contains {
                          CharacterSet.controlCharacters.contains($0)
                      }
              }) else {
            throw OCIReferrerContractError.limitExceeded
        }
    }
}

public struct OCIContentDescriptor: Codable, Equatable, Sendable {
    public let mediaType: String
    public let digest: OCIContentDigest
    public let size: Int
    public let annotations: [String: String]

    public init(
        mediaType: String,
        digest: OCIContentDigest,
        size: Int,
        annotations: [String: String] = [:]
    ) throws {
        try OCIMediaTypePolicy.validate(mediaType)
        try OCIMediaTypePolicy.validateAnnotations(annotations)
        guard (0...OCIReferrerLimits.maximumObjectBytes).contains(size) else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
    }
}

public enum OCIReferrerObjectKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case manifest
    case index
    case blob
}

public struct OCIReferrerFetchedObject:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let digest: OCIContentDigest
    public let mediaType: String
    public let size: Int
    public let kind: OCIReferrerObjectKind
    public let payload: Data
    public let childDescriptors: [OCIContentDescriptor]

    public init(
        digest: OCIContentDigest,
        mediaType: String,
        size: Int,
        kind: OCIReferrerObjectKind,
        payload: Data,
        childDescriptors: [OCIContentDescriptor]
    ) throws {
        try OCIMediaTypePolicy.validate(mediaType)
        guard size == payload.count,
              size <= OCIReferrerLimits.maximumObjectBytes,
              try digest.matches(payload),
              childDescriptors.count <=
                OCIReferrerLimits.maximumGraphDescriptors,
              kind != .blob || childDescriptors.isEmpty else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        self.digest = digest
        self.mediaType = mediaType
        self.size = size
        self.kind = kind
        self.payload = payload
        self.childDescriptors = childDescriptors
    }

    public var description: String {
        "OCI referrer object (digest: \(digest.canonicalValue), mediaType: \(mediaType), bytes: \(size), payload: redacted)."
    }

    public var debugDescription: String {
        description
    }
}

public struct OCIReferrerGraph: Equatable, Sendable {
    public let discovery: OCIReferrerDiscoveryResult
    public let verifiedReferrers: [OCIReferrerDescriptor]
    public let objects: [OCIReferrerFetchedObject]
    public let totalBytes: Int

    public init(
        discovery: OCIReferrerDiscoveryResult,
        verifiedReferrers: [OCIReferrerDescriptor],
        objects: [OCIReferrerFetchedObject]
    ) throws {
        let totalBytes = objects.reduce(0) { $0 + $1.size }
        guard verifiedReferrers.count <=
                OCIReferrerLimits.maximumReferrerDescriptors,
              objects.count <= OCIReferrerLimits.maximumGraphDescriptors,
              totalBytes <= OCIReferrerLimits.maximumGraphBytes else {
            throw OCIReferrerContractError.limitExceeded
        }
        self.discovery = discovery
        self.verifiedReferrers = verifiedReferrers
        self.objects = objects
        self.totalBytes = totalBytes
    }
}

struct OCIParsedDocument {
    let kind: OCIReferrerObjectKind
    let mediaType: String
    let effectiveArtifactType: OCIArtifactType?
    let subject: OCIContentDescriptor?
    let children: [OCIContentDescriptor]
    let annotations: [String: String]

    static func parse(_ data: Data) throws -> OCIParsedDocument {
        let object: [String: Any]
        do {
            object = try RegistryStrictJSONObject.decode(
                data,
                maximumBytes: OCIReferrerLimits.maximumObjectBytes,
                allowedKeys: [
                    "schemaVersion", "mediaType", "artifactType",
                    "config", "layers", "manifests", "subject",
                    "annotations"
                ],
                requiredKeys: ["schemaVersion", "mediaType"]
            )
        } catch {
            throw OCIReferrerContractError.invalidDescriptor
        }
        guard RegistryStrictJSONObject.integer(object["schemaVersion"]) == 2,
              let mediaType = object["mediaType"] as? String else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        let kind: OCIReferrerObjectKind
        switch mediaType {
        case OCIReferrerDescriptor.manifestMediaType:
            kind = .manifest
        case OCIReferrerDescriptor.indexMediaType:
            kind = .index
        default:
            throw OCIReferrerContractError.invalidMediaType
        }

        let declaredArtifactType: OCIArtifactType?
        if let raw = object["artifactType"] {
            guard let value = raw as? String else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            declaredArtifactType = try OCIArtifactType(value)
        } else {
            declaredArtifactType = nil
        }
        let subject = try object["subject"].map(parseDescriptor)
        let annotations: [String: String]
        if let rawAnnotations = object["annotations"] {
            guard let values = rawAnnotations as? [String: Any],
                  values.values.allSatisfy({ $0 is String }) else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            annotations = values.mapValues { $0 as! String }
            try OCIMediaTypePolicy.validateAnnotations(annotations)
        } else {
            annotations = [:]
        }
        let children: [OCIContentDescriptor]
        let effectiveArtifactType: OCIArtifactType?
        switch kind {
        case .manifest:
            guard let rawConfig = object["config"] else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            let config = try parseDescriptor(rawConfig)
            guard let rawLayers = object["layers"] as? [Any] else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            guard rawLayers.count + 1 <=
                    OCIReferrerLimits.maximumGraphDescriptors else {
                throw OCIReferrerContractError.limitExceeded
            }
            children = [config] + (try rawLayers.map(parseDescriptor))
            effectiveArtifactType = declaredArtifactType ??
                (try? OCIArtifactType(config.mediaType))
        case .index:
            guard let rawManifests = object["manifests"] as? [Any],
                  rawManifests.count <=
                    OCIReferrerLimits.maximumGraphDescriptors else {
                throw OCIReferrerContractError.limitExceeded
            }
            children = try rawManifests.map(parseDescriptor)
            effectiveArtifactType = declaredArtifactType
        case .blob:
            throw OCIReferrerContractError.invalidDescriptor
        }
        return OCIParsedDocument(
            kind: kind,
            mediaType: mediaType,
            effectiveArtifactType: effectiveArtifactType,
            subject: subject,
            children: children,
            annotations: annotations
        )
    }

    private static func parseDescriptor(
        _ raw: Any
    ) throws -> OCIContentDescriptor {
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(
                  of: [
                      "mediaType", "digest", "size",
                      "annotations", "artifactType", "platform"
                  ]
              ),
              let mediaType = object["mediaType"] as? String,
              let digest = object["digest"] as? String,
              let size = RegistryStrictJSONObject.integer(
                  object["size"]
              ) else {
            throw OCIReferrerContractError.invalidDescriptor
        }
        let annotations: [String: String]
        if let rawAnnotations = object["annotations"] {
            guard let values = rawAnnotations as? [String: Any],
                  values.values.allSatisfy({ $0 is String }) else {
                throw OCIReferrerContractError.invalidDescriptor
            }
            annotations = values.mapValues { $0 as! String }
        } else {
            annotations = [:]
        }
        return try OCIContentDescriptor(
            mediaType: mediaType,
            digest: OCIContentDigest(digest),
            size: size,
            annotations: annotations
        )
    }
}
